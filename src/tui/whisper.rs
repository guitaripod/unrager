use crate::error::Result;
use crate::gql::GqlClient;
use crate::parse::notification;
use crate::tui::event::{Event, EventTx};
use crate::tui::filter::OllamaConfig;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use std::collections::HashMap;
use std::time::{Duration, Instant};
use tracing::{debug, warn};

const MILESTONES: &[u64] = &[
    3, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000,
];
const MILESTONE_MAX_AGE: Duration = Duration::from_secs(48 * 3600);

const QUIET_INTERVAL: Duration = Duration::from_secs(120);
const ACTIVE_INTERVAL: Duration = Duration::from_secs(60);
const SURGE_INTERVAL: Duration = Duration::from_secs(30);
const COOLING_INTERVAL: Duration = Duration::from_secs(60);

const ROTATION_PERIOD: Duration = Duration::from_secs(20);
const ENTRY_TTL: Duration = Duration::from_secs(300);
const COOLING_TTL: Duration = Duration::from_secs(600);

const SURGE_THRESHOLD: usize = 16;
const ACTIVE_THRESHOLD: usize = 3;

const INITIAL_DELAY: Duration = Duration::from_secs(5);
const HEARTBEAT: Duration = Duration::from_secs(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WhisperPhase {
    Quiet,
    Active,
    Surge,
    Cooling,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sentiment {
    Positive,
    Mixed,
    Negative,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotifKind {
    Reply,
    Quote,
    Mention,
    Like,
    Retweet,
    Follow,
    Other,
}

impl NotifKind {
    pub fn from_api(s: &str) -> Self {
        match s {
            "Reply" => Self::Reply,
            "Quote" | "QuoteTweet" => Self::Quote,
            "Mention" => Self::Mention,
            "Like" | "Liked" => Self::Like,
            "Retweet" | "Retweeted" => Self::Retweet,
            "Follow" | "Followed" => Self::Follow,
            _ => Self::Other,
        }
    }

    fn priority(self, is_mutual: bool) -> u8 {
        match self {
            Self::Reply if is_mutual => 0,
            Self::Quote => 1,
            Self::Reply => 2,
            Self::Mention => 4,
            _ => 5,
        }
    }
}

#[derive(Debug, Clone)]
pub struct NotifEntry {
    pub kind: NotifKind,
    pub actor_handle: String,
    pub target_tweet_id: Option<String>,
    pub target_tweet_snippet: Option<String>,
    pub target_tweet_like_count: Option<u64>,
    pub priority: u8,
}

const AMBIENT_LIKE_THRESHOLD: u64 = 10;

impl NotifEntry {
    pub fn from_raw(raw: &notification::RawNotification) -> Self {
        let kind = NotifKind::from_api(&raw.notification_type);
        let actor_handle = raw
            .actors
            .first()
            .map(|u| u.handle.clone())
            .unwrap_or_default();
        let priority = kind.priority(false);
        Self {
            kind,
            actor_handle,
            target_tweet_id: raw.target_tweet_id.clone(),
            target_tweet_snippet: raw.target_tweet_snippet.clone(),
            target_tweet_like_count: raw.target_tweet_like_count,
            priority,
        }
    }
}

#[derive(Debug, Clone)]
pub struct WhisperEntry {
    pub text: String,
    pub created: Instant,
    pub priority: u8,
}

pub struct MilestoneTracker {
    tracked: HashMap<String, (u64, u64, DateTime<Utc>)>,
}

impl MilestoneTracker {
    fn new() -> Self {
        Self {
            tracked: HashMap::new(),
        }
    }

    pub fn update(
        &mut self,
        tweet_id: &str,
        like_count: u64,
        created_at: DateTime<Utc>,
    ) -> Option<u64> {
        let age = Utc::now().signed_duration_since(created_at);
        if age > chrono::Duration::from_std(MILESTONE_MAX_AGE).ok()? {
            self.tracked.remove(tweet_id);
            return None;
        }
        let highest = MILESTONES
            .iter()
            .rev()
            .find(|&&m| like_count >= m)
            .copied()
            .unwrap_or(0);
        let entry = self
            .tracked
            .entry(tweet_id.to_string())
            .or_insert((0, highest, created_at));
        entry.0 = like_count;
        if highest > entry.1 {
            entry.1 = highest;
            Some(highest)
        } else {
            None
        }
    }

    pub fn gc(&mut self) {
        let Some(cutoff_duration) = chrono::Duration::from_std(MILESTONE_MAX_AGE).ok() else {
            return;
        };
        let cutoff = Utc::now() - cutoff_duration;
        self.tracked.retain(|_, (_, _, created)| *created > cutoff);
    }
}

pub enum LlmRequest {
    None,
    SingleWhisper(NotifEntry),
    SurgeSummary(Vec<NotifEntry>),
}

pub struct WhisperState {
    pub phase: WhisperPhase,
    pub text: String,
    pub entries: Vec<WhisperEntry>,
    pub rotation_index: usize,
    pub last_rotation: Instant,
    pub last_poll: Option<Instant>,
    pub poll_interval: Duration,
    pub watermark_ts: i64,
    pub milestones: MilestoneTracker,
    pub poll_inflight: bool,
    pub llm_inflight: bool,
    pub surge_tweet_id: Option<String>,
    pub surge_sentiment: Option<Sentiment>,
    pub cooling_start: Option<Instant>,
}

impl Default for WhisperState {
    fn default() -> Self {
        Self::new()
    }
}

impl WhisperState {
    pub fn new() -> Self {
        Self {
            phase: WhisperPhase::Quiet,
            text: String::new(),
            entries: Vec::new(),
            rotation_index: 0,
            last_rotation: Instant::now(),
            last_poll: None,
            poll_interval: QUIET_INTERVAL,
            watermark_ts: 0,
            milestones: MilestoneTracker::new(),
            poll_inflight: false,
            llm_inflight: false,
            surge_tweet_id: None,
            surge_sentiment: None,
            cooling_start: None,
        }
    }

    pub fn should_poll(&self) -> bool {
        if self.poll_inflight {
            return false;
        }
        match self.last_poll {
            None => true,
            Some(last) => last.elapsed() >= self.poll_interval,
        }
    }

    pub fn ingest(
        &mut self,
        entries: &[NotifEntry],
        milestones: &[(String, u64, Option<String>)],
    ) -> LlmRequest {
        let count = entries.len();
        self.poll_inflight = false;

        self.entries.retain(|e| e.created.elapsed() < ENTRY_TTL);

        let surge_candidate = detect_surge(entries);
        let prev_phase = self.phase;

        if count >= SURGE_THRESHOLD || (surge_candidate.is_some() && count >= SURGE_THRESHOLD / 2) {
            self.phase = WhisperPhase::Surge;
            self.poll_interval = SURGE_INTERVAL;
            self.surge_tweet_id = surge_candidate;
            self.cooling_start = None;
            return LlmRequest::SurgeSummary(entries.to_vec());
        }

        if prev_phase == WhisperPhase::Surge && count < SURGE_THRESHOLD {
            self.phase = WhisperPhase::Cooling;
            self.poll_interval = COOLING_INTERVAL;
            self.cooling_start = Some(Instant::now());
        }

        if self.phase == WhisperPhase::Cooling {
            if let Some(start) = self.cooling_start {
                if start.elapsed() > COOLING_TTL {
                    self.phase = WhisperPhase::Quiet;
                    self.poll_interval = QUIET_INTERVAL;
                    self.text.clear();
                    self.entries.clear();
                }
            }
        }

        if self.phase != WhisperPhase::Surge && self.phase != WhisperPhase::Cooling {
            if count >= ACTIVE_THRESHOLD {
                self.phase = WhisperPhase::Active;
                self.poll_interval = ACTIVE_INTERVAL;
            } else {
                self.phase = WhisperPhase::Quiet;
                self.poll_interval = QUIET_INTERVAL;
            }
        }

        for (tweet_id, milestone, snippet) in milestones {
            if self.phase != WhisperPhase::Surge {
                let text = match snippet {
                    Some(s) => {
                        let short: String = s.chars().take(40).collect();
                        format!("{} likes — {}", format_milestone(*milestone), short)
                    }
                    None => format!(
                        "your tweet just passed {} likes",
                        format_milestone(*milestone)
                    ),
                };
                self.push_entry(WhisperEntry {
                    text,
                    created: Instant::now(),
                    priority: 3,
                });
            }
            debug!(tweet_id, milestone, "like milestone crossed");
        }

        let important: Vec<&NotifEntry> = entries.iter().filter(|e| e.priority <= 3).collect();

        if let Some(top) = important.first() {
            return LlmRequest::SingleWhisper((*top).clone());
        }

        if !entries.is_empty() {
            let has_follows = entries.iter().any(|e| e.kind == NotifKind::Follow);
            let quiet_likes: Vec<&NotifEntry> = entries
                .iter()
                .filter(|e| {
                    (e.kind == NotifKind::Like || e.kind == NotifKind::Retweet)
                        && e.target_tweet_like_count.unwrap_or(0) < AMBIENT_LIKE_THRESHOLD
                })
                .collect();

            let best = quiet_likes.first().copied();

            let text = if let Some(entry) = best {
                let snippet = entry.target_tweet_snippet.as_deref().unwrap_or("");
                let short: String = snippet.chars().take(40).collect();
                let actor = entry.actor_handle.as_str();
                if actor.is_empty() {
                    format!("\u{2661} {short}")
                } else {
                    format!("\u{2661} {actor} \u{2014} {short}")
                }
            } else if has_follows {
                "\u{2192} new followers".to_string()
            } else {
                return LlmRequest::None;
            };
            self.push_entry(WhisperEntry {
                text,
                created: Instant::now(),
                priority: 6,
            });
        }

        LlmRequest::None
    }

    pub fn tick(&mut self) {
        if self.entries.len() <= 1 {
            return;
        }
        if self.last_rotation.elapsed() >= ROTATION_PERIOD {
            self.rotation_index = (self.rotation_index + 1) % self.entries.len();
            self.last_rotation = Instant::now();
            self.text = self.entries[self.rotation_index].text.clone();
        }
    }

    pub fn clear(&mut self) {
        self.text.clear();
        self.entries.clear();
        self.phase = WhisperPhase::Quiet;
        self.poll_interval = QUIET_INTERVAL;
        self.surge_tweet_id = None;
        self.surge_sentiment = None;
        self.cooling_start = None;
        self.rotation_index = 0;
    }

    pub fn push_entry(&mut self, entry: WhisperEntry) {
        self.entries.push(entry);
        self.entries.sort_by_key(|e| e.priority);
        if self.entries.len() > 10 {
            self.entries.truncate(10);
        }
        if let Some(top) = self.entries.first() {
            self.text = top.text.clone();
        }
    }
}

fn detect_surge(entries: &[NotifEntry]) -> Option<String> {
    if entries.is_empty() {
        return None;
    }
    let mut tweet_counts: HashMap<&str, usize> = HashMap::new();
    for e in entries {
        if let Some(ref id) = e.target_tweet_id {
            *tweet_counts.entry(id.as_str()).or_default() += 1;
        }
    }
    let threshold = (entries.len() * 6) / 10;
    tweet_counts
        .into_iter()
        .find(|(_, count)| *count > threshold)
        .map(|(id, _)| id.to_string())
}

fn format_milestone(n: u64) -> String {
    if n >= 1_000 {
        let k = n / 1_000;
        let remainder = (n % 1_000) / 100;
        if remainder > 0 {
            format!("{k}.{remainder}k")
        } else {
            format!("{k}k")
        }
    } else {
        n.to_string()
    }
}

pub fn build_heuristic_whisper(entry: &NotifEntry) -> String {
    let verb = match entry.kind {
        NotifKind::Reply => "replied to your thread",
        NotifKind::Quote => "quoted your tweet",
        NotifKind::Mention => "mentioned you",
        NotifKind::Like => "liked your tweet",
        NotifKind::Retweet => "retweeted you",
        NotifKind::Follow => "followed you",
        NotifKind::Other => "interacted",
    };
    format!("{} {}", entry.actor_handle, verb)
}

fn build_heuristic_surge(entries: &[NotifEntry]) -> String {
    let mut replies = 0usize;
    let mut quotes = 0usize;
    let mut likes = 0usize;
    let mut other = 0usize;
    for e in entries {
        match e.kind {
            NotifKind::Reply => replies += 1,
            NotifKind::Quote => quotes += 1,
            NotifKind::Like => likes += 1,
            _ => other += 1,
        }
    }
    let mut parts = Vec::new();
    if replies > 0 {
        parts.push(format!("{replies} replies"));
    }
    if quotes > 0 {
        parts.push(format!("{quotes} quotes"));
    }
    if likes > 0 {
        parts.push(format!("{likes} likes"));
    }
    if other > 0 {
        parts.push(format!("{other} other"));
    }
    format!("surge: {}", parts.join(", "))
}

const NOTIFICATIONS_URL: &str = "https://x.com/i/api/2/notifications/all.json";
const MENTIONS_URL: &str = "https://x.com/i/api/2/notifications/mentions.json";

fn notification_params(cursor: Option<&str>) -> (Vec<(&str, &str)>, Option<String>) {
    let params: Vec<(&str, &str)> = vec![
        ("include_profile_interstitial_type", "1"),
        ("include_blocking", "1"),
        ("include_blocked_by", "1"),
        ("include_followed_by", "1"),
        ("include_want_retweets", "1"),
        ("include_mute_edge", "1"),
        ("include_can_dm", "1"),
        ("include_can_media_tag", "1"),
        ("include_ext_is_blue_verified", "1"),
        ("include_ext_verified_type", "1"),
        ("include_ext_profile_image_shape", "1"),
        ("skip_status", "1"),
        ("cards_platform", "Web-12"),
        ("include_cards", "1"),
        ("include_ext_alt_text", "true"),
        ("include_ext_limited_action_results", "true"),
        ("include_quote_count", "true"),
        ("include_reply_count", "1"),
        ("tweet_mode", "extended"),
        ("include_ext_views", "true"),
        ("include_entities", "true"),
        ("include_user_entities", "true"),
        ("include_ext_media_color", "true"),
        ("include_ext_media_availability", "true"),
        ("include_ext_sensitive_media_warning", "true"),
        ("include_ext_trusted_friends_metadata", "true"),
        ("send_error_codes", "true"),
        ("simple_quoted_tweet", "true"),
        ("count", "40"),
        ("requestContext", "launch"),
        (
            "ext",
            "mediaStats,highlightedLabel,hasNftAvatar,voiceInfo,birdwatchPivot,superFollowMetadata,unmentionInfo,editControl",
        ),
    ];
    (params, cursor.map(str::to_string))
}

pub async fn fetch_notifications(
    client: &GqlClient,
    cursor: Option<&str>,
) -> Result<notification::NotificationPage> {
    let response = fetch_notifications_raw(client, cursor).await?;
    notification::parse_response(&response)
}

pub async fn fetch_notifications_raw(
    client: &GqlClient,
    cursor: Option<&str>,
) -> Result<serde_json::Value> {
    let (mut params, cursor_owned) = notification_params(cursor);
    if let Some(ref c) = cursor_owned {
        params.push(("cursor", c));
    }
    client.raw_get(NOTIFICATIONS_URL, &params).await
}

pub async fn fetch_mentions(
    client: &GqlClient,
    cursor: Option<&str>,
) -> Result<notification::NotificationPage> {
    let response = fetch_mentions_raw(client, cursor).await?;
    notification::parse_mentions_response(&response)
}

pub async fn fetch_mentions_raw(
    client: &GqlClient,
    cursor: Option<&str>,
) -> Result<serde_json::Value> {
    let (mut params, cursor_owned) = notification_params(cursor);
    if let Some(ref c) = cursor_owned {
        params.push(("cursor", c));
    }
    client.raw_get(MENTIONS_URL, &params).await
}

pub fn start_poll_loop(tx: EventTx) {
    tokio::spawn(async move {
        tokio::time::sleep(INITIAL_DELAY).await;
        loop {
            let _ = tx.send(Event::WhisperPollTick);
            tokio::time::sleep(HEARTBEAT).await;
        }
    });
}

const WHISPER_SYSTEM_PROMPT: &str = "\
You produce short, lowercase, casual notifications for a terminal app. \
No emojis. No punctuation at the end. Max 50 characters. \
Output ONLY the notification text, nothing else. \
Examples: alice replied to your thread, bob quoted your take on async, carol mentioned you";

const SURGE_SYSTEM_PROMPT: &str = "\
Classify the overall sentiment of these reactions as POSITIVE, MIXED, or NEGATIVE. \
Then produce a short summary (max 60 chars, lowercase, no emojis). \
Format your response exactly as: SENTIMENT|summary text here\n\
Examples:\n\
POSITIVE|your async tweet is spreading -- mostly positive\n\
MIXED|your take is getting debated -- split reactions\n\
NEGATIVE|you're getting ratio'd -- mostly hostile quotes";

#[derive(Debug, Deserialize)]
struct OllamaChatResponse {
    message: OllamaChatMessage,
}

#[derive(Debug, Deserialize)]
struct OllamaChatMessage {
    content: String,
}

pub fn whisper_llm_async(entry: NotifEntry, ollama: OllamaConfig, tx: EventTx) {
    tokio::spawn(async move {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(ollama.timeout_seconds))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        let url = format!("{}/api/chat", ollama.host.trim_end_matches('/'));

        let verb = match entry.kind {
            NotifKind::Reply => "replied to",
            NotifKind::Quote => "quoted",
            NotifKind::Mention => "mentioned you in",
            NotifKind::Like => "liked",
            NotifKind::Retweet => "retweeted",
            NotifKind::Follow => "followed you (no tweet)",
            NotifKind::Other => "interacted with",
        };
        let snippet = entry.target_tweet_snippet.as_deref().unwrap_or("a tweet");
        let prompt = format!(
            "@{} {} your tweet: \"{}\"",
            entry.actor_handle, verb, snippet
        );

        let body = serde_json::json!({
            "model": ollama.model,
            "messages": [
                { "role": "system", "content": WHISPER_SYSTEM_PROMPT },
                { "role": "user", "content": prompt },
            ],
            "stream": false,
            "think": false,
            "options": { "temperature": 0.3, "num_predict": 60 },
        });

        let text = match http.post(&url).json(&body).send().await {
            Ok(resp) if resp.status().is_success() => {
                match resp.json::<OllamaChatResponse>().await {
                    Ok(r) => r.message.content.trim().to_lowercase(),
                    Err(e) => {
                        warn!("whisper llm parse failed: {e}");
                        build_heuristic_whisper(&entry)
                    }
                }
            }
            Ok(resp) => {
                warn!("whisper llm http status {}", resp.status());
                build_heuristic_whisper(&entry)
            }
            Err(e) => {
                warn!("whisper llm http error: {e}");
                build_heuristic_whisper(&entry)
            }
        };

        let _ = tx.send(Event::WhisperTextReady { text });
    });
}

pub fn surge_llm_async(entries: Vec<NotifEntry>, ollama: OllamaConfig, tx: EventTx) {
    tokio::spawn(async move {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(ollama.timeout_seconds))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        let url = format!("{}/api/chat", ollama.host.trim_end_matches('/'));

        let mut prompt = String::from("Recent reactions to the user's tweet:\n");
        for e in &entries {
            let kind_str = match e.kind {
                NotifKind::Reply => "replied",
                NotifKind::Quote => "quoted",
                NotifKind::Mention => "mentioned",
                NotifKind::Like => "liked",
                NotifKind::Retweet => "retweeted",
                NotifKind::Follow => "followed",
                NotifKind::Other => "interacted",
            };
            prompt.push_str(&format!("- @{} {}\n", e.actor_handle, kind_str));
        }

        let body = serde_json::json!({
            "model": ollama.model,
            "messages": [
                { "role": "system", "content": SURGE_SYSTEM_PROMPT },
                { "role": "user", "content": prompt },
            ],
            "stream": false,
            "think": false,
            "options": { "temperature": 0, "num_predict": 80 },
        });

        let (summary, sentiment) = match http.post(&url).json(&body).send().await {
            Ok(resp) if resp.status().is_success() => {
                match resp.json::<OllamaChatResponse>().await {
                    Ok(r) => parse_surge_response(&r.message.content),
                    Err(e) => {
                        warn!("surge llm parse failed: {e}");
                        (build_heuristic_surge(&entries), Sentiment::Mixed)
                    }
                }
            }
            _ => (build_heuristic_surge(&entries), Sentiment::Mixed),
        };

        let _ = tx.send(Event::WhisperSurgeReady { summary, sentiment });
    });
}

fn parse_surge_response(raw: &str) -> (String, Sentiment) {
    let trimmed = raw.trim();
    if let Some((sentiment_str, summary)) = trimmed.split_once('|') {
        let sentiment = match sentiment_str.trim().to_uppercase().as_str() {
            "POSITIVE" => Sentiment::Positive,
            "NEGATIVE" => Sentiment::Negative,
            _ => Sentiment::Mixed,
        };
        (summary.trim().to_lowercase(), sentiment)
    } else {
        (trimmed.to_lowercase(), Sentiment::Mixed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn milestone_sequence() {
        let mut tracker = MilestoneTracker::new();
        let now = Utc::now();
        assert_eq!(tracker.update("t1", 2, now), None);
        assert_eq!(tracker.update("t1", 3, now), Some(3));
        assert_eq!(tracker.update("t1", 4, now), None);
        assert_eq!(tracker.update("t1", 5, now), Some(5));
        assert_eq!(tracker.update("t1", 9, now), None);
        assert_eq!(tracker.update("t1", 10, now), Some(10));
        assert_eq!(tracker.update("t1", 24, now), None);
        assert_eq!(tracker.update("t1", 25, now), Some(25));
        assert_eq!(tracker.update("t1", 100, now), Some(100));
    }

    #[test]
    fn milestone_old_tweet_ignored() {
        let mut tracker = MilestoneTracker::new();
        let old = Utc::now() - chrono::Duration::hours(72);
        assert_eq!(tracker.update("t1", 100, old), None);
    }

    #[test]
    fn milestone_format() {
        assert_eq!(format_milestone(3), "3");
        assert_eq!(format_milestone(100), "100");
        assert_eq!(format_milestone(1_000), "1k");
        assert_eq!(format_milestone(2_500), "2.5k");
        assert_eq!(format_milestone(10_000), "10k");
        assert_eq!(format_milestone(100_000), "100k");
    }

    #[test]
    fn surge_detection() {
        let entries: Vec<NotifEntry> = (0..20)
            .map(|i| NotifEntry {
                kind: NotifKind::Like,
                actor_handle: format!("user{i}"),
                target_tweet_id: Some("tweet1".into()),
                target_tweet_snippet: None,
                target_tweet_like_count: None,
                priority: 5,
            })
            .collect();
        assert_eq!(detect_surge(&entries), Some("tweet1".into()));
    }

    #[test]
    fn no_surge_when_spread() {
        let entries: Vec<NotifEntry> = (0..10)
            .map(|i| NotifEntry {
                kind: NotifKind::Like,
                actor_handle: format!("user{i}"),
                target_tweet_id: Some(format!("tweet{i}")),
                target_tweet_snippet: None,
                target_tweet_like_count: None,
                priority: 5,
            })
            .collect();
        assert_eq!(detect_surge(&entries), None);
    }

    #[test]
    fn heuristic_whisper_text() {
        let entry = NotifEntry {
            kind: NotifKind::Reply,
            actor_handle: "alice".into(),
            target_tweet_id: None,
            target_tweet_snippet: None,
            target_tweet_like_count: None,
            priority: 2,
        };
        assert_eq!(
            build_heuristic_whisper(&entry),
            "alice replied to your thread"
        );
    }

    #[test]
    fn surge_response_parsing() {
        let (summary, sentiment) =
            parse_surge_response("POSITIVE|your async tweet is spreading -- mostly positive");
        assert_eq!(sentiment, Sentiment::Positive);
        assert!(summary.contains("spreading"));

        let (summary, sentiment) = parse_surge_response("NEGATIVE|you're getting ratio'd");
        assert_eq!(sentiment, Sentiment::Negative);
        assert!(summary.contains("ratio"));
    }

    #[test]
    fn whisper_state_transitions() {
        let mut state = WhisperState::new();
        assert_eq!(state.phase, WhisperPhase::Quiet);

        let entries: Vec<NotifEntry> = (0..5)
            .map(|i| NotifEntry {
                kind: NotifKind::Reply,
                actor_handle: format!("user{i}"),
                target_tweet_id: Some("t1".into()),
                target_tweet_snippet: Some("hello".into()),
                target_tweet_like_count: None,
                priority: 2,
            })
            .collect();
        let _ = state.ingest(&entries, &[]);
        assert_eq!(state.phase, WhisperPhase::Active);
        assert_eq!(state.poll_interval, ACTIVE_INTERVAL);

        let surge_entries: Vec<NotifEntry> = (0..20)
            .map(|i| NotifEntry {
                kind: NotifKind::Like,
                actor_handle: format!("user{i}"),
                target_tweet_id: Some("t1".into()),
                target_tweet_snippet: None,
                target_tweet_like_count: None,
                priority: 5,
            })
            .collect();
        let _ = state.ingest(&surge_entries, &[]);
        assert_eq!(state.phase, WhisperPhase::Surge);
        assert_eq!(state.poll_interval, SURGE_INTERVAL);

        let few: Vec<NotifEntry> = (0..2)
            .map(|i| NotifEntry {
                kind: NotifKind::Like,
                actor_handle: format!("user{i}"),
                target_tweet_id: Some("t1".into()),
                target_tweet_snippet: None,
                target_tweet_like_count: None,
                priority: 5,
            })
            .collect();
        let _ = state.ingest(&few, &[]);
        assert_eq!(state.phase, WhisperPhase::Cooling);
    }

    #[test]
    fn clear_resets_everything() {
        let mut state = WhisperState::new();
        state.phase = WhisperPhase::Surge;
        state.text = "something".into();
        state.surge_tweet_id = Some("t1".into());
        state.surge_sentiment = Some(Sentiment::Positive);
        state.push_entry(WhisperEntry {
            text: "test".into(),
            created: Instant::now(),
            priority: 1,
        });

        state.clear();
        assert_eq!(state.phase, WhisperPhase::Quiet);
        assert!(state.text.is_empty());
        assert!(state.entries.is_empty());
        assert!(state.surge_tweet_id.is_none());
        assert!(state.surge_sentiment.is_none());
    }
}
