use base64::Engine;
use rand::Rng;
use regex::Regex;
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

const X_EPOCH: u64 = 1682924400;
const KEYWORD: &str = "obfiowerehiring";
const TOTAL_ANIM_TIME: f64 = 4096.0;
const BEZIER_TOLERANCE: f64 = 0.00001;
const BEZIER_MAX_ITERS: usize = 100;

#[derive(Debug, Clone)]
pub struct TransactionKeyMaterial {
    pub key_bytes: Vec<u8>,
    pub svg_frames: Vec<Vec<Vec<i32>>>,
    pub row_index: usize,
    pub key_indices: Vec<usize>,
}

pub fn generate_id(material: &TransactionKeyMaterial, method: &str, path: &str) -> Option<String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    let time_now = now.checked_sub(X_EPOCH)? as u32;

    let animation_key = compute_animation_key(material)?;

    let hash_input = format!("{method}!{path}!{time_now}{KEYWORD}{animation_key}");
    let hash = Sha256::digest(hash_input.as_bytes());

    let time_bytes = time_now.to_le_bytes();

    let mut payload = Vec::with_capacity(material.key_bytes.len() + 4 + 16 + 1);
    payload.extend_from_slice(&material.key_bytes);
    payload.extend_from_slice(&time_bytes);
    payload.extend_from_slice(&hash[..16]);
    payload.push(3);

    let random_byte: u8 = rand::rng().random();
    let mut out = Vec::with_capacity(1 + payload.len());
    out.push(random_byte);
    for &b in &payload {
        out.push(b ^ random_byte);
    }

    let encoded = base64::engine::general_purpose::STANDARD.encode(&out);
    Some(encoded.trim_end_matches('=').to_string())
}

fn compute_animation_key(material: &TransactionKeyMaterial) -> Option<String> {
    let kb = &material.key_bytes;
    if kb.len() <= 5 || material.svg_frames.len() < 4 {
        return None;
    }

    let frame_idx = (kb[5] as usize) % 4;
    let frame = &material.svg_frames[frame_idx];
    if frame.is_empty() {
        return None;
    }

    if material.row_index >= kb.len() {
        return None;
    }
    let row_idx = (kb[material.row_index] as usize) % frame.len();
    let row = &frame[row_idx];

    if material.key_indices.is_empty() {
        return None;
    }
    let frame_time: f64 = material
        .key_indices
        .iter()
        .filter_map(|&i| kb.get(i))
        .map(|&b| (b % 16) as f64)
        .product();
    let frame_time = (frame_time / 10.0).round() * 10.0;
    let target_time = (frame_time / TOTAL_ANIM_TIME).clamp(0.0, 1.0);

    Some(animate(row, target_time))
}

fn animate(row: &[i32], target_time: f64) -> String {
    if row.len() < 11 {
        return String::new();
    }

    let from_color = [row[0] as f64, row[1] as f64, row[2] as f64, 1.0];
    let to_color = [row[3] as f64, row[4] as f64, row[5] as f64, 1.0];

    let to_rotation = solve(row[6], 60.0, 360.0, true);

    let x1 = solve(row[7], 0.0, 1.0, false);
    let y1 = solve(row[8], -1.0, 1.0, false);
    let x2 = solve(row[9], 0.0, 1.0, false);
    let y2 = solve(row[10], -1.0, 1.0, false);

    let val = cubic_bezier_value(x1, y1, x2, y2, target_time);

    let color = interpolate(&from_color, &to_color, val);
    let rotation = interpolate(&[0.0], &[to_rotation], val);
    let matrix = rotation_to_matrix(rotation[0]);

    let mut parts = Vec::with_capacity(9);

    for &c in &color[..3] {
        let v = c.round().clamp(0.0, 255.0) as i32;
        parts.push(format!("{v:x}"));
    }

    for &value in &matrix {
        let rounded = (value * 100.0).round() / 100.0;
        let hex = float_to_hex(rounded.abs());
        if hex.starts_with('.') {
            parts.push(format!("0{hex}"));
        } else if hex.is_empty() {
            parts.push("0".to_string());
        } else {
            parts.push(hex);
        }
    }

    parts.push("0".to_string());
    parts.push("0".to_string());

    parts.join("").replace(['.', '-'], "")
}

fn solve(value: i32, min: f64, max: f64, round_down: bool) -> f64 {
    let result = value as f64 * (max - min) / 255.0 + min;
    if round_down {
        result.floor()
    } else {
        (result * 100.0).round() / 100.0
    }
}

fn interpolate(from: &[f64], to: &[f64], t: f64) -> Vec<f64> {
    from.iter()
        .zip(to.iter())
        .map(|(&a, &b)| a + (b - a) * t)
        .collect()
}

fn rotation_to_matrix(degrees: f64) -> [f64; 4] {
    let rad = degrees * std::f64::consts::PI / 180.0;
    let c = rad.cos();
    let s = rad.sin();
    [c, -s, s, c]
}

fn cubic_bezier_value(x1: f64, y1: f64, x2: f64, y2: f64, target_x: f64) -> f64 {
    let bezier = |t: f64, p1: f64, p2: f64| -> f64 {
        3.0 * (1.0 - t).powi(2) * t * p1 + 3.0 * (1.0 - t) * t.powi(2) * p2 + t.powi(3)
    };

    let mut low = 0.0_f64;
    let mut high = 1.0_f64;

    for _ in 0..BEZIER_MAX_ITERS {
        let mid = (low + high) / 2.0;
        let x = bezier(mid, x1, x2);
        if (x - target_x).abs() < BEZIER_TOLERANCE {
            return bezier(mid, y1, y2);
        }
        if x < target_x {
            low = mid;
        } else {
            high = mid;
        }
    }

    bezier((low + high) / 2.0, y1, y2)
}

fn float_to_hex(value: f64) -> String {
    if value == 0.0 {
        return "0".to_string();
    }

    let int_part = value.floor() as u64;
    let frac = value - value.floor();

    let mut result = format!("{int_part:x}");

    if frac > 1e-10 {
        result.push('.');
        let mut f = frac;
        for _ in 0..13 {
            f *= 16.0;
            let digit = f.floor() as u8;
            if let Some(c) = char::from_digit(digit as u32, 16) {
                result.push(c);
            }
            f -= digit as f64;
            if f.abs() < 1e-10 {
                break;
            }
        }
    }

    result
}

pub fn parse_path_data(d: &str) -> Vec<Vec<i32>> {
    if d.len() < 10 {
        return Vec::new();
    }
    let rest = &d[9..];
    rest.split('C')
        .filter(|s| !s.trim().is_empty())
        .map(|segment| {
            let cleaned: String = segment
                .chars()
                .map(|c| {
                    if c.is_ascii_digit() || c == '-' {
                        c
                    } else {
                        ' '
                    }
                })
                .collect();
            cleaned
                .split_whitespace()
                .filter_map(|s| s.parse::<i32>().ok())
                .collect()
        })
        .collect()
}

static VERIFICATION_RE: OnceLock<Regex> = OnceLock::new();
static ONDEMAND_RE: OnceLock<Regex> = OnceLock::new();
static SVG_PATH_RE: OnceLock<Regex> = OnceLock::new();
static JS_INDEX_RE: OnceLock<Regex> = OnceLock::new();

fn verification_re() -> &'static Regex {
    VERIFICATION_RE.get_or_init(|| {
        Regex::new(r#"content="([^"]+)"[^>]*name="twitter-site-verification"|name="twitter-site-verification"[^>]*content="([^"]+)""#)
            .expect("verification regex")
    })
}

fn ondemand_re() -> &'static Regex {
    ONDEMAND_RE.get_or_init(|| {
        Regex::new(r#"['"]ondemand\.s['"]:\s*['"](\w+)['"]"#).expect("ondemand regex")
    })
}

fn svg_path_re() -> &'static Regex {
    SVG_PATH_RE.get_or_init(|| Regex::new(r#"\bd="([^"]+)""#).expect("svg path regex"))
}

fn js_index_re() -> &'static Regex {
    JS_INDEX_RE.get_or_init(|| Regex::new(r"\(\w\[(\d{1,2})\],\s*16\)").expect("js index regex"))
}

pub struct HomepageExtract {
    pub key_bytes: Vec<u8>,
    pub svg_frames: Vec<Vec<Vec<i32>>>,
    pub ondemand_url: String,
}

pub fn extract_from_homepage(html: &str) -> Option<HomepageExtract> {
    let key_bytes = extract_verification_key(html)?;
    let svg_frames = extract_svg_frames(html)?;
    let ondemand_url = extract_ondemand_url(html)?;
    Some(HomepageExtract {
        key_bytes,
        svg_frames,
        ondemand_url,
    })
}

fn extract_verification_key(html: &str) -> Option<Vec<u8>> {
    let cap = verification_re().captures(html)?;
    let b64 = cap.get(1).or_else(|| cap.get(2))?.as_str();
    base64::engine::general_purpose::STANDARD.decode(b64).ok()
}

fn extract_svg_frames(html: &str) -> Option<Vec<Vec<Vec<i32>>>> {
    let mut frames = Vec::with_capacity(4);
    for i in 0..4 {
        let marker = format!("loading-x-anim-{i}");
        let pos = html.find(&marker)?;
        let after = &html[pos..];
        let end = after.find("</svg>")?;
        let block = &after[..end];
        let d_attr = svg_path_re()
            .captures_iter(block)
            .filter_map(|c| c.get(1))
            .map(|m| m.as_str())
            .filter(|d| d.contains('C'))
            .last()?;
        frames.push(parse_path_data(d_attr));
    }
    Some(frames)
}

fn extract_ondemand_url(html: &str) -> Option<String> {
    let cap = ondemand_re().captures(html)?;
    let hash = cap.get(1)?.as_str();
    Some(format!(
        "https://abs.twimg.com/responsive-web/client-web/ondemand.s.{hash}a.js"
    ))
}

pub fn extract_indices_from_js(js: &str) -> Option<(usize, Vec<usize>)> {
    let indices: Vec<usize> = js_index_re()
        .captures_iter(js)
        .filter_map(|c| c.get(1)?.as_str().parse().ok())
        .collect();
    if indices.is_empty() {
        return None;
    }
    Some((indices[0], indices[1..].to_vec()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solve_round_down() {
        assert_eq!(solve(128, 60.0, 360.0, true), 210.0);
        assert_eq!(solve(0, 60.0, 360.0, true), 60.0);
        assert_eq!(solve(255, 60.0, 360.0, true), 360.0);
    }

    #[test]
    fn solve_round_2dp() {
        let v = solve(128, 0.0, 1.0, false);
        assert!((v - 0.50).abs() < 0.01);
    }

    #[test]
    fn interpolate_midpoint() {
        let result = interpolate(&[0.0, 100.0], &[100.0, 200.0], 0.5);
        assert!((result[0] - 50.0).abs() < 0.001);
        assert!((result[1] - 150.0).abs() < 0.001);
    }

    #[test]
    fn rotation_identity_at_zero() {
        let m = rotation_to_matrix(0.0);
        assert!((m[0] - 1.0).abs() < 0.001);
        assert!(m[1].abs() < 0.001);
        assert!(m[2].abs() < 0.001);
        assert!((m[3] - 1.0).abs() < 0.001);
    }

    #[test]
    fn rotation_90_degrees() {
        let m = rotation_to_matrix(90.0);
        assert!(m[0].abs() < 0.001);
        assert!((m[1] + 1.0).abs() < 0.001);
        assert!((m[2] - 1.0).abs() < 0.001);
        assert!(m[3].abs() < 0.001);
    }

    #[test]
    fn cubic_bezier_linear() {
        let v = cubic_bezier_value(0.0, 0.0, 1.0, 1.0, 0.5);
        assert!((v - 0.5).abs() < 0.01);
    }

    #[test]
    fn cubic_bezier_endpoints() {
        let v0 = cubic_bezier_value(0.25, 0.1, 0.25, 1.0, 0.0);
        assert!(v0.abs() < 0.01);

        let v1 = cubic_bezier_value(0.25, 0.1, 0.25, 1.0, 1.0);
        assert!((v1 - 1.0).abs() < 0.01);
    }

    #[test]
    fn float_to_hex_integers() {
        assert_eq!(float_to_hex(0.0), "0");
        assert_eq!(float_to_hex(10.0), "a");
        assert_eq!(float_to_hex(255.0), "ff");
        assert_eq!(float_to_hex(16.0), "10");
    }

    #[test]
    fn float_to_hex_fractions() {
        assert_eq!(float_to_hex(0.5), "0.8");
        assert_eq!(float_to_hex(0.25), "0.4");
    }

    #[test]
    fn parse_path_data_basic() {
        let d = "M 0 0 0 C 10 20 30 40 50 60 C 70 80 90 100 110 120";
        let result = parse_path_data(d);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0], vec![10, 20, 30, 40, 50, 60]);
        assert_eq!(result[1], vec![70, 80, 90, 100, 110, 120]);
    }

    #[test]
    fn parse_path_data_too_short() {
        assert!(parse_path_data("M 0").is_empty());
    }

    #[test]
    fn extract_indices_basic() {
        let js =
            "function(e) { return parseInt(e[2], 16) + parseInt(e[12], 16) + parseInt(e[7], 16) }";
        let result = extract_indices_from_js(js);
        assert!(result.is_some());
        let (row, rest) = result.unwrap();
        assert_eq!(row, 2);
        assert_eq!(rest, vec![12, 7]);
    }

    #[test]
    fn extract_indices_empty() {
        assert!(extract_indices_from_js("no matches here").is_none());
    }

    #[test]
    fn extract_verification_key_name_first() {
        let html = r#"<meta name="twitter-site-verification" content="dGVzdA=="/>"#;
        let key = extract_verification_key(html);
        assert_eq!(key, Some(b"test".to_vec()));
    }

    #[test]
    fn extract_verification_key_content_first() {
        let html = r#"<meta content="dGVzdA==" name="twitter-site-verification"/>"#;
        let key = extract_verification_key(html);
        assert_eq!(key, Some(b"test".to_vec()));
    }

    #[test]
    fn extract_verification_key_missing() {
        assert!(extract_verification_key("<html></html>").is_none());
    }

    #[test]
    fn animate_produces_nonempty_string() {
        let row = vec![127, 58, 0, 200, 100, 50, 180, 64, 128, 192, 32];
        let result = animate(&row, 0.5);
        assert!(!result.is_empty());
        assert!(!result.contains('.'));
        assert!(!result.contains('-'));
    }

    #[test]
    fn animate_short_row_empty() {
        assert!(animate(&[1, 2, 3], 0.5).is_empty());
    }
}
