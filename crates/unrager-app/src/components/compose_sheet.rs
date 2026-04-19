use crate::api::{ApiError, use_client};
use crate::state::{AppState, ToastKind};
use dioxus::prelude::*;

#[cfg(target_arch = "wasm32")]
const MAX_MEDIA: usize = 4;
const TWEET_MAX_CHARS: usize = 280;
const FILE_INPUT_ID: &str = "unrager-compose-file";

#[derive(Debug, Clone, PartialEq)]
struct Attachment {
    name: String,
    size: u64,
    mime: String,
    preview: Option<String>,
}

#[component]
pub fn ComposeSheet(reply_to: Option<String>) -> Element {
    let client = use_client();
    let mut state = use_context::<Signal<AppState>>();
    let mut text = use_signal(String::new);
    let mut submitting = use_signal(|| false);
    let mut err = use_signal(|| Option::<String>::None);
    let mut done = use_signal(|| false);
    let mut attachments = use_signal(Vec::<Attachment>::new);

    let on_file_change = move |_: Event<FormData>| {
        attachments.set(read_file_list());
    };

    let mut clear_attachments = move || {
        attachments.write().clear();
        clear_file_input();
    };

    let reply_to_for_submit = reply_to.clone();
    let on_submit = move |_| {
        let client = client.clone();
        let reply_to = reply_to_for_submit.clone();
        let t = text();
        let has_media = !attachments.read().is_empty();
        if t.trim().is_empty() && !has_media {
            err.set(Some("tweet text or media required".into()));
            return;
        }
        submitting.set(true);
        err.set(None);
        done.set(false);
        spawn(async move {
            let path = match reply_to.as_deref() {
                Some(id) => format!("/api/reply/{id}"),
                None => "/api/compose".into(),
            };
            let result = compose_multipart(&client, &path, &t).await;
            submitting.set(false);
            match result {
                Ok(_) => {
                    text.set(String::new());
                    clear_attachments();
                    done.set(true);
                    state.write().show_toast("posted", ToastKind::Success);
                }
                Err(e) => {
                    let msg = e.to_string();
                    err.set(Some(msg.clone()));
                    state.write().show_toast(msg, ToastKind::Error);
                }
            }
        });
    };

    let clear_cb = move |_| clear_attachments();

    let char_count = text().chars().count();
    let over = char_count > TWEET_MAX_CHARS;

    rsx! {
        div { class: "compose",
            textarea {
                placeholder: if reply_to.is_some() { "reply..." } else { "what's on your mind?" },
                value: "{text}",
                oninput: move |e| text.set(e.value()),
                rows: "5",
            }

            div { class: "compose-row",
                label { class: "file-btn", r#for: FILE_INPUT_ID, "attach media" }
                input {
                    id: FILE_INPUT_ID,
                    class: "hidden-file",
                    r#type: "file",
                    accept: "image/*,video/*",
                    multiple: true,
                    onchange: on_file_change,
                }
                span { class: if over { "char-count over" } else { "char-count" },
                    "{char_count} / {TWEET_MAX_CHARS}"
                }
            }

            if !attachments.read().is_empty() {
                div { class: "media-preview",
                    for (i, a) in attachments.read().iter().enumerate() {
                        div { key: "{i}", class: "media-preview-item",
                            if let Some(url) = a.preview.as_ref() {
                                img { src: "{url}", alt: "{a.name}" }
                            } else {
                                div { class: "media-preview-fallback",
                                    span { class: "media-preview-kind", "{a.mime}" }
                                    span { class: "media-preview-name", "{a.name}" }
                                }
                            }
                            div { class: "media-preview-size", {human_size(a.size)} }
                        }
                    }
                    button { class: "media-clear", onclick: clear_cb, "clear" }
                }
            }

            if let Some(e) = err() {
                div { class: "error-banner",
                    span { class: "error-message", "{e}" }
                }
            }
            if done() {
                div { class: "banner", style: "color: var(--success)", "posted" }
            }
            div { class: "compose-submit",
                button {
                    class: "primary",
                    disabled: submitting() || (text().trim().is_empty() && attachments.read().is_empty()) || over,
                    onclick: on_submit,
                    if submitting() { "posting..." } else { "post" }
                }
            }
        }
    }
}

fn human_size(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    if bytes < KB {
        format!("{bytes} B")
    } else if bytes < MB {
        format!("{:.0} KB", bytes as f64 / KB as f64)
    } else {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    }
}

#[cfg(target_arch = "wasm32")]
fn read_file_list() -> Vec<Attachment> {
    use wasm_bindgen::JsCast;
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return Vec::new();
    };
    let Some(el) = doc.get_element_by_id(FILE_INPUT_ID) else {
        return Vec::new();
    };
    let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() else {
        return Vec::new();
    };
    let Some(fl) = input.files() else {
        return Vec::new();
    };
    let len = fl.length().min(MAX_MEDIA as u32);
    let mut out = Vec::with_capacity(len as usize);
    for i in 0..len {
        if let Some(file) = fl.item(i) {
            let preview = if file.type_().starts_with("image/") {
                web_sys::Url::create_object_url_with_blob(&file).ok()
            } else {
                None
            };
            out.push(Attachment {
                name: file.name(),
                size: file.size() as u64,
                mime: file.type_(),
                preview,
            });
        }
    }
    out
}

#[cfg(not(target_arch = "wasm32"))]
fn read_file_list() -> Vec<Attachment> {
    Vec::new()
}

#[cfg(target_arch = "wasm32")]
fn clear_file_input() {
    use wasm_bindgen::JsCast;
    if let Some(el) = web_sys::window()
        .and_then(|w| w.document())
        .and_then(|d| d.get_element_by_id(FILE_INPUT_ID))
        && let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>()
    {
        input.set_value("");
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn clear_file_input() {}

#[cfg(target_arch = "wasm32")]
async fn compose_multipart(
    client: &crate::api::Client,
    path: &str,
    text: &str,
) -> std::result::Result<unrager_model::ComposeResult, ApiError> {
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return Err(ApiError("no document".into()));
    };
    let files_opt = doc
        .get_element_by_id(FILE_INPUT_ID)
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        .and_then(|input| input.files());

    let form = web_sys::FormData::new().map_err(|e| ApiError(format!("FormData: {e:?}")))?;
    form.append_with_str("text", text)
        .map_err(|e| ApiError(format!("form text: {e:?}")))?;
    if let Some(fl) = files_opt {
        let len = fl.length().min(MAX_MEDIA as u32);
        for i in 0..len {
            if let Some(file) = fl.item(i) {
                form.append_with_blob_and_filename("media[]", &file, &file.name())
                    .map_err(|e| ApiError(format!("form media: {e:?}")))?;
            }
        }
    }

    let url = client.url(path);
    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_body(&form);
    let request = web_sys::Request::new_with_str_and_init(&url, &opts)
        .map_err(|e| ApiError(format!("Request: {e:?}")))?;
    let window = web_sys::window().ok_or_else(|| ApiError("no window".into()))?;
    let resp_val = JsFuture::from(window.fetch_with_request(&request))
        .await
        .map_err(|e| ApiError(format!("fetch: {e:?}")))?;
    let response: web_sys::Response = resp_val
        .dyn_into()
        .map_err(|_| ApiError("response cast".into()))?;
    if !response.ok() {
        return Err(ApiError(format!("HTTP {}", response.status())));
    }
    let text_promise = response
        .text()
        .map_err(|e| ApiError(format!("text: {e:?}")))?;
    let text_val = JsFuture::from(text_promise)
        .await
        .map_err(|e| ApiError(format!("text await: {e:?}")))?;
    let body = text_val.as_string().unwrap_or_default();
    serde_json::from_str(&body).map_err(|e| ApiError(format!("decode: {e}")))
}

#[cfg(not(target_arch = "wasm32"))]
async fn compose_multipart(
    _client: &crate::api::Client,
    _path: &str,
    _text: &str,
) -> std::result::Result<unrager_model::ComposeResult, ApiError> {
    Err(ApiError("native compose not implemented".into()))
}
