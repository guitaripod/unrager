//! Off-main image loading into `gtk::Picture`.
//!
//! The Linux analog of `UnragerKit/Imaging/ImagePipeline.swift`: fetch encoded
//! bytes on the tokio runtime (reqwest is `Send`), hop back to the GTK main
//! thread, decode into a `gdk::Texture`, cache it (URL-keyed LRU), and set it as
//! the picture's paintable. Late results for a recycled widget are harmless —
//! the picture handle is captured per call.

use gtk::gdk;
use gtk::glib;
use lru::LruCache;
use std::cell::RefCell;
use std::num::NonZeroUsize;
use std::rc::Rc;
use std::sync::Arc;
use unrager_gtk_core::ApiClient;
use url::Url;

#[derive(Clone)]
pub struct ImagePipeline {
    cache: Rc<RefCell<LruCache<String, gdk::Texture>>>,
}

impl Default for ImagePipeline {
    fn default() -> Self {
        Self::new()
    }
}

impl ImagePipeline {
    pub fn new() -> Self {
        Self {
            cache: Rc::new(RefCell::new(LruCache::new(
                NonZeroUsize::new(512).expect("nonzero"),
            ))),
        }
    }

    fn cached(&self, key: &str) -> Option<gdk::Texture> {
        self.cache.borrow_mut().get(key).cloned()
    }

    fn insert(&self, key: String, texture: gdk::Texture) {
        self.cache.borrow_mut().put(key, texture);
    }

    /// Loads `url` into `picture`. Returns immediately; the paintable is set when
    /// the bytes arrive and decode.
    pub fn load(&self, picture: &gtk::Picture, api: Arc<ApiClient>, url: Url) {
        let picture = picture.clone();
        self.load_with(api, url, move |texture| {
            picture.set_paintable(Some(texture));
        });
    }

    /// Loads `url` as an `adw::Avatar`'s custom image — the dedicated avatar
    /// widget keeps a fixed, circular frame no matter the source dimensions,
    /// which a bare `gtk::Picture` does not.
    pub fn load_avatar(&self, avatar: &adw::Avatar, api: Arc<ApiClient>, url: Url) {
        let avatar = avatar.clone();
        self.load_with(api, url, move |texture| {
            avatar.set_custom_image(Some(texture));
        });
    }

    /// Loads `url` into a `gtk::Image` (a fixed-`pixel_size` square slot that
    /// scales the picture to fit). Unlike `gtk::Picture`, a `gtk::Image` never
    /// grows to the source's natural size, so it's the right fit for the small
    /// fixed thumbnails in notifications.
    pub fn load_image(&self, image: &gtk::Image, api: Arc<ApiClient>, url: Url) {
        let image = image.clone();
        self.load_with(api, url, move |texture| {
            image.set_paintable(Some(texture));
        });
    }

    /// Shared fetch+decode core: serve from cache or fetch the bytes off-main,
    /// decode on the main thread, cache, and hand the texture to `apply`.
    fn load_with<F>(&self, api: Arc<ApiClient>, url: Url, apply: F)
    where
        F: Fn(&gdk::Texture) + 'static,
    {
        let key = url.as_str().to_string();
        if let Some(texture) = self.cached(&key) {
            apply(&texture);
            return;
        }

        let images = self.clone();
        let (tx, rx) = tokio::sync::oneshot::channel::<Option<Vec<u8>>>();

        relm4::spawn(async move {
            let bytes = api.fetch_bytes(url).await.ok();
            let _ = tx.send(bytes);
        });

        glib::spawn_future_local(async move {
            if let Ok(Some(bytes)) = rx.await
                && let Some(texture) = decode(&bytes)
            {
                images.insert(key, texture.clone());
                apply(&texture);
            }
        });
    }
}

fn decode(bytes: &[u8]) -> Option<gdk::Texture> {
    gdk::Texture::from_bytes(&glib::Bytes::from(bytes)).ok()
}
