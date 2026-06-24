//! Multipart form construction for compose/reply, mirroring the boundary layout
//! of `UnragerKit`'s `APIClient.multipart`.

use crate::models::ComposeMedia;
use reqwest::multipart::{Form, Part};

/// Builds a `multipart/form-data` body: a `text` part (only when non-empty),
/// then one `media` part per attachment.
pub(crate) fn build_form(text: &str, media: &[ComposeMedia]) -> reqwest::Result<Form> {
    let mut form = Form::new();
    if !text.is_empty() {
        form = form.text("text", text.to_string());
    }
    for item in media {
        let part = Part::bytes(item.bytes.clone())
            .file_name(item.filename.clone())
            .mime_str(&item.mime)?;
        form = form.part("media", part);
    }
    Ok(form)
}
