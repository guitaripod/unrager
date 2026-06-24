//! The tweet card — the atomic, reused widget rendered in feeds and threads.
//! Built imperatively (cards are data-driven and dynamic): avatar + author,
//! body, first media image, an optional quoted tweet, and the metric/like row.

use crate::shared::Ctx;
use gtk::prelude::*;
use gtk::{glib, pango};
use std::cell::Cell;
use std::rc::Rc;
use unrager_gtk_core::format;
use unrager_gtk_core::model::{MediaKind, Tweet};
use url::Url;

/// Callbacks a card raises to its host screen. `open_thread` is handled by the
/// list row activation, so a card only needs profile navigation, media viewing,
/// and toasts.
#[derive(Clone)]
pub struct CardCallbacks {
    pub open_profile: Rc<dyn Fn(String)>,
    /// `(tweet_id, viewable media indices, position to open at)`.
    pub open_media: Rc<dyn Fn(String, Vec<usize>, usize)>,
    pub toast: Rc<dyn Fn(String)>,
}

pub fn build_tweet_card(tweet: &Tweet, ctx: &Ctx, cb: &CardCallbacks) -> gtk::Widget {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 8);
    card.add_css_class("tweet-card");

    card.append(&header_row(tweet, ctx, cb));

    if !tweet.text.is_empty() {
        let body = gtk::Label::new(Some(&tweet.text));
        body.set_wrap(true);
        body.set_wrap_mode(pango::WrapMode::WordChar);
        body.set_xalign(0.0);
        body.set_selectable(true);
        body.add_css_class("tweet-body");
        card.append(&body);
    }

    if let Some(media) = media_widget(tweet, ctx, cb) {
        card.append(&media);
    }

    if let Some(quoted) = &tweet.quoted_tweet {
        card.append(&quoted_block(quoted, ctx));
    }

    card.append(&action_row(tweet, ctx, cb));
    card.upcast()
}

fn header_row(tweet: &Tweet, ctx: &Ctx, cb: &CardCallbacks) -> gtk::Widget {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);

    let avatar = gtk::Picture::new();
    avatar.set_size_request(44, 44);
    avatar.set_content_fit(gtk::ContentFit::Cover);
    avatar.add_css_class("avatar");
    if let Some(url) = tweet
        .author
        .avatar_url
        .as_deref()
        .and_then(|u| Url::parse(u).ok())
    {
        ctx.images.load(&avatar, ctx.api.clone(), url);
    }

    let avatar_btn = gtk::Button::builder()
        .child(&avatar)
        .valign(gtk::Align::Start)
        .build();
    avatar_btn.add_css_class("avatar-button");
    avatar_btn.add_css_class("flat");
    let handle = tweet.author.handle.clone();
    let open_profile = cb.open_profile.clone();
    avatar_btn.connect_clicked(move |_| (open_profile)(handle.clone()));
    row.append(&avatar_btn);

    let names = gtk::Box::new(gtk::Orientation::Vertical, 0);
    names.set_hexpand(true);
    names.set_valign(gtk::Align::Center);

    let name_line = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    let name = gtk::Label::new(Some(&tweet.author.name));
    name.set_xalign(0.0);
    name.set_ellipsize(pango::EllipsizeMode::End);
    name.add_css_class("tweet-name");
    name_line.append(&name);
    if tweet.author.verified {
        let mark = gtk::Label::new(Some("✓"));
        mark.add_css_class("verified");
        name_line.append(&mark);
    }
    names.append(&name_line);

    let meta = gtk::Label::new(Some(&format!(
        "@{} · {}",
        tweet.author.handle,
        format::relative_time(tweet.created_at, chrono::Utc::now())
    )));
    meta.set_xalign(0.0);
    meta.set_ellipsize(pango::EllipsizeMode::End);
    meta.add_css_class("tweet-meta");
    names.append(&meta);

    row.append(&names);
    row.upcast()
}

fn media_widget(tweet: &Tweet, ctx: &Ctx, cb: &CardCallbacks) -> Option<gtk::Widget> {
    let viewable: Vec<usize> = tweet
        .media
        .iter()
        .enumerate()
        .filter(|(_, m)| is_viewable(&m.kind))
        .map(|(i, _)| i)
        .collect();
    if viewable.is_empty() {
        return None;
    }

    let id = tweet.rest_id.clone();
    let cell = |pos: usize, height: i32| -> gtk::Picture {
        let picture = gtk::Picture::new();
        picture.set_height_request(height);
        picture.set_content_fit(gtk::ContentFit::Cover);
        picture.add_css_class("tweet-media");
        picture.set_cursor_from_name(Some("pointer"));
        ctx.images.load(
            &picture,
            ctx.api.clone(),
            ctx.api.media_url(&id, viewable[pos]),
        );

        let gesture = gtk::GestureClick::new();
        let open_media = cb.open_media.clone();
        let id = id.clone();
        let viewable = viewable.clone();
        gesture.connect_released(move |_, _, _, _| (open_media)(id.clone(), viewable.clone(), pos));
        picture.add_controller(gesture);
        picture
    };

    let shown = viewable.len().min(4);
    if shown == 1 {
        return Some(cell(0, 300).upcast());
    }

    let grid = gtk::Grid::new();
    grid.add_css_class("media-grid");
    grid.set_row_spacing(3);
    grid.set_column_spacing(3);
    grid.set_column_homogeneous(true);
    grid.set_row_homogeneous(true);
    for pos in 0..shown {
        let column = (pos % 2) as i32;
        let row = (pos / 2) as i32;
        grid.attach(&cell(pos, 170), column, row, 1, 1);
    }
    Some(grid.upcast())
}

fn is_viewable(kind: &MediaKind) -> bool {
    matches!(
        kind,
        MediaKind::Photo | MediaKind::Video | MediaKind::AnimatedGif
    )
}

fn quoted_block(quoted: &Tweet, _ctx: &Ctx) -> gtk::Widget {
    let block = gtk::Box::new(gtk::Orientation::Vertical, 4);
    block.add_css_class("quoted-tweet");

    let head = gtk::Label::new(Some(&format!(
        "{}  @{}",
        quoted.author.name, quoted.author.handle
    )));
    head.set_xalign(0.0);
    head.set_ellipsize(pango::EllipsizeMode::End);
    head.add_css_class("quoted-head");
    block.append(&head);

    if !quoted.text.is_empty() {
        let body = gtk::Label::new(Some(&quoted.text));
        body.set_wrap(true);
        body.set_xalign(0.0);
        body.add_css_class("quoted-body");
        block.append(&body);
    }
    block.upcast()
}

fn metric_box(icon: &str, count: u64) -> gtk::Box {
    let b = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    b.add_css_class("metric");
    b.append(&gtk::Image::from_icon_name(icon));
    let label = gtk::Label::new(Some(&format::count(count as i64)));
    label.add_css_class("metric-count");
    b.append(&label);
    b
}

fn action_row(tweet: &Tweet, ctx: &Ctx, cb: &CardCallbacks) -> gtk::Widget {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 14);
    row.add_css_class("tweet-actions");

    row.append(&metric_box("mail-reply-sender-symbolic", tweet.reply_count));
    row.append(&metric_box(
        "media-playlist-repeat-symbolic",
        tweet.retweet_count,
    ));
    row.append(&like_button(tweet, ctx, cb));
    row.append(&metric_box(
        "view-reveal-symbolic",
        tweet.view_count.unwrap_or(0),
    ));
    row.upcast()
}

fn like_button(tweet: &Tweet, ctx: &Ctx, cb: &CardCallbacks) -> gtk::Widget {
    let inner = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    inner.append(&gtk::Image::from_icon_name("emblem-favorite-symbolic"));
    let label = gtk::Label::new(Some(&format::count(tweet.like_count as i64)));
    label.add_css_class("metric-count");
    inner.append(&label);

    let button = gtk::Button::builder().child(&inner).build();
    button.add_css_class("flat");
    button.add_css_class("metric");
    button.add_css_class("like");
    if tweet.favorited {
        button.add_css_class("liked");
    }

    let liked = Rc::new(Cell::new(tweet.favorited));
    let base_count = tweet.like_count;
    let api = ctx.api.clone();
    let id = tweet.rest_id.clone();
    let toast = cb.toast.clone();

    button.connect_clicked(move |button| {
        let now = !liked.get();
        liked.set(now);
        if now {
            button.add_css_class("liked");
        } else {
            button.remove_css_class("liked");
        }
        let new_count = if now {
            base_count + 1
        } else {
            base_count.saturating_sub(1)
        };
        label.set_label(&format::count(new_count as i64));

        let api = api.clone();
        let id = id.clone();
        let toast = toast.clone();
        let (tx, rx) = tokio::sync::oneshot::channel::<Option<String>>();
        relm4::spawn(async move {
            let result = if now {
                api.like(&id).await
            } else {
                api.unlike(&id).await
            };
            let _ = tx.send(result.err().map(|e| e.user_message()));
        });
        glib::spawn_future_local(async move {
            if let Ok(Some(message)) = rx.await {
                (toast)(message);
            }
        });
    });

    button.upcast()
}
