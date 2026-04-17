use crate::model::{MediaKind, Tweet};
use std::path::{Path, PathBuf};

/// macOS splits by media kind: images/GIF-stills go through QuickLook
/// (`qlmanage -p`) so space/Esc returns focus to the terminal, while videos
/// go through `open` → QuickTime Player, because `qlmanage -p` throws an
/// NSInternalInconsistencyException on MP4s (it can't drive the video player
/// view). Linux uses `xdg-open` for everything and leans on the WM for focus.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenerKind {
    Image,
    Video,
}

#[cfg(target_os = "macos")]
pub fn opener_for(kind: OpenerKind) -> (&'static str, &'static [&'static str], bool) {
    match kind {
        OpenerKind::Image => ("qlmanage", &["-p"], true),
        OpenerKind::Video => ("open", &[], true),
    }
}

#[cfg(not(target_os = "macos"))]
pub fn opener_for(_kind: OpenerKind) -> (&'static str, &'static [&'static str], bool) {
    ("xdg-open", &[], false)
}

pub fn kind_for_extension(ext: &str) -> OpenerKind {
    match ext {
        "mp4" | "mov" => OpenerKind::Video,
        _ => OpenerKind::Image,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenTarget {
    pub url: String,
    pub path: PathBuf,
}

/// Collect every openable asset on a tweet, in display order.
/// Videos and GIFs use `video_url` (the playable mp4) when available, falling
/// back to the poster jpg so the user always gets *something*.
pub fn collect_open_targets(tweet: &Tweet, tweet_dir: &Path) -> Vec<OpenTarget> {
    let mut out = Vec::with_capacity(tweet.media.len());
    for (i, media) in tweet.media.iter().enumerate() {
        let url = match media.kind {
            MediaKind::Photo => media.url.clone(),
            MediaKind::Video | MediaKind::AnimatedGif => {
                media.video_url.clone().unwrap_or_else(|| media.url.clone())
            }
        };
        let path = tweet_dir.join(file_name_for(i, &url));
        out.push(OpenTarget { url, path });
    }
    out
}

fn file_name_for(idx: usize, url: &str) -> String {
    let ext = extension_for_url(url).unwrap_or("bin");
    format!("{idx:02}.{ext}")
}

fn extension_for_url(url: &str) -> Option<&'static str> {
    let path = url.split('?').next().unwrap_or(url);
    let path = path.split('#').next().unwrap_or(path);
    let segment = path.rsplit('/').next()?;
    let ext = segment.rsplit_once('.')?.1.to_ascii_lowercase();
    match ext.as_str() {
        "jpg" | "jpeg" => Some("jpg"),
        "png" => Some("png"),
        "gif" => Some("gif"),
        "webp" => Some("webp"),
        "mp4" => Some("mp4"),
        "mov" => Some("mov"),
        _ => None,
    }
}

pub async fn download_and_open(targets: Vec<OpenTarget>) -> Result<Vec<PathBuf>, String> {
    if targets.is_empty() {
        return Err("no media to open".into());
    }
    if let Some(parent) = targets[0].path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    let client = reqwest::Client::new();
    for t in &targets {
        if tokio::fs::try_exists(&t.path).await.unwrap_or(false) {
            tracing::debug!(path = %t.path.display(), "media cache hit, skipping download");
            continue;
        }
        tracing::info!(url = %t.url, path = %t.path.display(), "downloading media");
        let bytes = client
            .get(&t.url)
            .send()
            .await
            .map_err(|e| format!("fetch {}: {e}", t.url))?
            .error_for_status()
            .map_err(|e| format!("fetch {}: {e}", t.url))?
            .bytes()
            .await
            .map_err(|e| format!("read {}: {e}", t.url))?;
        tokio::fs::write(&t.path, &bytes)
            .await
            .map_err(|e| format!("write {}: {e}", t.path.display()))?;
    }

    let mut groups: Vec<(OpenerKind, Vec<PathBuf>)> = Vec::new();
    for t in &targets {
        let ext = t
            .path
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("bin")
            .to_ascii_lowercase();
        let kind = kind_for_extension(&ext);
        match groups.last_mut() {
            Some((k, paths)) if *k == kind => paths.push(t.path.clone()),
            _ => groups.push((kind, vec![t.path.clone()])),
        }
    }

    let mut opened: Vec<PathBuf> = Vec::new();
    for (kind, paths) in groups {
        let (program, prefix_args, multi_file) = opener_for(kind);
        let to_open: Vec<PathBuf> = if multi_file {
            paths.clone()
        } else {
            vec![paths[0].clone()]
        };
        opened.extend(to_open.clone());
        let prefix_args = prefix_args.to_vec();
        tracing::info!(
            program,
            ?prefix_args,
            count = to_open.len(),
            ?kind,
            "spawning external viewer"
        );
        tokio::task::spawn_blocking(move || {
            std::process::Command::new(program)
                .args(&prefix_args)
                .args(&to_open)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .map(|_| ())
                .map_err(|e| format!("{program} failed: {e}"))
        })
        .await
        .map_err(|e| format!("spawn join: {e}"))??;
    }
    Ok(opened)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Media, MediaKind, User};
    use chrono::Utc;

    fn tweet_with_media(id: &str, media: Vec<Media>) -> Tweet {
        Tweet {
            rest_id: id.into(),
            author: User {
                rest_id: "1".into(),
                handle: "u".into(),
                name: "U".into(),
                verified: false,
                followers: 0,
                following: 0,
            },
            created_at: Utc::now(),
            text: String::new(),
            reply_count: 0,
            retweet_count: 0,
            like_count: 0,
            quote_count: 0,
            view_count: None,
            favorited: false,
            retweeted: false,
            bookmarked: false,
            lang: None,
            in_reply_to_tweet_id: None,
            quoted_tweet: None,
            media,
            url: "https://x.com/u/status/1".into(),
        }
    }

    fn photo(url: &str) -> Media {
        Media {
            kind: MediaKind::Photo,
            url: url.into(),
            video_url: None,
            alt_text: None,
        }
    }

    fn video(poster: &str, video_url: Option<&str>) -> Media {
        Media {
            kind: MediaKind::Video,
            url: poster.into(),
            video_url: video_url.map(str::to_string),
            alt_text: None,
        }
    }

    fn gif(poster: &str, video_url: Option<&str>) -> Media {
        Media {
            kind: MediaKind::AnimatedGif,
            url: poster.into(),
            video_url: video_url.map(str::to_string),
            alt_text: None,
        }
    }

    #[test]
    fn collect_empty_when_no_media() {
        let t = tweet_with_media("1", vec![]);
        assert!(collect_open_targets(&t, Path::new("/tmp/t/1")).is_empty());
    }

    #[test]
    fn collect_multi_photo_preserves_order_and_indices() {
        let t = tweet_with_media(
            "1",
            vec![
                photo("https://pbs.twimg.com/media/a.jpg"),
                photo("https://pbs.twimg.com/media/b.png"),
                photo("https://pbs.twimg.com/media/c.webp"),
            ],
        );
        let targets = collect_open_targets(&t, Path::new("/c/1"));
        assert_eq!(targets.len(), 3);
        assert_eq!(targets[0].path, PathBuf::from("/c/1/00.jpg"));
        assert_eq!(targets[1].path, PathBuf::from("/c/1/01.png"));
        assert_eq!(targets[2].path, PathBuf::from("/c/1/02.webp"));
        assert!(targets[0].url.ends_with("a.jpg"));
    }

    #[test]
    fn collect_video_uses_video_url_not_poster() {
        let t = tweet_with_media(
            "9",
            vec![video(
                "https://pbs.twimg.com/poster.jpg",
                Some("https://video.twimg.com/v.mp4"),
            )],
        );
        let targets = collect_open_targets(&t, Path::new("/c/9"));
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].url, "https://video.twimg.com/v.mp4");
        assert_eq!(targets[0].path, PathBuf::from("/c/9/00.mp4"));
    }

    #[test]
    fn collect_video_without_variant_falls_back_to_poster() {
        let t = tweet_with_media("10", vec![video("https://pbs.twimg.com/poster.jpg", None)]);
        let targets = collect_open_targets(&t, Path::new("/c/10"));
        assert_eq!(targets.len(), 1);
        assert!(targets[0].url.ends_with("poster.jpg"));
        assert_eq!(targets[0].path, PathBuf::from("/c/10/00.jpg"));
    }

    #[test]
    fn collect_gif_uses_video_url_when_present() {
        let t = tweet_with_media(
            "11",
            vec![gif(
                "https://pbs.twimg.com/thumb.jpg",
                Some("https://video.twimg.com/g.mp4"),
            )],
        );
        let targets = collect_open_targets(&t, Path::new("/c/11"));
        assert_eq!(targets[0].url, "https://video.twimg.com/g.mp4");
        assert_eq!(targets[0].path.extension().unwrap(), "mp4");
    }

    #[test]
    fn collect_mixed_photo_video_preserves_display_order() {
        let t = tweet_with_media(
            "12",
            vec![
                photo("https://pbs.twimg.com/a.jpg"),
                video(
                    "https://pbs.twimg.com/poster.jpg",
                    Some("https://video.twimg.com/v.mp4"),
                ),
                photo("https://pbs.twimg.com/b.jpg"),
            ],
        );
        let targets = collect_open_targets(&t, Path::new("/c/12"));
        assert_eq!(targets.len(), 3);
        assert!(targets[0].url.ends_with("a.jpg"));
        assert_eq!(targets[1].url, "https://video.twimg.com/v.mp4");
        assert!(targets[2].url.ends_with("b.jpg"));
        assert_eq!(targets[0].path, PathBuf::from("/c/12/00.jpg"));
        assert_eq!(targets[1].path, PathBuf::from("/c/12/01.mp4"));
        assert_eq!(targets[2].path, PathBuf::from("/c/12/02.jpg"));
    }

    #[test]
    fn file_name_normalizes_jpeg_to_jpg() {
        assert_eq!(file_name_for(0, "https://ex.com/x.JPEG"), "00.jpg");
    }

    #[test]
    fn file_name_strips_query_string() {
        assert_eq!(
            file_name_for(
                1,
                "https://pbs.twimg.com/media/abc.jpg?format=jpg&name=large"
            ),
            "01.jpg"
        );
    }

    #[test]
    fn file_name_falls_back_to_bin_for_unknown_ext() {
        assert_eq!(file_name_for(0, "https://ex.com/noext"), "00.bin");
        assert_eq!(file_name_for(0, "https://ex.com/file.xyz"), "00.bin");
    }

    #[test]
    fn kind_for_extension_routes_videos_to_video_opener() {
        assert_eq!(kind_for_extension("mp4"), OpenerKind::Video);
        assert_eq!(kind_for_extension("mov"), OpenerKind::Video);
        assert_eq!(kind_for_extension("jpg"), OpenerKind::Image);
        assert_eq!(kind_for_extension("png"), OpenerKind::Image);
        assert_eq!(kind_for_extension("gif"), OpenerKind::Image);
        assert_eq!(kind_for_extension("webp"), OpenerKind::Image);
        assert_eq!(kind_for_extension("bin"), OpenerKind::Image);
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn macos_routes_images_to_quicklook_videos_to_open() {
        let (img_prog, img_prefix, _) = opener_for(OpenerKind::Image);
        assert_eq!(img_prog, "qlmanage");
        assert_eq!(img_prefix, &["-p"]);
        let (vid_prog, vid_prefix, _) = opener_for(OpenerKind::Video);
        assert_eq!(vid_prog, "open");
        assert!(vid_prefix.is_empty());
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn linux_uses_xdg_open_for_everything() {
        for kind in [OpenerKind::Image, OpenerKind::Video] {
            let (prog, prefix, multi) = opener_for(kind);
            assert_eq!(prog, "xdg-open");
            assert!(prefix.is_empty());
            assert!(!multi);
        }
    }
}
