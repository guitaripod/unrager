use dioxus::prelude::*;

#[component]
pub fn Avatar(name: String, handle: String, #[props(default = 44)] size: u32) -> Element {
    let initial = first_letter(&name, &handle);
    let bg = hashed_color(&handle);
    let fg = "#0e0e10";
    let style = format!("width: {size}px; height: {size}px; background: {bg}; color: {fg};");

    rsx! {
        div { class: "avatar", style: "{style}",
            span { class: "avatar-initial", "{initial}" }
        }
    }
}

fn first_letter(name: &str, handle: &str) -> String {
    let source = if name.trim().is_empty() { handle } else { name };
    source
        .chars()
        .find(|c| !c.is_whitespace())
        .map(|c| c.to_uppercase().to_string())
        .unwrap_or_else(|| "?".to_string())
}

fn hashed_color(s: &str) -> String {
    let mut hash: u32 = 2166136261;
    for b in s.bytes() {
        hash ^= u32::from(b);
        hash = hash.wrapping_mul(16777619);
    }
    let hue = hash % 360;
    format!("hsl({hue}, 55%, 68%)")
}
