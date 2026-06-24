//! Server-Sent Events parsing core, mirroring `UnragerKit`'s `sseStream`.
//!
//! Lenient by design: only `data:` lines are considered, the `[DONE]` sentinel
//! ends the stream, blank/comment/keep-alive lines are skipped, and a payload
//! that fails to decode as `T` is dropped silently (matching the Swift `try?`).

use crate::ApiError;
use crate::models::ServerError;
use futures::{Stream, StreamExt};
use reqwest::Client;
use serde::de::DeserializeOwned;
use url::Url;

pub(crate) fn sse_stream<T>(client: Client, url: Url) -> impl Stream<Item = Result<T, ApiError>>
where
    T: DeserializeOwned + 'static,
{
    async_stream::stream! {
        let resp = match client
            .get(url)
            .header(reqwest::header::ACCEPT, "text/event-stream")
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                yield Err(ApiError::from_reqwest(&e));
                return;
            }
        };

        let status = resp.status();
        if !status.is_success() {
            let body = resp.bytes().await.ok();
            let server_err = body
                .as_deref()
                .and_then(|b| serde_json::from_slice::<ServerError>(b).ok());
            yield Err(ApiError::from_status(status.as_u16(), server_err));
            return;
        }

        let mut bytes = resp.bytes_stream();
        let mut buf: Vec<u8> = Vec::new();
        while let Some(chunk) = bytes.next().await {
            let chunk = match chunk {
                Ok(c) => c,
                Err(e) => {
                    yield Err(ApiError::from_reqwest(&e));
                    return;
                }
            };
            buf.extend_from_slice(&chunk);

            while let Some(newline) = buf.iter().position(|&b| b == b'\n') {
                let mut line: Vec<u8> = buf.drain(..=newline).collect();
                line.pop();
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                let line = String::from_utf8_lossy(&line);
                let Some(rest) = line.strip_prefix("data:") else {
                    continue;
                };
                let value = rest.strip_prefix(' ').unwrap_or(rest);
                if value == "[DONE]" {
                    return;
                }
                if value.is_empty() {
                    continue;
                }
                if let Ok(event) = serde_json::from_str::<T>(value) {
                    yield Ok(event);
                }
            }
        }
    }
}
