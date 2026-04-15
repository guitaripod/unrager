use crate::error::Result;
use crate::parse::notification::RawNotification;
use crate::parse::timeline::TimelinePage;
use crate::tui::source::SourceKind;
use crossterm::event::{Event as CtEvent, EventStream, KeyEvent};
use futures::StreamExt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::interval;
use tokio_util::sync::CancellationToken;

const TICK_HZ: f64 = 4.0;
const RENDER_HZ: f64 = 30.0;

pub type RequestId = u64;

static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

pub fn next_request_id() -> RequestId {
    NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed)
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum Event {
    Tick,
    Render,
    Key(KeyEvent),
    Resize(u16, u16),
    FocusGained,
    FocusLost,
    Quit,
    TimelineLoaded {
        kind: SourceKind,
        result: Result<TimelinePage>,
        append: bool,
        silent: bool,
    },
    ThreadLoaded {
        request_id: RequestId,
        focal_id: String,
        result: Result<TimelinePage>,
    },
    InlineThreadLoaded {
        focal_id: String,
        result: Result<TimelinePage>,
    },
    MediaLoadedKitty {
        url: String,
        id: u32,
        w: u32,
        h: u32,
    },
    MediaLoadedPixels {
        url: String,
        pixels: std::sync::Arc<Vec<u8>>,
        w: u32,
        h: u32,
    },
    MediaFailed {
        url: String,
        err: String,
    },
    TweetClassified {
        rest_id: String,
        verdict: crate::tui::filter::FilterDecision,
    },
    TweetTranslated {
        rest_id: String,
        translated: String,
    },
    OpenTweetResolved {
        request_id: RequestId,
        result: Result<crate::model::Tweet>,
    },
    SelfHandleResolved {
        handle: String,
    },
    SelfHandleBackgroundResolved {
        handle: String,
    },
    UserTimelineLoaded {
        result: Result<crate::parse::timeline::TimelinePage>,
    },
    LikersPageLoaded {
        tweet_id: String,
        result: Result<crate::tui::focus::LikersPage>,
        append: bool,
    },
    NotificationPageLoaded {
        result: Result<crate::parse::notification::NotificationPage>,
        append: bool,
        silent: bool,
    },
    WhisperPollTick,
    NotificationsLoaded {
        notifications: Vec<RawNotification>,
        top_cursor: Option<String>,
    },
    NotificationsFailed {
        err: String,
    },
    WhisperTextReady {
        text: String,
    },
    WhisperSurgeReady {
        summary: String,
        sentiment: crate::tui::whisper::Sentiment,
    },
    AskToken {
        tweet_id: String,
        token: String,
    },
    AskStreamFinished {
        tweet_id: String,
        error: Option<String>,
    },
    AskRepliesLoaded {
        tweet_id: String,
        replies: Vec<crate::model::Tweet>,
    },
}

pub type EventTx = mpsc::UnboundedSender<Event>;

pub struct EventLoop {
    tx: EventTx,
    rx: mpsc::UnboundedReceiver<Event>,
    cancel: CancellationToken,
}

impl Default for EventLoop {
    fn default() -> Self {
        Self::new()
    }
}

impl EventLoop {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        Self {
            tx,
            rx,
            cancel: CancellationToken::new(),
        }
    }

    pub fn sender(&self) -> EventTx {
        self.tx.clone()
    }

    pub fn start(&self) {
        let tx = self.tx.clone();
        let cancel = self.cancel.clone();
        tokio::spawn(async move { pump_events(tx, cancel).await });
    }

    pub async fn next(&mut self) -> Option<Event> {
        self.rx.recv().await
    }
}

async fn pump_events(tx: EventTx, cancel: CancellationToken) {
    let mut tick = interval(Duration::from_secs_f64(1.0 / TICK_HZ));
    let mut render = interval(Duration::from_secs_f64(1.0 / RENDER_HZ));
    let mut stream = EventStream::new();

    loop {
        tokio::select! {
            _ = cancel.cancelled() => break,
            _ = tick.tick() => { let _ = tx.send(Event::Tick); }
            _ = render.tick() => { let _ = tx.send(Event::Render); }
            Some(evt) = stream.next() => match evt {
                Ok(CtEvent::Key(k)) => { let _ = tx.send(Event::Key(k)); }
                Ok(CtEvent::Resize(w, h)) => { let _ = tx.send(Event::Resize(w, h)); }
                Ok(CtEvent::FocusGained) => { let _ = tx.send(Event::FocusGained); }
                Ok(CtEvent::FocusLost) => { let _ = tx.send(Event::FocusLost); }
                Ok(_) => {}
                Err(_) => break,
            },
        }
    }
}
