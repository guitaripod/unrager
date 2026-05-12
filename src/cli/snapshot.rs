//! Headless full-frame screenshot CLI. Constructs a real `App` against
//! the user's logged-in X session, fetches whatever a given view needs,
//! eagerly decodes every visible avatar and media image to RGBA in
//! memory, registers them with the snapshot-mode media registry, then
//! runs a single `ui::draw` pass against a ratatui `TestBackend` and
//! rasterizes the resulting buffer to PNG with images composited over
//! the kitty placeholder cells. Used to regenerate the site carousel
//! without manual terminal capture.
//!
//! Each view (home, detail, ask, compose, search, notifications,
//! profile, help) seeds the App's mode + focus stack + source state
//! directly — bypassing the live TUI's async event loop — so the output
//! is deterministic and reproducible.

use clap::{Args as ClapArgs, ValueEnum};
use image::RgbaImage;
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use crate::error::{Error, Result};
use crate::model::{MediaKind, Tweet};
use crate::parse::notification::RawNotification;
use crate::tui::app::{ActivePane, App, InputMode};
use crate::tui::compose::ReplyBar;
use crate::tui::focus::{FocusEntry, NotificationsView, TweetDetail};
use crate::tui::media::{CellSize, MediaEntry, MediaRegistry};
use crate::tui::snapshot::{RasterizeArgs, rasterize_full_frame};
use crate::tui::source::{self, Source, SourceKind};
use crate::tui::{focus, theme, ui, whisper};

#[derive(Debug, ClapArgs)]
pub struct Args {
    /// Which view to capture.
    #[arg(long, value_enum)]
    pub view: View,

    /// Output PNG path.
    #[arg(long)]
    pub out: PathBuf,

    /// Logical column count of the synthetic terminal.
    #[arg(long, default_value_t = 160)]
    pub cols: u16,

    /// Logical row count of the synthetic terminal.
    #[arg(long, default_value_t = 48)]
    pub rows: u16,

    /// Cell width in pixels.
    #[arg(long = "cell-w", default_value_t = 12)]
    pub cell_w: u32,

    /// Cell height in pixels.
    #[arg(long = "cell-h", default_value_t = 25)]
    pub cell_h: u32,

    /// Search query (used by `--view search`).
    #[arg(long)]
    pub query: Option<String>,

    /// Profile handle (used by `--view profile`; defaults to your own handle).
    #[arg(long)]
    pub user: Option<String>,

    /// Specific tweet ID to focus (used by `--view detail`, `--view ask`,
    /// `--view compose`; defaults to the first tweet in the home feed).
    #[arg(long)]
    pub tweet: Option<String>,

    /// Theme to render under. Defaults to `x-dark`.
    #[arg(long, default_value = "x-dark")]
    pub theme: String,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum View {
    Home,
    Detail,
    Notifications,
    Profile,
    Search,
    Help,
    Ask,
    Compose,
}

pub async fn run(args: Args) -> Result<()> {
    // SAFETY: set before any tokio task reads the env var.
    unsafe { std::env::set_var("UNRAGER_DISABLE_KITTY", "1") };

    let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
    let mut app = App::new(tx, true).await?;

    let cell = CellSize {
        w: args.cell_w,
        h: args.cell_h,
    };
    app.media = MediaRegistry::for_snapshot(cell);
    app.feed_avatars = true;

    if let Some(theme) = theme::Theme::by_name(&args.theme, true) {
        app.is_dark = theme.is_dark;
        app.theme_name = theme.name.to_string();
        theme::set_active(theme);
    }

    if app.self_handle.is_none() {
        match source::fetch_self_handle(&app.client).await {
            Ok(h) => app.self_handle = Some(h),
            Err(e) => tracing::warn!("self handle resolve failed (continuing): {e}"),
        }
    }

    let mut images: HashMap<u32, RgbaImage> = HashMap::new();
    seed_state(&mut app, &args).await?;
    prefetch_visible_images(&mut app, &mut images).await;

    let backend = TestBackend::new(args.cols, args.rows);
    let mut terminal = Terminal::new(backend)
        .map_err(|e| Error::Config(format!("TestBackend init failed: {e}")))?;
    terminal
        .draw(|frame| ui::draw(frame, &mut app))
        .map_err(|e| Error::Config(format!("draw failed: {e}")))?;

    let buf = terminal.backend().buffer().clone();

    let snapshot = {
        let theme = theme::active();
        rasterize_full_frame(RasterizeArgs {
            buf: &buf,
            theme: &theme,
            cell,
            images: &images,
        })
    };

    if let Some(parent) = args.out.parent() {
        std::fs::create_dir_all(parent)?;
    }
    snapshot
        .save(&args.out)
        .map_err(|e| Error::Config(format!("save {}: {e}", args.out.display())))?;
    println!("wrote {}", args.out.display());
    Ok(())
}

async fn seed_state(app: &mut App, args: &Args) -> Result<()> {
    match args.view {
        View::Home => {
            load_home(app).await?;
        }
        View::Detail => {
            load_home(app).await?;
            push_detail_focus(app, args.tweet.as_deref()).await?;
        }
        View::Notifications => {
            load_home(app).await?;
            push_notifications_focus(app).await?;
        }
        View::Profile => {
            let handle = args
                .user
                .clone()
                .or_else(|| app.self_handle.clone())
                .ok_or_else(|| Error::Config("no --user and no logged-in handle".into()))?;
            load_user(app, &handle).await?;
        }
        View::Search => {
            let query = args
                .query
                .clone()
                .ok_or_else(|| Error::Config("--view search requires --query".into()))?;
            load_search(app, &query).await?;
        }
        View::Help => {
            load_home(app).await?;
            app.mode = InputMode::Help;
        }
        View::Ask => {
            load_home(app).await?;
            push_ask_focus(app, args.tweet.as_deref()).await?;
        }
        View::Compose => {
            load_home(app).await?;
            push_compose_focus(app, args.tweet.as_deref()).await?;
        }
    }
    Ok(())
}

async fn load_home(app: &mut App) -> Result<()> {
    let kind = SourceKind::Home { following: false };
    let page = source::fetch_page(&app.client, &kind, None).await?;
    app.source = Source::new(kind);
    app.source.reset_with(page);
    Ok(())
}

async fn load_user(app: &mut App, handle: &str) -> Result<()> {
    let kind = SourceKind::User {
        handle: handle.to_string(),
    };
    let page = source::fetch_page(&app.client, &kind, None).await?;
    app.source = Source::new(kind);
    let profile = page.profile_user.clone();
    app.source.reset_with(page);
    app.source.profile_user = profile;
    Ok(())
}

async fn load_search(app: &mut App, query: &str) -> Result<()> {
    let kind = SourceKind::Search {
        query: query.to_string(),
        product: source::SearchProduct::Top,
    };
    let page = source::fetch_page(&app.client, &kind, None).await?;
    app.source = Source::new(kind);
    app.source.reset_with(page);
    Ok(())
}

async fn push_detail_focus(app: &mut App, tweet_id: Option<&str>) -> Result<()> {
    let tweet = pick_focal_tweet(app, tweet_id)?;
    let mut detail = TweetDetail::new(tweet);
    let page = focus::fetch_thread(&app.client, &detail.tweet.rest_id).await?;
    detail.apply_page(page);
    app.focus_stack.push(FocusEntry::Tweet(detail));
    app.active = ActivePane::Detail;
    Ok(())
}

async fn push_notifications_focus(app: &mut App) -> Result<()> {
    let mut view = NotificationsView::new();
    match whisper::fetch_notifications(&app.client, None).await {
        Ok(page) => {
            tracing::info!(
                count = page.notifications.len(),
                "snapshot: notifications loaded"
            );
            view.reset_with(page);
        }
        Err(e) => {
            tracing::warn!("snapshot: notifications fetch failed: {e}");
            let _: Vec<RawNotification> = Vec::new();
            view.error = Some(e.to_string());
        }
    }
    view.loading = false;
    app.focus_stack.push(FocusEntry::Notifications(view));
    app.active = ActivePane::Detail;
    Ok(())
}

async fn push_ask_focus(app: &mut App, tweet_id: Option<&str>) -> Result<()> {
    let tweet = pick_focal_tweet(app, tweet_id)?;
    let mut ask = crate::tui::ask::AskView::new(tweet.clone(), Vec::new(), false);
    ask.push_user_message(crate::tui::ask::DEFAULT_PROMPT.into());
    let canned = sample_ask_response(&tweet);
    for chunk in canned.split_inclusive(char::is_whitespace) {
        ask.append_token(chunk);
    }
    ask.mark_done(None);
    app.focus_stack.push(FocusEntry::Ask(ask));
    app.active = ActivePane::Detail;
    Ok(())
}

async fn push_compose_focus(app: &mut App, tweet_id: Option<&str>) -> Result<()> {
    push_detail_focus(app, tweet_id).await?;
    if let Some(FocusEntry::Tweet(detail)) = app.focus_stack.last_mut() {
        let mut bar = ReplyBar::new();
        let body = "the part I'd push back on is that the framing makes this sound binary — there's a third axis nobody's measuring yet";
        bar.editor.input = body.into();
        bar.editor.cursor_pos = bar.editor.input.chars().count();
        detail.reply_bar = Some(bar);
    }
    Ok(())
}

fn pick_focal_tweet(app: &App, tweet_id: Option<&str>) -> Result<Tweet> {
    match tweet_id {
        Some(id) => app
            .source
            .tweets
            .iter()
            .find(|t| t.rest_id == id)
            .cloned()
            .ok_or_else(|| Error::Config(format!("tweet {id} not in home feed"))),
        None => app
            .source
            .tweets
            .iter()
            .find(|t| !t.media.is_empty())
            .or_else(|| app.source.tweets.first())
            .cloned()
            .ok_or_else(|| Error::Config("home feed empty".into())),
    }
}

fn sample_ask_response(tweet: &Tweet) -> String {
    format!(
        "The post is from @{} and reads as a short, opinionated take. \
         The core claim is that the topic in question is worth attention, \
         framed as a contrast between expectation and reality.\n\n\
         The replies, if you skim them, mostly agree with the framing and \
         pile on with their own anecdotes — there is one short thread of \
         pushback further down asking whether the framing actually generalises.\n\n\
         If you want a steelman: the strongest version of the post is that \
         the gap between how people describe X and how X actually plays out \
         is wide enough to be worth a name.",
        tweet.author.handle
    )
}

/// Walk every place the renderer will display a tweet (source list,
/// detail pane, ask pane, inline threads) and download + decode every
/// avatar / media URL we'll need, registering each with the snapshot
/// media registry so the UI emits a `placeholder_lines` block at the
/// right grid cells.
async fn prefetch_visible_images(app: &mut App, images: &mut HashMap<u32, RgbaImage>) {
    let mut urls: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    let push = |url: Option<&str>, urls: &mut Vec<String>, seen: &mut HashSet<String>| {
        let Some(u) = url else { return };
        if u.is_empty() || !seen.insert(u.to_string()) {
            return;
        }
        urls.push(u.to_string());
    };

    if let Some(p) = app.source.profile_user.as_ref() {
        push(p.avatar_url.as_deref(), &mut urls, &mut seen);
    }
    for tweet in &app.source.tweets {
        collect_tweet_urls(tweet, &mut urls, &mut seen);
    }
    if let Some(focus) = app.focus_stack.last() {
        match focus {
            FocusEntry::Tweet(d) => {
                collect_tweet_urls(&d.tweet, &mut urls, &mut seen);
                for r in &d.replies {
                    collect_tweet_urls(r, &mut urls, &mut seen);
                }
            }
            FocusEntry::Ask(a) => {
                collect_tweet_urls(&a.tweet, &mut urls, &mut seen);
            }
            FocusEntry::Notifications(n) => {
                for notif in &n.notifications {
                    for actor in &notif.actors {
                        push(actor.avatar_url.as_deref(), &mut urls, &mut seen);
                    }
                }
            }
            _ => {}
        }
    }

    tracing::info!(count = urls.len(), "snapshot: prefetching images");
    let client = reqwest::Client::new();
    for url in urls {
        let cache = app.media.avatar_cache_path(&url);
        let bytes = match fetch_bytes(&client, &url, cache.as_deref()).await {
            Some(b) => b,
            None => continue,
        };
        let decoded = tokio::task::spawn_blocking(move || image::load_from_memory(&bytes))
            .await
            .ok()
            .and_then(|r| r.ok())
            .map(|img| img.into_rgba8());
        let Some(rgba) = decoded else {
            tracing::warn!(%url, "snapshot: decode failed");
            continue;
        };
        let (w, h) = rgba.dimensions();
        if app.media.entries.contains_key(&url) {
            // Already registered (avatar reused across multiple tweets,
            // for instance). Find its existing id and reuse the same
            // pixels under that id rather than allocating a new one.
            if let Some(MediaEntry::ReadyKitty { id, .. }) = app.media.entries.get(&url) {
                images.insert(*id, rgba);
            }
            continue;
        }
        let id = app.media.assign_id();
        app.media.register_snapshot_kitty(&url, id, w, h);
        images.insert(id, rgba);
    }
}

fn collect_tweet_urls(tweet: &Tweet, urls: &mut Vec<String>, seen: &mut HashSet<String>) {
    if let Some(url) = tweet.author.avatar_url.as_deref() {
        if !url.is_empty() && seen.insert(url.to_string()) {
            urls.push(url.to_string());
        }
    }
    for m in &tweet.media {
        if matches!(
            m.kind,
            MediaKind::Photo
                | MediaKind::Video
                | MediaKind::AnimatedGif
                | MediaKind::YouTube { .. }
                | MediaKind::Article { .. }
                | MediaKind::LinkCard { .. }
        ) && !m.url.is_empty()
            && seen.insert(m.url.clone())
        {
            urls.push(m.url.clone());
        }
    }
    if let Some(qt) = &tweet.quoted_tweet {
        collect_tweet_urls(qt, urls, seen);
    }
}

async fn fetch_bytes(
    client: &reqwest::Client,
    url: &str,
    cache_path: Option<&std::path::Path>,
) -> Option<Vec<u8>> {
    if let Some(path) = cache_path {
        if let Ok(b) = tokio::fs::read(path).await {
            if !b.is_empty() {
                return Some(b);
            }
        }
    }
    let resp = client.get(url).send().await.ok()?.error_for_status().ok()?;
    let bytes = resp.bytes().await.ok()?.to_vec();
    if let Some(path) = cache_path {
        if let Some(parent) = path.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        let tmp = path.with_extension("bin.tmp");
        if tokio::fs::write(&tmp, &bytes).await.is_ok() {
            let _ = tokio::fs::rename(&tmp, path).await;
        }
    }
    Some(bytes)
}
