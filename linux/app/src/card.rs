//! The tweet card — the atomic, reused widget rendered in feeds and threads.
//! Built imperatively (cards are data-driven and dynamic): avatar + author,
//! body, first media image, an optional quoted tweet, and the metric/like row.

use crate::shared::{Ctx, MediaRef};
use gtk::prelude::*;
use gtk::{glib, pango};
use std::cell::Cell;
use std::rc::Rc;
use unrager_gtk_core::MediaSize;
use unrager_gtk_core::format;
use unrager_gtk_core::model::{Media, MediaKind, Tweet};
use url::Url;

/// Callbacks a card raises to its host screen. `open_thread` is handled by the
/// list row activation, so a card only needs profile navigation, media viewing,
/// and toasts.
#[derive(Clone)]
pub struct CardCallbacks {
    pub open_profile: Rc<dyn Fn(String)>,
    /// `(tweet_id, viewable media refs, position to open at)`.
    pub open_media: Rc<dyn Fn(String, Vec<MediaRef>, usize)>,
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

    let avatar = adw::Avatar::new(44, Some(&tweet.author.name), true);
    ctx.load_avatar(&avatar, tweet.author.avatar_url.as_deref());

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
    name_line.append(&flag_mark(&tweet.author, ctx));
    if tweet.author.verified {
        name_line.append(&verified_mark());
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
    let permalink = tweet.url.clone();
    let media_size = ctx.media_size.get();
    let items: Vec<MediaRef> = viewable
        .iter()
        .map(|&i| MediaRef {
            index: i,
            video: matches!(
                tweet.media[i].kind,
                MediaKind::Video | MediaKind::AnimatedGif
            ),
        })
        .collect();

    let build = |pos: usize| -> (gtk::Picture, bool) {
        let media = &tweet.media[viewable[pos]];
        let playable = matches!(media.kind, MediaKind::Video | MediaKind::AnimatedGif);
        let picture = gtk::Picture::new();
        picture.set_content_fit(gtk::ContentFit::Cover);
        picture.set_overflow(gtk::Overflow::Hidden);
        picture.add_css_class("tweet-media");
        picture.set_cursor_from_name(Some("pointer"));
        // The proxy streams a video/GIF's raw MP4, which `gtk::Picture` can't
        // decode, so load the poster still (`media.url`) directly — photos go
        // through the proxy as before.
        if playable {
            if let Ok(url) = Url::parse(&media.url) {
                ctx.load_picture(&picture, url);
            }
        } else {
            ctx.load_picture(&picture, ctx.api.media_url(&id, viewable[pos]));
        }

        let open_media = cb.open_media.clone();
        let open_id = id.clone();
        let open_items = items.clone();
        let open = move || (open_media)(open_id.clone(), open_items.clone(), pos);

        let click = gtk::GestureClick::new();
        click.set_button(gtk::gdk::BUTTON_PRIMARY);
        let open_click = open.clone();
        click.connect_released(move |_, _, _, _| open_click());
        picture.add_controller(click);

        attach_image_menu(&picture, &media.url, &permalink, open);
        (picture, playable)
    };

    let shown = viewable.len().min(4);
    if shown == 1 {
        let (picture, playable) = build(0);
        picture.set_hexpand(true);
        let ratio = aspect_ratio(&tweet.media[viewable[0]]);
        // `aspect_box` grows the container's height to `width / ratio` as the
        // column widens, so the whole image shows (the picture alone reports a
        // constant-size request and `Cover` would crop a short box). `Large`
        // fills the column; the capped steps sit in a width clamp.
        let framed = crate::aspect::aspect_box(&with_play_badge(picture, playable), ratio);
        if media_size == MediaSize::Large {
            return Some(framed);
        }
        return Some(clamp_media_width(framed, media_size.max_width()));
    }

    let grid = gtk::Grid::new();
    grid.add_css_class("media-grid");
    grid.set_overflow(gtk::Overflow::Hidden);
    grid.set_row_spacing(3);
    grid.set_column_spacing(3);
    grid.set_column_homogeneous(true);
    grid.set_row_homogeneous(true);
    for pos in 0..shown {
        let column = (pos % 2) as i32;
        let row = (pos / 2) as i32;
        let (picture, playable) = build(pos);
        picture.set_height_request(170);
        grid.attach(&with_play_badge(picture, playable), column, row, 1, 1);
    }
    if media_size == MediaSize::Large {
        Some(grid.upcast())
    } else {
        Some(clamp_media_width(grid.upcast(), media_size.max_width()))
    }
}

/// The image's aspect ratio (width ÷ height) from the server-reported
/// dimensions, clamped so an extreme portrait/panorama stays sane, defaulting
/// to 16:9 when unknown. Fed to the `AspectFrame` that sizes inline media.
fn aspect_ratio(media: &Media) -> f32 {
    match (media.width, media.height) {
        (Some(w), Some(h)) if w > 0 && h > 0 => w as f32 / h as f32,
        _ => 16.0 / 9.0,
    }
    .clamp(1.0 / 1.3, 2.0)
}

/// Overlays a centered play badge on video/GIF media (which renders as its
/// poster still inline); photos pass through unchanged. The badge is
/// click-through so the picture's own open/menu gestures still fire.
fn with_play_badge(picture: gtk::Picture, playable: bool) -> gtk::Widget {
    if !playable {
        return picture.upcast();
    }
    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&picture));
    let badge = gtk::Image::from_icon_name("media-playback-start-symbolic");
    badge.set_pixel_size(44);
    badge.add_css_class("play-badge");
    badge.set_halign(gtk::Align::Center);
    badge.set_valign(gtk::Align::Center);
    badge.set_can_target(false);
    overlay.add_overlay(&badge);
    overlay.upcast()
}

/// The author's country flag directly after the display name, mirroring the
/// TUI. Starts hidden and fills in asynchronously once the session flag cache
/// resolves the author (synchronously on a cache hit); authors without a
/// country simply never show it. The tooltip carries the country name, since
/// a flag glyph alone can be ambiguous.
pub(crate) fn flag_mark(author: &unrager_gtk_core::model::User, ctx: &Ctx) -> gtk::Label {
    let flag = gtk::Label::new(None);
    flag.set_visible(false);
    flag.add_css_class("flag");
    let weak = flag.downgrade();
    ctx.resolve_about(&author.rest_id, &author.handle, move |info| {
        let Some(label) = weak.upgrade() else {
            return;
        };
        if let Some(emoji) = info.flag.as_deref() {
            label.set_text(emoji);
            label.set_tooltip_text(info.based_in.as_deref());
            label.set_visible(true);
        }
    });
    flag
}

/// A verified badge as a themed symbolic icon rather than a raw "✓" glyph, so
/// it aligns with the bold name, follows the accent colour, and is announced as
/// "Verified" to assistive tech instead of read as selectable text.
pub(crate) fn verified_mark() -> gtk::Image {
    let mark = gtk::Image::from_icon_name("emblem-ok-symbolic");
    mark.set_valign(gtk::Align::Center);
    mark.set_pixel_size(15);
    mark.add_css_class("verified");
    mark.set_tooltip_text(Some("Verified"));
    mark
}

/// Builds the right-click context menu for an inline image: open in the viewer,
/// copy/save the picture, and open/copy the image and post URLs — the native
/// `GtkPopoverMenu` over a `gio::Menu`, with one `gio` action per item.
fn attach_image_menu(
    picture: &gtk::Picture,
    media_url: &str,
    permalink: &str,
    open: impl Fn() + 'static,
) {
    let actions = gtk::gio::SimpleActionGroup::new();

    let open_action = gtk::gio::SimpleAction::new("open", None);
    open_action.connect_activate(move |_, _| open());
    actions.add_action(&open_action);

    let copy_action = gtk::gio::SimpleAction::new("copy", None);
    copy_action.connect_activate(glib::clone!(
        #[weak]
        picture,
        move |_, _| {
            if let Some(texture) = picture.paintable().and_downcast::<gtk::gdk::Texture>()
                && let Some(clipboard) = display_clipboard()
            {
                clipboard.set_texture(&texture);
            }
        }
    ));
    actions.add_action(&copy_action);

    let save_action = gtk::gio::SimpleAction::new("save", None);
    save_action.connect_activate(glib::clone!(
        #[weak]
        picture,
        move |_, _| save_image(&picture)
    ));
    actions.add_action(&save_action);

    let browser_action = gtk::gio::SimpleAction::new("browser", None);
    let browser_url = media_url.to_string();
    browser_action.connect_activate(glib::clone!(
        #[weak]
        picture,
        move |_, _| open_uri(&picture, &browser_url)
    ));
    actions.add_action(&browser_action);

    let address_action = gtk::gio::SimpleAction::new("copy-address", None);
    let address_url = media_url.to_string();
    address_action.connect_activate(move |_, _| {
        if let Some(clipboard) = display_clipboard() {
            clipboard.set_text(&address_url);
        }
    });
    actions.add_action(&address_action);

    let post_action = gtk::gio::SimpleAction::new("open-post", None);
    let post_url = permalink.to_string();
    post_action.connect_activate(glib::clone!(
        #[weak]
        picture,
        move |_, _| open_uri(&picture, &post_url)
    ));
    actions.add_action(&post_action);

    let link_action = gtk::gio::SimpleAction::new("copy-post-link", None);
    let link_url = permalink.to_string();
    link_action.connect_activate(move |_, _| {
        if let Some(clipboard) = display_clipboard() {
            clipboard.set_text(&link_url);
        }
    });
    actions.add_action(&link_action);

    picture.insert_action_group("img", Some(&actions));

    let menu = gtk::gio::Menu::new();
    let view_section = gtk::gio::Menu::new();
    view_section.append(Some("Open"), Some("img.open"));
    view_section.append(Some("Copy Image"), Some("img.copy"));
    view_section.append(Some("Save Image As…"), Some("img.save"));
    menu.append_section(None, &view_section);
    let image_section = gtk::gio::Menu::new();
    image_section.append(Some("Open Image in Browser"), Some("img.browser"));
    image_section.append(Some("Copy Image Address"), Some("img.copy-address"));
    menu.append_section(None, &image_section);
    let post_section = gtk::gio::Menu::new();
    post_section.append(Some("Open Tweet in Browser"), Some("img.open-post"));
    post_section.append(Some("Copy Tweet Link"), Some("img.copy-post-link"));
    menu.append_section(None, &post_section);

    let popover = gtk::PopoverMenu::from_model(Some(&menu));
    popover.set_parent(picture);
    popover.set_has_arrow(false);
    popover.set_halign(gtk::Align::Start);

    let gesture = gtk::GestureClick::new();
    gesture.set_button(gtk::gdk::BUTTON_SECONDARY);
    gesture.connect_pressed(glib::clone!(
        #[weak]
        popover,
        move |gesture, _, x, y| {
            gesture.set_state(gtk::EventSequenceState::Claimed);
            popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            popover.popup();
        }
    ));
    picture.add_controller(gesture);

    picture.connect_destroy(glib::clone!(
        #[weak]
        popover,
        move |_| popover.unparent()
    ));
}

/// The display's clipboard, reachable without a widget — so copy actions don't
/// have to capture (and thus keep alive) the picture they belong to.
fn display_clipboard() -> Option<gtk::gdk::Clipboard> {
    gtk::gdk::Display::default().map(|display| display.clipboard())
}

/// Opens `uri` in the user's browser via the portal-aware `GtkUriLauncher`.
fn open_uri(widget: &impl IsA<gtk::Widget>, uri: &str) {
    let parent = widget.root().and_downcast::<gtk::Window>();
    gtk::UriLauncher::new(uri).launch(parent.as_ref(), gtk::gio::Cancellable::NONE, |_| {});
}

/// Saves the picture's decoded texture to a user-chosen file as PNG.
fn save_image(picture: &gtk::Picture) {
    let Some(texture) = picture.paintable().and_downcast::<gtk::gdk::Texture>() else {
        return;
    };
    let parent = picture.root().and_downcast::<gtk::Window>();
    let dialog = gtk::FileDialog::builder()
        .title("Save Image")
        .initial_name("image.png")
        .build();
    dialog.save(
        parent.as_ref(),
        gtk::gio::Cancellable::NONE,
        move |result| {
            if let Ok(file) = result
                && let Some(path) = file.path()
            {
                let bytes = texture.save_to_png_bytes();
                if let Err(error) = std::fs::write(&path, bytes.as_ref()) {
                    tracing::warn!(target: "ui", "save image failed: {error}");
                }
            }
        },
    );
}

/// Caps inline media at `max_width`, centered when the window is wider. A
/// horizontal `AdwClamp` is the reliable width constraint — capping height
/// instead lets a vertical clamp mis-measure a `height-for-width` picture and
/// crop it. A lone image (`Contain`) is shown whole; the 2×2 grid keeps its
/// fixed tile heights.
fn clamp_media_width(child: gtk::Widget, max_width: i32) -> gtk::Widget {
    let clamp = adw::Clamp::builder()
        .maximum_size(max_width)
        .child(&child)
        .build();
    clamp.set_hexpand(true);
    clamp.upcast()
}

fn is_viewable(kind: &MediaKind) -> bool {
    matches!(
        kind,
        MediaKind::Photo | MediaKind::Video | MediaKind::AnimatedGif
    )
}

fn quoted_block(quoted: &Tweet, ctx: &Ctx) -> gtk::Widget {
    let block = gtk::Box::new(gtk::Orientation::Vertical, 4);
    block.add_css_class("quoted-tweet");

    let head_row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let avatar = adw::Avatar::new(20, Some(&quoted.author.name), true);
    ctx.load_avatar(&avatar, quoted.author.avatar_url.as_deref());
    head_row.append(&avatar);

    let head = gtk::Label::new(Some(&format!(
        "{}  @{}",
        quoted.author.name, quoted.author.handle
    )));
    head.set_xalign(0.0);
    head.set_ellipsize(pango::EllipsizeMode::End);
    head.add_css_class("quoted-head");
    head_row.append(&head);
    block.append(&head_row);

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
    let favorited_at_build = tweet.favorited;
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
        let new_count = like_count_after(base_count, favorited_at_build, now);
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

/// The like count to show after an optimistic like/unlike toggle, relative to
/// the state the card was built with: the build-time count already includes the
/// user's own like when the tweet arrived favorited, so returning to the
/// build-time state restores the build-time count, and only a genuine
/// transition away from it moves the count by one.
fn like_count_after(count_at_build: u64, favorited_at_build: bool, liked_now: bool) -> u64 {
    if liked_now == favorited_at_build {
        count_at_build
    } else if liked_now {
        count_at_build + 1
    } else {
        count_at_build.saturating_sub(1)
    }
}

#[cfg(test)]
mod tests {
    use super::like_count_after;

    #[test]
    fn already_favorited_round_trip_restores_count() {
        assert_eq!(like_count_after(10, true, false), 9);
        assert_eq!(like_count_after(10, true, true), 10);
    }

    #[test]
    fn not_favorited_round_trip_restores_count() {
        assert_eq!(like_count_after(10, false, true), 11);
        assert_eq!(like_count_after(10, false, false), 10);
    }

    #[test]
    fn unlike_never_underflows() {
        assert_eq!(like_count_after(0, true, false), 0);
    }
}
