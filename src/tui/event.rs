use crate::error::Result;
use crossterm::event::{Event as CtEvent, EventStream, KeyEvent};
use futures::StreamExt;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::interval;
use tokio_util::sync::CancellationToken;

const TICK_HZ: f64 = 4.0;
const RENDER_HZ: f64 = 60.0;

#[derive(Debug, Clone)]
pub enum Event {
    Tick,
    Render,
    Key(KeyEvent),
    Resize(u16, u16),
    FocusGained,
    FocusLost,
    Quit,
}

pub struct EventLoop {
    tx: mpsc::UnboundedSender<Event>,
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

    pub fn sender(&self) -> mpsc::UnboundedSender<Event> {
        self.tx.clone()
    }

    pub fn cancel_token(&self) -> CancellationToken {
        self.cancel.clone()
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

async fn pump_events(tx: mpsc::UnboundedSender<Event>, cancel: CancellationToken) {
    let mut tick = interval(Duration::from_secs_f64(1.0 / TICK_HZ));
    let mut render = interval(Duration::from_secs_f64(1.0 / RENDER_HZ));
    let mut stream = EventStream::new();

    loop {
        tokio::select! {
            _ = cancel.cancelled() => break,
            _ = tick.tick() => {
                let _ = tx.send(Event::Tick);
            }
            _ = render.tick() => {
                let _ = tx.send(Event::Render);
            }
            Some(evt) = stream.next() => match evt {
                Ok(CtEvent::Key(k)) => {
                    let _ = tx.send(Event::Key(k));
                }
                Ok(CtEvent::Resize(w, h)) => {
                    let _ = tx.send(Event::Resize(w, h));
                }
                Ok(CtEvent::FocusGained) => {
                    let _ = tx.send(Event::FocusGained);
                }
                Ok(CtEvent::FocusLost) => {
                    let _ = tx.send(Event::FocusLost);
                }
                Ok(_) => {}
                Err(_) => break,
            },
        }
    }
}

pub fn dispatch_result<E: std::fmt::Display>(
    tx: &mpsc::UnboundedSender<Event>,
    result: std::result::Result<Event, E>,
) {
    match result {
        Ok(e) => {
            let _ = tx.send(e);
        }
        Err(e) => {
            tracing::error!("event dispatch error: {e}");
        }
    }
}

pub type EventTx = mpsc::UnboundedSender<Event>;

pub fn send(tx: &EventTx, e: Event) -> Result<()> {
    tx.send(e)
        .map_err(|e| crate::error::Error::Config(format!("event channel closed: {e}")))?;
    Ok(())
}
