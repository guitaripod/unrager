use crate::routes::Route;
use dioxus::prelude::*;

#[component]
pub fn Home() -> Element {
    let nav = use_navigator();
    use_effect(move || {
        nav.push(Route::SourceHome {});
    });
    rsx! { div { class: "loading", "loading..." } }
}
