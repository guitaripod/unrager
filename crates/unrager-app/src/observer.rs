//! Intersection observer helpers for infinite scroll and seen tracking.

#[cfg(target_arch = "wasm32")]
pub use web::*;

#[cfg(not(target_arch = "wasm32"))]
pub use native::*;

#[cfg(target_arch = "wasm32")]
mod web {
    use std::cell::RefCell;
    use std::rc::Rc;
    use wasm_bindgen::JsCast;
    use wasm_bindgen::prelude::*;

    pub type VisibleIdsCb = Rc<RefCell<dyn FnMut(Vec<String>)>>;

    pub struct ObserverGuard {
        pub observer: web_sys::IntersectionObserver,
        _closure: Closure<dyn FnMut(js_sys::Array, web_sys::IntersectionObserver)>,
    }

    pub fn observe_visibility(attr: &'static str, cb: VisibleIdsCb) -> Option<ObserverGuard> {
        let attr_owned = attr.to_string();
        let closure = Closure::wrap(Box::new(
            move |entries: js_sys::Array, _obs: web_sys::IntersectionObserver| {
                let mut ids: Vec<String> = Vec::new();
                for i in 0..entries.length() {
                    let entry = entries
                        .get(i)
                        .dyn_into::<web_sys::IntersectionObserverEntry>()
                        .ok();
                    if let Some(e) = entry
                        && e.is_intersecting()
                    {
                        let target = e.target();
                        if let Some(id) = target.get_attribute(&attr_owned) {
                            ids.push(id);
                        }
                    }
                }
                if !ids.is_empty() {
                    (cb.borrow_mut())(ids);
                }
            },
        )
            as Box<dyn FnMut(js_sys::Array, web_sys::IntersectionObserver)>);

        let init = web_sys::IntersectionObserverInit::new();
        init.set_root_margin("0px");
        init.set_threshold(&JsValue::from_f64(0.5));
        let observer = web_sys::IntersectionObserver::new_with_options(
            closure.as_ref().unchecked_ref(),
            &init,
        )
        .ok()?;
        Some(ObserverGuard {
            observer,
            _closure: closure,
        })
    }

    pub fn observe_element_by_id(observer: &web_sys::IntersectionObserver, id: &str) {
        if let Some(doc) = web_sys::window().and_then(|w| w.document())
            && let Some(el) = doc.get_element_by_id(id)
        {
            observer.observe(&el);
        }
    }

    pub fn observe_all_by_attr(observer: &web_sys::IntersectionObserver, attr: &str) {
        if let Some(doc) = web_sys::window().and_then(|w| w.document())
            && let Ok(nodes) = doc.query_selector_all(&format!("[{attr}]"))
        {
            for i in 0..nodes.length() {
                if let Some(node) = nodes.item(i)
                    && let Ok(el) = node.dyn_into::<web_sys::Element>()
                {
                    observer.observe(&el);
                }
            }
        }
    }

    impl Drop for ObserverGuard {
        fn drop(&mut self) {
            self.observer.disconnect();
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
mod native {
    use std::cell::RefCell;
    use std::rc::Rc;

    pub type VisibleIdsCb = Rc<RefCell<dyn FnMut(Vec<String>)>>;

    pub struct ObserverGuard;

    pub fn observe_visibility(_attr: &'static str, _cb: VisibleIdsCb) -> Option<ObserverGuard> {
        None
    }
}
