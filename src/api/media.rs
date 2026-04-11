use crate::error::{Error, Result};
use std::path::{Path, PathBuf};

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
