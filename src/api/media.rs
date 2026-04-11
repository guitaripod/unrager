use crate::error::{Error, Result};
use reqwest::multipart::{Form, Part};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::time::sleep;

pub const MEDIA_UPLOAD_URL: &str = "https://api.x.com/2/media/upload";
pub const SINGLE_SHOT_MAX: u64 = 5 * 1024 * 1024;
pub const CHUNK_SIZE: u64 = 4 * 1024 * 1024;
pub const MAX_MEDIA_PER_TWEET: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaCategory {
    TweetImage,
    TweetGif,
    TweetVideo,
}

impl MediaCategory {
    pub const fn as_api(self) -> &'static str {
        match self {
            Self::TweetImage => "tweet_image",
            Self::TweetGif => "tweet_gif",
            Self::TweetVideo => "tweet_video",
        }
    }

    pub const fn needs_status_poll(self) -> bool {
        matches!(self, Self::TweetVideo)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UploadStrategy {
    SingleShot,
    Chunked { segments: u64 },
}

#[derive(Debug, Clone)]
pub struct MediaFile {
    pub path: PathBuf,
    pub mime: String,
    pub size: u64,
    pub category: MediaCategory,
}

impl MediaFile {
    pub fn from_path(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref().to_path_buf();
        let metadata = std::fs::metadata(&path).map_err(|e| {
            Error::Config(format!("cannot stat media file {}: {e}", path.display()))
        })?;
        if !metadata.is_file() {
            return Err(Error::Config(format!(
                "media path is not a regular file: {}",
                path.display()
            )));
        }
        let size = metadata.len();
        if size == 0 {
            return Err(Error::Config(format!(
                "media file is empty: {}",
                path.display()
            )));
        }

        let mime = mime_guess::from_path(&path)
            .first_or_octet_stream()
            .essence_str()
            .to_string();

        let category = classify(&mime).ok_or_else(|| {
            Error::Config(format!(
                "unsupported media type {mime} for {}; X accepts jpeg, png, webp, gif, mp4, mov",
                path.display()
            ))
        })?;

        Ok(Self {
            path,
            mime,
            size,
            category,
        })
    }

    pub fn strategy(&self) -> UploadStrategy {
        if self.category == MediaCategory::TweetVideo || self.size > SINGLE_SHOT_MAX {
            let segments = self.size.div_ceil(CHUNK_SIZE).max(1);
            UploadStrategy::Chunked { segments }
        } else {
            UploadStrategy::SingleShot
        }
    }
}

fn classify(mime: &str) -> Option<MediaCategory> {
    match mime {
        "image/jpeg" | "image/png" | "image/webp" => Some(MediaCategory::TweetImage),
        "image/gif" => Some(MediaCategory::TweetGif),
        "video/mp4" | "video/quicktime" => Some(MediaCategory::TweetVideo),
        _ => None,
    }
}

pub fn validate_set(files: &[MediaFile]) -> Result<()> {
    if files.len() > MAX_MEDIA_PER_TWEET {
        return Err(Error::Config(format!(
            "X allows at most {MAX_MEDIA_PER_TWEET} media attachments per tweet (got {})",
            files.len()
        )));
    }

    let videos = files
        .iter()
        .filter(|f| f.category == MediaCategory::TweetVideo)
        .count();
    let gifs = files
        .iter()
        .filter(|f| f.category == MediaCategory::TweetGif)
        .count();
    let images = files
        .iter()
        .filter(|f| f.category == MediaCategory::TweetImage)
        .count();

    if videos > 1 {
        return Err(Error::Config("X allows at most 1 video per tweet".into()));
    }
    if gifs > 1 {
        return Err(Error::Config(
            "X allows at most 1 animated gif per tweet".into(),
        ));
    }
    if (videos > 0 || gifs > 0) && images > 0 {
        return Err(Error::Config(
            "X does not allow mixing video/gif with images in the same tweet".into(),
        ));
    }
    if videos > 0 && gifs > 0 {
        return Err(Error::Config(
            "X does not allow both video and animated gif in the same tweet".into(),
        ));
    }

    Ok(())
}

const STATUS_POLL_MAX_ATTEMPTS: u32 = 60;
const STATUS_POLL_MIN_INTERVAL: Duration = Duration::from_secs(2);

pub struct MediaUploader<'a> {
    http: &'a reqwest::Client,
    access_token: &'a str,
}

impl<'a> MediaUploader<'a> {
    pub fn new(http: &'a reqwest::Client, access_token: &'a str) -> Self {
        Self { http, access_token }
    }

    pub async fn upload(&self, file: &MediaFile) -> Result<String> {
        match file.strategy() {
            UploadStrategy::SingleShot => self.upload_single_shot(file).await,
            UploadStrategy::Chunked { segments } => self.upload_chunked(file, segments).await,
        }
    }

    async fn upload_single_shot(&self, file: &MediaFile) -> Result<String> {
        tracing::debug!(
            "single-shot upload: {} ({} bytes, {})",
            file.path.display(),
            file.size,
            file.mime
        );
        let bytes = tokio::fs::read(&file.path).await.map_err(|e| {
            Error::Config(format!(
                "cannot read media file {}: {e}",
                file.path.display()
            ))
        })?;
        let file_name = file
            .path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("upload.bin")
            .to_string();

        let part = Part::bytes(bytes)
            .file_name(file_name)
            .mime_str(&file.mime)
            .map_err(|e| Error::Config(format!("bad media mime type: {e}")))?;
        let form = Form::new()
            .part("media", part)
            .text("media_category", file.category.as_api());

        let res = self
            .http
            .post(MEDIA_UPLOAD_URL)
            .bearer_auth(self.access_token)
            .multipart(form)
            .send()
            .await?;

        let value = parse_upload_response(res).await?;
        extract_media_id(&value)
    }

    async fn upload_chunked(&self, file: &MediaFile, segments: u64) -> Result<String> {
        tracing::debug!(
            "chunked upload: {} ({} bytes, {} segments, {})",
            file.path.display(),
            file.size,
            segments,
            file.mime
        );
        let media_id = self.init(file).await?;
        tracing::debug!("INIT → media_id {media_id}");

        let bytes = tokio::fs::read(&file.path).await.map_err(|e| {
            Error::Config(format!(
                "cannot read media file {}: {e}",
                file.path.display()
            ))
        })?;

        for (segment_index, chunk) in bytes.chunks(CHUNK_SIZE as usize).enumerate() {
            self.append(&media_id, segment_index as u64, chunk).await?;
            tracing::debug!("APPEND segment {} ({} bytes)", segment_index, chunk.len());
        }

        let finalize_response = self.finalize(&media_id).await?;
        tracing::debug!("FINALIZE complete");

        if file.category.needs_status_poll() || has_pending_processing_info(&finalize_response) {
            self.poll_status(&media_id).await?;
        }

        Ok(media_id)
    }

    async fn init(&self, file: &MediaFile) -> Result<String> {
        let form = Form::new()
            .text("command", "INIT")
            .text("total_bytes", file.size.to_string())
            .text("media_type", file.mime.clone())
            .text("media_category", file.category.as_api());

        let res = self
            .http
            .post(MEDIA_UPLOAD_URL)
            .bearer_auth(self.access_token)
            .multipart(form)
            .send()
            .await?;

        let value = parse_upload_response(res).await?;
        extract_media_id(&value)
    }

    async fn append(&self, media_id: &str, segment_index: u64, chunk: &[u8]) -> Result<()> {
        let part = Part::bytes(chunk.to_vec())
            .file_name("chunk")
            .mime_str("application/octet-stream")
            .map_err(|e| Error::Config(format!("bad chunk mime: {e}")))?;
        let form = Form::new()
            .text("command", "APPEND")
            .text("media_id", media_id.to_string())
            .text("segment_index", segment_index.to_string())
            .part("media", part);

        let res = self
            .http
            .post(MEDIA_UPLOAD_URL)
            .bearer_auth(self.access_token)
            .multipart(form)
            .send()
            .await?;

        let status = res.status();
        if !status.is_success() {
            let body = res.text().await.unwrap_or_default();
            return Err(classify_media_error(status.as_u16(), &body));
        }
        Ok(())
    }

    async fn finalize(&self, media_id: &str) -> Result<Value> {
        let form = Form::new()
            .text("command", "FINALIZE")
            .text("media_id", media_id.to_string());
        let res = self
            .http
            .post(MEDIA_UPLOAD_URL)
            .bearer_auth(self.access_token)
            .multipart(form)
            .send()
            .await?;
        parse_upload_response(res).await
    }

    async fn poll_status(&self, media_id: &str) -> Result<()> {
        for attempt in 0..STATUS_POLL_MAX_ATTEMPTS {
            let query = [("command", "STATUS"), ("media_id", media_id)];
            let res = self
                .http
                .get(MEDIA_UPLOAD_URL)
                .bearer_auth(self.access_token)
                .query(&query)
                .send()
                .await?;
            let value = parse_upload_response(res).await?;

            let processing = value
                .pointer("/data/processing_info")
                .or_else(|| value.get("processing_info"));
            let Some(info) = processing else {
                tracing::debug!("STATUS returned no processing_info; upload ready");
                return Ok(());
            };

            let state = info.get("state").and_then(Value::as_str).unwrap_or("");
            match state {
                "succeeded" => return Ok(()),
                "failed" => {
                    let reason = info
                        .pointer("/error/message")
                        .and_then(Value::as_str)
                        .unwrap_or("(no reason reported)");
                    return Err(Error::Config(format!("media processing failed: {reason}")));
                }
                _ => {}
            }

            let wait_secs = info
                .get("check_after_secs")
                .and_then(Value::as_u64)
                .unwrap_or(2)
                .max(2);
            tracing::debug!("STATUS attempt {attempt}: state={state:?}, next poll in {wait_secs}s");
            sleep(Duration::from_secs(wait_secs).max(STATUS_POLL_MIN_INTERVAL)).await;
        }
        Err(Error::Config(format!(
            "media processing did not complete after {STATUS_POLL_MAX_ATTEMPTS} status polls"
        )))
    }
}

async fn parse_upload_response(res: reqwest::Response) -> Result<Value> {
    let status = res.status();
    let body = res.text().await?;
    if !status.is_success() {
        return Err(classify_media_error(status.as_u16(), &body));
    }
    if body.is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&body).map_err(|e| {
        Error::GraphqlShape(format!(
            "media upload response was not valid json ({e}): {body}"
        ))
    })
}

fn extract_media_id(value: &Value) -> Result<String> {
    if let Some(id) = value.pointer("/data/id").and_then(Value::as_str) {
        return Ok(id.to_string());
    }
    if let Some(id) = value.get("media_id_string").and_then(Value::as_str) {
        return Ok(id.to_string());
    }
    if let Some(id) = value.get("media_id").and_then(Value::as_u64) {
        return Ok(id.to_string());
    }
    Err(Error::GraphqlShape(format!(
        "media upload response missing media id: {value}"
    )))
}

fn has_pending_processing_info(value: &Value) -> bool {
    value
        .pointer("/data/processing_info")
        .or_else(|| value.get("processing_info"))
        .is_some()
}

fn classify_media_error(status: u16, body: &str) -> Error {
    if status == 413 {
        return Error::Config(format!(
            "413: media file too large for this endpoint. Raw: {body}"
        ));
    }
    if status == 400 && body.contains("media type") {
        return Error::Config(format!(
            "400: X rejected the media type. Only jpeg, png, webp, gif, mp4, mov are supported. Raw: {body}"
        ));
    }
    if status == 401 {
        return Error::Config(format!(
            "401: access token rejected during media upload. \
             Delete ~/.config/unrager/tokens.json and re-authorize. Raw: {body}"
        ));
    }
    if status == 403 {
        return Error::Config(format!(
            "403: media upload forbidden. Check that your app has Read+Write scope \
             and that tweet.write is granted. Raw: {body}"
        ));
    }
    Error::GraphqlStatus {
        status,
        body: body.to_string(),
    }
}

pub fn format_size(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = 1024.0 * 1024.0;
    let b = bytes as f64;
    if b >= MB {
        format!("{:.1} MB", b / MB)
    } else if b >= KB {
        format!("{:.1} KB", b / KB)
    } else {
        format!("{bytes} B")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_tmp(name: &str, bytes: &[u8]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("unrager-media-tests-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(bytes).unwrap();
        path
    }

    #[test]
    fn classify_known_types() {
        assert_eq!(classify("image/jpeg"), Some(MediaCategory::TweetImage));
        assert_eq!(classify("image/png"), Some(MediaCategory::TweetImage));
        assert_eq!(classify("image/webp"), Some(MediaCategory::TweetImage));
        assert_eq!(classify("image/gif"), Some(MediaCategory::TweetGif));
        assert_eq!(classify("video/mp4"), Some(MediaCategory::TweetVideo));
        assert_eq!(classify("video/quicktime"), Some(MediaCategory::TweetVideo));
        assert_eq!(classify("image/bmp"), None);
        assert_eq!(classify("application/pdf"), None);
    }

    #[test]
    fn strategy_small_image_is_single_shot() {
        let f = MediaFile {
            path: "x.jpg".into(),
            mime: "image/jpeg".into(),
            size: 100_000,
            category: MediaCategory::TweetImage,
        };
        assert_eq!(f.strategy(), UploadStrategy::SingleShot);
    }

    #[test]
    fn strategy_large_image_is_chunked() {
        let f = MediaFile {
            path: "x.jpg".into(),
            mime: "image/jpeg".into(),
            size: 6 * 1024 * 1024,
            category: MediaCategory::TweetImage,
        };
        assert!(matches!(f.strategy(), UploadStrategy::Chunked { .. }));
    }

    #[test]
    fn strategy_video_always_chunked() {
        let f = MediaFile {
            path: "x.mp4".into(),
            mime: "video/mp4".into(),
            size: 100_000,
            category: MediaCategory::TweetVideo,
        };
        assert!(matches!(f.strategy(), UploadStrategy::Chunked { .. }));
    }

    #[test]
    fn strategy_segment_count_ceils_correctly() {
        let f = MediaFile {
            path: "x.mp4".into(),
            mime: "video/mp4".into(),
            size: CHUNK_SIZE * 2 + 1,
            category: MediaCategory::TweetVideo,
        };
        assert_eq!(f.strategy(), UploadStrategy::Chunked { segments: 3 });
    }

    fn sample_image() -> MediaFile {
        MediaFile {
            path: "a.jpg".into(),
            mime: "image/jpeg".into(),
            size: 1024,
            category: MediaCategory::TweetImage,
        }
    }
    fn sample_video() -> MediaFile {
        MediaFile {
            path: "a.mp4".into(),
            mime: "video/mp4".into(),
            size: 1024,
            category: MediaCategory::TweetVideo,
        }
    }
    fn sample_gif() -> MediaFile {
        MediaFile {
            path: "a.gif".into(),
            mime: "image/gif".into(),
            size: 1024,
            category: MediaCategory::TweetGif,
        }
    }

    #[test]
    fn validate_accepts_four_images() {
        let files = vec![
            sample_image(),
            sample_image(),
            sample_image(),
            sample_image(),
        ];
        assert!(validate_set(&files).is_ok());
    }

    #[test]
    fn validate_rejects_five_images() {
        let files = vec![
            sample_image(),
            sample_image(),
            sample_image(),
            sample_image(),
            sample_image(),
        ];
        assert!(validate_set(&files).is_err());
    }

    #[test]
    fn validate_rejects_two_videos() {
        let files = vec![sample_video(), sample_video()];
        assert!(validate_set(&files).is_err());
    }

    #[test]
    fn validate_rejects_video_plus_image() {
        let files = vec![sample_video(), sample_image()];
        assert!(validate_set(&files).is_err());
    }

    #[test]
    fn validate_rejects_gif_plus_image() {
        let files = vec![sample_gif(), sample_image()];
        assert!(validate_set(&files).is_err());
    }

    #[test]
    fn validate_accepts_single_video() {
        assert!(validate_set(&[sample_video()]).is_ok());
    }

    #[test]
    fn validate_accepts_single_gif() {
        assert!(validate_set(&[sample_gif()]).is_ok());
    }

    #[test]
    fn validate_accepts_empty() {
        assert!(validate_set(&[]).is_ok());
    }

    #[test]
    fn from_path_rejects_empty_file() {
        let p = write_tmp("empty.jpg", b"");
        assert!(MediaFile::from_path(&p).is_err());
    }

    #[test]
    fn from_path_rejects_missing_file() {
        assert!(MediaFile::from_path("/tmp/definitely-not-a-real-file-xyz-12345.jpg").is_err());
    }

    #[test]
    fn from_path_classifies_jpeg_by_extension() {
        let p = write_tmp("photo.jpg", b"\xff\xd8\xff\xe0fake jpeg");
        let f = MediaFile::from_path(&p).unwrap();
        assert_eq!(f.mime, "image/jpeg");
        assert_eq!(f.category, MediaCategory::TweetImage);
        assert_eq!(f.strategy(), UploadStrategy::SingleShot);
    }

    #[test]
    fn format_size_tiers() {
        assert_eq!(format_size(500), "500 B");
        assert_eq!(format_size(2048), "2.0 KB");
        assert_eq!(format_size(5 * 1024 * 1024), "5.0 MB");
    }
}
