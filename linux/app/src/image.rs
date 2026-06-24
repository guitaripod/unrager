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
        let key = url.as_str().to_string();
        if let Some(texture) = self.cached(&key) {
            picture.set_paintable(Some(&texture));
            return;
        }

        let picture = picture.clone();
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
                picture.set_paintable(Some(&texture));
            }
        });
    }
}

fn decode(bytes: &[u8]) -> Option<gdk::Texture> {
    gdk::Texture::from_bytes(&glib::Bytes::from(bytes)).ok()
}
