"""The made-up world the stats-on-your-posts pictures are shot in.

Nothing here is a real person, account or post. The signed-in account is
the app demo's Nora Lind (`demos/app/demo_world.py`); the people who like,
repost and quote her posts are that demo's cast plus the names below, with
the abstract avatars `make_assets.py` draws (and hue-turned copies of them).
Every count, analytics figure and hour of impressions is invented, and
`BASELINE` is the earlier look the "+N since you last looked" marks count
from.
"""

from __future__ import annotations

import math
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app"))
import demo_world  # noqa: E402

NOW = datetime.now(timezone.utc).replace(microsecond=0)
TWITTER_EPOCH_MS = 1_288_834_974_657
ME = "noralind"
ME_NAME = "Nora Lind"
ME_BIO = "Designer. Small details, long walks, slow mornings."
ME_LOCATION = "Helsinki"
ME_FOLLOWERS = 4_812
ME_FOLLOWING = 312
ME_POSTS = 2_418
AVATAR_BASE = "https://pbs.twimg.com/profile_images/demo"


def avatar_url(name: str) -> str:
    return f"{AVATAR_BASE}/{name}_400x400.jpg"


EXTRA = [
    ("oskarbuilds", "Oskar Lindqvist", False, 2_310),
    ("ainov", "Aino Virtanen", False, 860),
    ("priyamakes", "Priya Nair", True, 14_200),
    ("leomoreau_", "Léo Moreau", False, 1_190),
    ("hanasketch", "Hana Sato", False, 5_430),
    ("elifdesigns", "Elif Kaya", True, 22_800),
    ("noahbecker", "Noah Becker", False, 412),
    ("zoeadler", "Zoe Adler", False, 3_020),
    ("mateoruiz", "Mateo Ruiz", False, 760),
    ("freyaholm", "Freya Holm", True, 9_870),
    ("yusufdemir", "Yusuf Demir", False, 1_480),
    ("claraweiss", "Clara Weiss", False, 2_640),
    ("theogrant", "Theo Grant", False, 318),
    ("ivychenux", "Ivy Chen", True, 41_300),
    ("svenaalto", "Sven Aalto", False, 1_020),
    ("mayatorres", "Maya Torres", False, 6_710),
    ("rubendiaz_", "Rubén Díaz", False, 540),
    ("lottaniemi", "Lotta Niemi", False, 2_180),
    ("jonashart", "Jonas Hart", False, 970),
    ("adaquinn", "Ada Quinn", True, 18_400),
    ("felixbrandt", "Felix Brandt", False, 1_760),
    ("ninarossi", "Nina Rossi", False, 3_390),
    ("omarhaddad", "Omar Haddad", False, 2_050),
    ("sofialund", "Sofia Lund", False, 1_310),
    ("kaimercer", "Kai Mercer", False, 7_820),
    ("evaharju", "Eva Harju", False, 650),
    ("dankoval", "Dan Koval", False, 1_140),
    ("mirjamtalvi", "Mirjam Talvi", True, 11_900),
]

FOLLOWS_ME = set(demo_world.FOLLOWS_ME) | {
    "oskarbuilds", "ainov", "hanasketch", "noahbecker", "freyaholm", "claraweiss",
    "svenaalto", "lottaniemi", "adaquinn", "sofialund", "evaharju", "mirjamtalvi",
}
I_FOLLOW = set(demo_world.ME_FOLLOWS) | {
    "priyamakes", "elifdesigns", "freyaholm", "ivychenux", "adaquinn", "kaimercer", "mirjamtalvi",
}


def _people() -> dict[str, dict]:
    people = {}
    for index, (handle, name, verified, followers, *_rest) in enumerate(demo_world.CAST):
        if handle in (ME, "outragedaily", "hottakeshourly"):
            continue
        people[handle] = {
            "handle": handle,
            "name": name,
            "verified": verified,
            "followers": followers,
            "avatar": demo_world.CAST[index][5],
        }
    for index, (handle, name, verified, followers) in enumerate(EXTRA):
        people[handle] = {
            "handle": handle,
            "name": name,
            "verified": verified,
            "followers": followers,
            "avatar": f"h{index % 16 + 1:02d}",
        }
    for rank, person in enumerate(people.values()):
        person["rest_id"] = str(3_000_000_000 + rank * 7_919)
        person["follows_me"] = person["handle"] in FOLLOWS_ME
        person["followed_by_me"] = person["handle"] in I_FOLLOW
    return people


PEOPLE = _people()


def user(handle: str) -> dict:
    p = PEOPLE[handle]
    return {
        "rest_id": p["rest_id"],
        "handle": p["handle"],
        "name": p["name"],
        "verified": p["verified"],
        "followers": p["followers"],
        "following": 300,
        "avatar_url": avatar_url(p["avatar"]),
        "follows_me": p["follows_me"],
        "followed_by_me": p["followed_by_me"],
    }


def snowflake(when: datetime, seq: int) -> str:
    ms = int(when.timestamp() * 1000) - TWITTER_EPOCH_MS
    return str((ms << 22) | (seq & 0x3FFFFF))


def curve(hours: int, total: int, peak_at: float, spread: float, tail: float, seed: int) -> list[int]:
    """Impressions per hour that rise to a peak and settle into a long tail,
    with a little hour-to-hour wobble, adding up to `total`."""
    raw = []
    for h in range(hours):
        rise = 1 - math.exp(-(h + 0.6) / max(peak_at, 0.3))
        fall = math.exp(-max(0.0, h - peak_at) / spread)
        wobble = 1 + 0.18 * math.sin(h * 1.7 + seed) + 0.08 * math.cos(h * 3.1 + seed * 2)
        raw.append(max(0.02, rise * fall + tail) * wobble)
    if hours:
        raw[-1] *= 0.45
    scale = total / sum(raw)
    out = [max(1, round(v * scale)) for v in raw]
    out[out.index(max(out))] += total - sum(out)
    return out


POSTS = [
    {
        "key": "link",
        "age": timedelta(hours=6, minutes=40),
        "text": "Wrote up how I design loading states that don't flash, with the timings I actually use.",
        "card": {
            "title": "Loading states that don't flash",
            "description": "Skeletons, delays and the 250 ms rule: notes from five years of waiting screens.",
            "domain": "noralind.example",
            "url": "https://noralind.example/loading-states",
            "image": "card_01",
        },
        "counts": {"replies": 7, "reposts": 18, "likes": 96, "quotes": 2, "bookmarks": 41, "views": 4_126},
        "analytics": {"engagements": 702, "detail_expands": 148, "profile_visits": 31, "link_clicks": 214, "follows": 3},
        "shape": (0.6, 1.3, 0.04),
        "likers": 96,
        "reposters": 18,
        "front": (["priyamakes", "oskarbuilds", "anyavoss"], ["freyaholm", "mirakoski"]),
        "quotes": ["q_link"],
    },
    {
        "key": "hero",
        "age": timedelta(hours=26, minutes=40),
        "text": "Hot take: a good skeleton screen is the shape of the thing, not a spinner pretending to be busy.",
        "counts": {"replies": 14, "reposts": 27, "likes": 388, "quotes": 6, "bookmarks": 52, "views": 11_842},
        "analytics": {"engagements": 862, "detail_expands": 214, "profile_visits": 73, "link_clicks": 0, "follows": 9},
        "shape": (1.4, 3.2, 0.035),
        "likers": 388,
        "reposters": 27,
        "front": (["mirakoski", "hanasketch", "ivychenux"], ["fieldnotes", "lenapark"]),
        "quotes": ["q1", "q2", "q3"],
    },
    {
        "key": "photo",
        "age": timedelta(hours=30, minutes=5),
        "text": "Tried the new tab bar minimize on a real device and it's lovely. The small details really are the whole thing.",
        "photo": ("land_06", 1600, 1067),
        "counts": {"replies": 4, "reposts": 2, "likes": 61, "quotes": 1, "bookmarks": 9, "views": 1_873},
        "analytics": {"engagements": 190, "detail_expands": 64, "profile_visits": 12, "link_clicks": 0, "follows": 1},
        "shape": (0.9, 2.5, 0.05),
        "likers": 61,
        "reposters": 2,
        "front": (["kitwren", "junocooks", "svenaalto"], ["tomasbuilds"]),
        "quotes": [],
    },
    {
        "key": "quiet",
        "age": timedelta(days=2, hours=1),
        "text": "Spent the morning on a loading state that doesn't flash. The trick is mostly not showing it at all.",
        "counts": {"replies": 9, "reposts": 7, "likes": 212, "quotes": 2, "bookmarks": 31, "views": 6_400},
        "analytics": {"engagements": 604, "detail_expands": 251, "profile_visits": 40, "link_clicks": 0, "follows": 4},
        "shape": (1.0, 2.8, 0.04),
        "likers": 212,
        "reposters": 7,
        "front": (["anyavoss", "elifdesigns", "claraweiss"], ["mirakoski"]),
        "quotes": [],
    },
    {
        "key": "grid",
        "age": timedelta(days=4, hours=3),
        "text": "Tried justified rows for a photo grid. Nothing cropped, nothing wasted, and it looks calm.",
        "photo": ("land_02", 1600, 1067),
        "counts": {"replies": 5, "reposts": 4, "likes": 143, "quotes": 1, "bookmarks": 18, "views": 3_200},
        "analytics": {"engagements": 377, "detail_expands": 122, "profile_visits": 22, "link_clicks": 0, "follows": 2},
        "shape": (1.2, 2.2, 0.04),
        "likers": 143,
        "reposters": 4,
        "front": (["freyaholm", "mayatorres", "noahbecker"], ["ivychenux"]),
        "quotes": [],
    },
]

QUOTES = {
    "q1": ("mirakoski", timedelta(hours=24), "This. A skeleton is a promise about the layout, not a loading animation.", (3, 2, 41, 820)),
    "q2": ("tomasbuilds", timedelta(hours=22), "Counterpoint: sometimes a spinner is the honest answer. But yes, shape beats spin.", (6, 0, 17, 610)),
    "q3": ("lenapark", timedelta(hours=19), "Saving this for the next design review.", (0, 0, 9, 240)),
    "q_link": ("priyamakes", timedelta(hours=2), "The 250 ms rule in here is the one I keep coming back to.", (1, 1, 12, 330)),
}

BASELINE_AGE = timedelta(hours=3)
BASELINE = {
    "link": ({"replies": 5, "reposts": 17, "likes": 80, "bookmarks": 33, "views": 2_980},
             {"impressions": 2_980, "engagements": 540, "detail_expands": 112, "profile_visits": 24, "link_clicks": 160, "follows": 2}),
    "hero": ({"replies": 12, "reposts": 31, "likes": 371, "bookmarks": 49, "views": 10_900},
             {"impressions": 10_900, "engagements": 790, "detail_expands": 196, "profile_visits": 69, "link_clicks": 0, "follows": 8}),
    "photo": ({"replies": 4, "reposts": 2, "likes": 58, "bookmarks": 9, "views": 1_850},
              {"impressions": 1_850, "engagements": 186, "detail_expands": 63, "profile_visits": 12, "link_clicks": 0, "follows": 1}),
}


class World:
    """Nora's posts with their ids and times, and what the server says
    about each: analytics, the people on its lists, the posts quoting it."""

    def __init__(self) -> None:
        self.posts = []
        handles = list(PEOPLE)
        for seq, post in enumerate(POSTS):
            created = NOW - post["age"]
            p = dict(post, created=created, id=snowflake(created, seq + 1))
            hours = min(48, max(1, math.ceil(post["age"].total_seconds() / 3600)))
            p["hourly"] = curve(hours, post["counts"]["views"], *post["shape"], seed=seq)
            likers_front, reposters_front = post["front"]
            p["liker_handles"] = self._ordered(handles, likers_front, post["likers"], seq)
            p["reposter_handles"] = self._ordered(handles, reposters_front, post["reposters"], seq + 7)
            self.posts.append(p)
        self.by_id = {p["id"]: p for p in self.posts}
        self.by_key = {p["key"]: p for p in self.posts}

    @staticmethod
    def _ordered(handles: list[str], front: list[str], count: int, seed: int) -> list[str]:
        """Who liked or reposted a post, newest first: `front`, then a stable
        order of everyone else that differs from post to post."""
        def mix(h: str) -> int:
            return (sum(ord(c) * (i + 1) for i, c in enumerate(h)) * (seed * 31 + 7)) % 1009
        rest = sorted((h for h in handles if h not in front), key=mix)
        order = list(front) + rest
        return order[: min(count, len(order))]

    def analytics(self, post: dict) -> dict:
        return {
            "impressions": post["counts"]["views"],
            **post["analytics"],
            "hourly_impressions": post["hourly"],
        }

    def page(self, handles: list[str], cursor: str | None, size: int) -> dict:
        start = int(cursor or 0)
        chunk = handles[start: start + size]
        nxt = start + size
        return {"users": [user(h) for h in chunk], "cursor": str(nxt) if nxt < len(handles) else None}

    def quote_tweets(self, post: dict) -> list[dict]:
        out = []
        for seq, key in enumerate(post["quotes"]):
            handle, age, text, (replies, reposts, likes, views) = QUOTES[key]
            created = NOW - age
            out.append({
                "rest_id": snowflake(created, 900 + seq),
                "author": user(handle),
                "created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "text": text,
                "reply_count": replies,
                "retweet_count": reposts,
                "like_count": likes,
                "quote_count": 0,
                "view_count": views,
                "url": f"https://x.com/{handle}/status/{snowflake(created, 900 + seq)}",
                "media": [],
            })
        return out

    def seen(self) -> dict:
        """The earlier look the rises count from, as the extension stores it."""
        at = int((NOW - BASELINE_AGE).timestamp() * 1000)
        return {
            self.by_key[key]["id"]: {"t": at, "c": counts, "a": analytics}
            for key, (counts, analytics) in BASELINE.items()
        }
