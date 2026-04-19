use crate::api::ApiError;
use futures::Stream;
use serde::de::DeserializeOwned;

#[derive(Debug, Clone)]
pub struct StreamEvent {
    /// SSE event name (`message` by default). Exposed for multi-event
    /// streams; current consumers only inspect `data`.
    #[allow(dead_code)]
    pub event: String,
    pub data: String,
}

impl StreamEvent {
    /// Parse the event payload as JSON. Reserved for callers that want the
    /// error path; current call sites match on `data` directly.
    #[allow(dead_code)]
    pub fn parse<T: DeserializeOwned>(&self) -> Result<T, ApiError> {
        serde_json::from_str(&self.data).map_err(|e| ApiError(e.to_string()))
    }
}

#[cfg(target_arch = "wasm32")]
pub fn stream_sse(url: &str) -> impl Stream<Item = Result<StreamEvent, ApiError>> {
    use futures::StreamExt;
    use gloo_net::eventsource::futures::EventSource;
    async_stream::stream! {
        let mut es = match EventSource::new(url) {
            Ok(es) => es,
            Err(e) => {
                yield Err(ApiError(e.to_string()));
                return;
            }
        };
        let stream = es.subscribe("message").unwrap();
        let mut s = stream;
        while let Some(item) = s.next().await {
            match item {
                Ok((event_type, msg)) => {
                    let data = msg.data().as_string().unwrap_or_default();
                    yield Ok(StreamEvent { event: event_type, data });
                }
                Err(e) => {
                    yield Err(ApiError(format!("sse: {e:?}")));
                    break;
                }
            }
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub fn stream_sse(url: &str) -> impl Stream<Item = Result<StreamEvent, ApiError>> {
    use eventsource_stream::Eventsource;
    use futures::StreamExt;
    let url = url.to_string();
    async_stream::stream! {
        let resp = match reqwest::get(&url).await {
            Ok(r) => r,
            Err(e) => {
                yield Err(ApiError(e.to_string()));
                return;
            }
        };
        if !resp.status().is_success() {
            yield Err(ApiError(format!("HTTP {}", resp.status())));
            return;
        }
        let mut stream = resp.bytes_stream().eventsource();
        while let Some(event) = stream.next().await {
            match event {
                Ok(ev) => {
                    let event_name = if ev.event.is_empty() { "message".into() } else { ev.event };
                    yield Ok(StreamEvent { event: event_name, data: ev.data });
                }
                Err(e) => {
                    yield Err(ApiError(e.to_string()));
                    break;
                }
            }
        }
    }
}
