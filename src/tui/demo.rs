//! Bundled tweets for `unrager demo` — a self-contained offline feed designed
//! to exercise the rage filter visibly.
//!
//! The set is hand-tuned so that a default-rubric Ollama classifier drops
//! roughly half as rage-bait (politics / war / culture war) and keeps the
//! other half (technical, scientific, wholesome). That way `−N` in the status
//! bar has an honest number to display, and the filter's effect is legible
//! without needing a live X session.

use crate::model::{Tweet, User};
use crate::parse::timeline::TimelinePage;
use chrono::{DateTime, Duration, Utc};

pub fn is_demo_mode() -> bool {
    std::env::var_os("UNRAGER_DEMO").is_some()
}

pub const DEMO_HANDLE: &str = "demouser";

fn user(handle: &str, name: &str, verified: bool, followers: u64) -> User {
    User {
        rest_id: format!("u_{handle}"),
        handle: handle.into(),
        name: name.into(),
        verified,
        followers,
        following: followers / 20,
    }
}

fn tweet(
    id: u64,
    minutes_ago: i64,
    author: User,
    text: &str,
    likes: u64,
    replies: u64,
    retweets: u64,
) -> Tweet {
    let created_at: DateTime<Utc> = Utc::now() - Duration::minutes(minutes_ago);
    Tweet {
        rest_id: format!("demo_{id}"),
        author: author.clone(),
        created_at,
        text: text.into(),
        reply_count: replies,
        retweet_count: retweets,
        like_count: likes,
        quote_count: 0,
        view_count: Some(likes * 40 + replies * 60),
        favorited: false,
        retweeted: false,
        bookmarked: false,
        lang: Some("en".into()),
        in_reply_to_tweet_id: None,
        quoted_tweet: None,
        media: Vec::new(),
        url: format!("https://x.com/{}/status/demo_{id}", author.handle),
    }
}

pub fn page() -> TimelinePage {
    let alex = user("alex_codes", "Alex · Rust", true, 18_400);
    let mira = user("miradata", "Mira H.", false, 4_200);
    let jin = user("jinml", "Jin · ML", true, 62_000);
    let pol = user("beltwayfire", "Beltway Fire", false, 3_100);
    let war = user("frontline_daily", "Frontline Daily", false, 15_900);
    let cult = user("culturewarden", "Culture Warden", false, 7_700);
    let sci = user("cell_biolog", "Rina K.", true, 11_200);
    let art = user("studio_koi", "Koi Studio", false, 5_400);
    let pres = user("pundit_night", "Pundit Night", false, 9_800);
    let game = user("terminalgopher", "gopher", false, 1_200);
    let mus = user("labelb_side", "B-side Notes", false, 2_900);
    let sport = user("rinkreport", "Rink Report", false, 6_400);

    let tweets = vec![
        tweet(
            1,
            2,
            alex.clone(),
            "shipped a little rust crate today that memoizes expensive async fns across tokio tasks — surprisingly nice to use. gist in replies.",
            420,
            18,
            42,
        ),
        tweet(
            2,
            5,
            pol.clone(),
            "the senate floor tonight was a circus — both parties more interested in owning each other than passing anything. the country deserves better than this partisan theater.",
            2_100,
            340,
            180,
        ),
        tweet(
            3,
            8,
            jin.clone(),
            "new paper: small MoE at 2B active params matching 7B dense on MMLU. routing stability was the unlock. code + weights up today.",
            3_800,
            90,
            620,
        ),
        tweet(
            4,
            12,
            war.clone(),
            "heavy artillery exchange overnight in the eastern sector. civilian casualty figures from the regional hospital are climbing. footage coming.",
            1_400,
            220,
            310,
        ),
        tweet(
            5,
            15,
            sci.clone(),
            "the thing nobody tells you about cryo-EM: 80% of a good structure is sample prep, 15% is microscope time, 5% is the software everyone argues about.",
            900,
            44,
            130,
        ),
        tweet(
            6,
            19,
            cult.clone(),
            "if men won't do X, women will do X and then complain about it. this is why modern dating is broken. reply guys don't @ me.",
            5_400,
            1_200,
            410,
        ),
        tweet(
            7,
            23,
            art.clone(),
            "three weeks on a single watercolor. i think i finally understand why my teacher kept saying 'paint the air between things, not the things themselves'.",
            2_200,
            60,
            280,
        ),
        tweet(
            8,
            28,
            pres.clone(),
            "the president's speech tonight was a disaster. congress needs to act NOW. anyone who thinks this is normal is part of the problem.",
            8_900,
            2_400,
            1_100,
        ),
        tweet(
            9,
            33,
            game.clone(),
            "reminder that you can use `git worktree` to have two branches checked out simultaneously without re-cloning. saved me today while debugging a flaky CI.",
            640,
            22,
            180,
        ),
        tweet(
            10,
            38,
            mus.clone(),
            "spent the afternoon in my friend's home studio — ribbon mic into a 1960s tube pre, no post-EQ. the midrange is unreal. analog chain still matters.",
            310,
            14,
            36,
        ),
        tweet(
            11,
            44,
            war.clone(),
            "battlefield footage from the front shows what happens when drones with thermite payloads meet a dug-in armor column. brutal.",
            980,
            160,
            240,
        ),
        tweet(
            12,
            50,
            sport.clone(),
            "overtime game 6, two teams that actually respect each other, refs letting them play, and the crowd on its feet the whole third. this is why we watch.",
            1_700,
            80,
            210,
        ),
        tweet(
            13,
            58,
            sci.clone(),
            "weekly reminder: the replication crisis hasn't gone away, it has just gotten quieter. if your result only works on one lab's machine, it isn't a result yet.",
            1_500,
            55,
            420,
        ),
        tweet(
            14,
            67,
            alex.clone(),
            "favorite cargo feature nobody uses: `[profile.dev.package.'*'] opt-level = 1`. keeps your own crate debuggable while making third-party deps run fast. night-and-day for async work.",
            1_100,
            40,
            240,
        ),
        tweet(
            15,
            78,
            mira.clone(),
            "migrated a small read-heavy app from postgres to sqlite on a tailscale-only box. 50x latency drop on the p99. sometimes the right db is the one on the same machine as the code.",
            820,
            65,
            190,
        ),
    ];

    TimelinePage {
        tweets,
        next_cursor: None,
        top_cursor: None,
    }
}
