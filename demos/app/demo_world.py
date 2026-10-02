"""The made-up world the app demo runs on: a cast, their posts and threads.

Nothing here is a real person, account or post. Counts, times and text are
invented; the pictures come from `make_assets.py`. `World(base)` turns it all
into the JSON the unrager server would send, with media URLs under `base`.

`CAST` rows are (handle, name, verified, followers, following, avatar, banner,
country as (name, alpha2, flag)); `PROFILES` adds the bio, location, website
and join date a profile page shows, `PROTECTED` and `SUSPENDED` the accounts
whose posts are hidden or that are gone. `POSTS` rows are (key, author, minutes ago,
text, media, counts, options): media is `("photos", [names])`, `("video", name)`,
`("card", {...})` or `None`, counts are (replies, reposts, likes, quotes, views,
bookmarks), and options such as `reply_to` and `hidden_from_feed` shape the
threads, the quoted post and the signed-in account's own posts. `REPOSTS` maps
the Home posts that arrive as someone's repost to the reposter's handle, and
`quotes_of` lists the posts quoting a post.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

NOW = datetime.now(timezone.utc)


def ago(**delta) -> str:
    return (NOW - timedelta(**delta)).strftime("%Y-%m-%dT%H:%M:%SZ")


def snowflake(index: int) -> str:
    return str(2110000000000000000 + index * 4096)


CAST = [
    ("noralind", "Nora Lind", False, 1842, 312, "a01", "b01", ("Finland", "FI", "🇫🇮")),
    ("mirakoski", "Mira Koski", True, 48210, 611, "a02", "b02", ("Finland", "FI", "🇫🇮")),
    ("tomasbuilds", "Tomás Bellamy", False, 9340, 402, "a03", "b03", ("Portugal", "PT", "🇵🇹")),
    ("orbitaldaily", "Orbital Daily", True, 612400, 85, "a04", "b04", ("United States", "US", "🇺🇸")),
    ("fieldnotes", "Field Notes", True, 129800, 240, "a05", "b05", ("Norway", "NO", "🇳🇴")),
    ("junocooks", "Juno Cook", False, 22900, 518, "a06", "b06", ("Japan", "JP", "🇯🇵")),
    ("kitwren", "Kit Wren", False, 15600, 903, "a07", "b01", ("United Kingdom", "GB", "🇬🇧")),
    ("thelongwalk", "The Long Walk", False, 31200, 77, "a08", "b05", ("Canada", "CA", "🇨🇦")),
    ("anyavoss", "Dr. Anya Voss", True, 204500, 312, "a09", "b04", ("Germany", "DE", "🇩🇪")),
    ("maxplays", "Max Okafor", False, 7400, 280, "a10", "b03", ("Nigeria", "NG", "🇳🇬")),
    ("hottakeshourly", "Hot Takes Hourly", False, 88300, 12, "a11", "b06", ("United States", "US", "🇺🇸")),
    ("outragedaily", "OUTRAGE DAILY", False, 55100, 9, "a12", "b06", ("United States", "US", "🇺🇸")),
    ("samreyes_", "Sam Reyes", False, 3100, 450, "a13", "b02", ("Mexico", "MX", "🇲🇽")),
    ("lenapark", "Lena Park", True, 18700, 733, "a14", "b02", ("South Korea", "KR", "🇰🇷")),
    ("ravimenon", "Ravi Menon", False, 5200, 390, "a15", "b03", ("India", "IN", "🇮🇳")),
    ("inesduarte", "Inês Duarte", False, 4100, 620, "a16", "b05", ("Brazil", "BR", "🇧🇷")),
    ("quietfern", "Fern Halloway", False, 412, 198, "a13", "b05", ("Ireland", "IE", "🇮🇪")),
]
HANDLES = {c[0]: i + 1 for i, c in enumerate(CAST)}
ME = "noralind"

PROFILES = {
    "noralind": ("Designer. Small details, long walks, slow mornings.", "Helsinki", None, "2015-03-12T09:00:00Z"),
    "mirakoski": ("Illustrator and product designer. Drawing the diagrams for @anyavoss's book.\nPortfolio: https://mirakoski.example/work",
                  "Turku, Finland", "https://www.mirakoski.example/work/", "2011-09-03T12:00:00Z"),
    "anyavoss": ("Physicist. Everyday puzzles explained in short threads: light, sound, resonance. "
                 "Writing a book with @mirakoski. Notes and diagrams at https://anyavoss.example/notes #physics",
                 "Berlin", "https://anyavoss.example/notes", "2009-06-21T08:30:00Z"),
    "fieldnotes": ("Photographs from the trail, one ridge at a time.", "Somewhere above the tree line",
                   "https://fieldnotes.example", "2013-02-14T07:00:00Z"),
    "quietfern": ("Notes for friends. Garden, books, the odd sourdough.", "Galway", None, "2020-04-02T10:00:00Z"),
}
PROTECTED = {"quietfern"}
PINNED = {"mirakoski": "f18"}
SUSPENDED = {"spamking"}

MEDIA_DIMS = {
    "land": (1600, 1067), "port": (1200, 1600), "sq": (1080, 1080),
    "shot": (1400, 900), "card": (1200, 628),
}

POSTS = [
    ("f1", "fieldnotes", 25, "First light on the ridge. Woke at 4, hiked in the dark, and it was worth every blister.",
     ("photos", ["land_01"]), (64, 188, 2410, 12, 41200, 301), {}),
    ("f2", "mirakoski", 62, "Two directions for the onboarding illustration. Which one feels calmer?",
     ("photos", ["port_01", "port_02"]), (7, 11, 482, 3, 9800, 66), {}),
    ("f3", "tomasbuilds", 118, "Shipped v2.0 of my little habit tracker today. 14 months, 1 person, 0 trackers in the app. Thread on what I learned ↓",
     ("photos", ["shot_01"]), (31, 54, 1290, 8, 22400, 410), {}),
    ("f4", "orbitaldaily", 176, "Time-lapse: the Moon crossing the Pleiades, as seen from the Atacama last night.",
     ("video", "v_port_01"), (112, 940, 14800, 77, 402000, 1700), {}),
    ("f5", "hottakeshourly", 190, "Anyone who puts milk in before the cereal is a threat to society and I will not be taking questions.",
     None, (2400, 3100, 6200, 190, 710000, 40), {"hide": "outrage bait"}),
    ("f6", "lenapark", 66, "The second one. The shapes feel like they're exhaling.",
     None, (1, 0, 63, 0, 1200, 2), {"reply_to": "f2", "reply_handle": "mirakoski", "text_prefix": "@mirakoski "}),
    ("f7", "junocooks", 300, "Sunday bread. Three loaves, one very happy oven.",
     ("photos", ["sq_01", "port_03", "sq_02"]), (22, 31, 940, 2, 12100, 188), {}),
    ("f8", "kitwren", 362, "This is the best explanation of resonance I've seen. Playing it to my students tomorrow.",
     None, (6, 14, 391, 4, 5200, 40), {"quote": "a1"}),
    ("f9", "outragedaily", 370, "THEY don't want you to know what your coffee is doing to YOU. Retweet before this gets deleted!!!",
     None, (880, 4100, 3300, 61, 520000, 22), {"hide": "engagement bait"}),
    ("f10", "anyavoss", 420,
     "Why is the sky blue and the sunset red? A thread, but short.\n\nSunlight is every colour at once. Air molecules scatter short wavelengths (blue) far more than long ones (red).\n\nAt noon the light takes a short path through the atmosphere, so the blue scattered in every direction reaches you from everywhere. The whole sky glows.\n\nAt sunset the light takes a very long path. Most of the blue has been scattered away before it gets to you. What's left is the red and orange.\n\nSo the same physics paints both. The sky isn't blue at noon and red at dusk because something changed. The distance did.\n\nThe next time you see a red sun, you are looking through hundreds of kilometres of air.",
     None, (89, 702, 9100, 41, 188000, 2300), {}),
    ("f11", "maxplays", 480, "New devlog is up: how I made 300 tiny puzzles feel handmade without drawing a single one by hand.",
     ("card", {"cover": "card_01", "title": "Procedural puzzles with a human touch", "description": "A look at the generator, the rejected prototypes and the one rule that fixed everything.", "domain": "maxplays.example", "target": "https://maxplays.example/devlog/14"}),
     (9, 17, 412, 1, 6100, 84), {}),
    ("f12", "thelongwalk", 540, "Day 9. Rain all morning, then this.",
     ("photos", ["land_03"]), (18, 66, 1800, 3, 19200, 210), {}),
    ("f13", "hottakeshourly", 560, "Unpopular opinion that is actually extremely popular: everyone who disagrees with me is lying.",
     None, (1900, 2100, 5100, 99, 480000, 18), {"hide": "culture-war threads"}),
    ("f14", "samreyes_", 600, "Reminder that the quiet people in your life are keeping a lot of things from falling apart.",
     None, (14, 129, 3400, 6, 31000, 520), {}),
    ("f15", "inesduarte", 660, "Hoje o mar estava tão calmo que parecia um espelho. Fiquei a olhar até o sol sumir.",
     None, (3, 5, 211, 0, 2400, 12), {"lang": "pt"}),
    ("f16", "orbitaldaily", 700, "A calm one: Jupiter and its four largest moons, imaged this week from a backyard.",
     ("photos", ["land_05"]), (40, 211, 6100, 9, 98000, 640), {}),
    ("f17", "junocooks", 760, "Tried a new way of folding dumplings. Nine pleats is the magic number, apparently.",
     ("video", "v_land_01"), (30, 144, 2900, 6, 51000, 380), {}),
    ("f18", "mirakoski", 820, "A good empty state is a tiny piece of writing. Spent today rewriting ours.",
     ("photos", ["shot_02"]), (22, 40, 1100, 5, 17000, 290), {}),
    ("a1", "anyavoss", 700, "Why does a wine glass sing when you rub its rim? Friction makes the glass vibrate at its natural frequency — and the glass amplifies its own note. Resonance, up close.",
     ("photos", ["sq_03"]), (21, 133, 2200, 11, 41000, 800), {"hidden_from_feed": True}),
    ("o1", "noralind", 300, "Tried the new tab bar minimize on a real device and it's lovely. The small details really are the whole thing.",
     None, (4, 2, 61, 1, 1873, 9), {}),
    ("o2", "noralind", 1500, "Quiet Sunday. Coffee, a long walk and the first chapter of a book I've been saving.",
     ("photos", ["land_04"]), (6, 3, 144, 0, 2900, 14), {}),
    ("o3", "noralind", 2900, "Spent the morning on a loading state that doesn't flash. The trick is mostly not showing it at all.",
     None, (9, 7, 212, 2, 6400, 31), {}),
    ("o4", "noralind", 4300, "Hot take: a good skeleton screen is the shape of the thing, not a spinner pretending to be busy.",
     None, (14, 12, 388, 6, 11800, 52), {}),
    ("o5", "noralind", 6100, "Tried justified rows for a photo grid. Nothing cropped, nothing wasted, and it looks calm.",
     ("photos", ["land_02"]), (5, 4, 143, 1, 3200, 18), {}),
    ("r1", "lenapark", 66, "The second one. The shapes feel like they're exhaling.",
     None, (1, 0, 63, 0, 1200, 2), {"reply_to": "f2", "reply_handle": "mirakoski", "text_prefix": "@mirakoski ", "feed": False}),
    ("r1a", "mirakoski", 58, "that's exactly the word I was looking for. \"Exhaling\" is going in the brief.",
     None, (0, 0, 21, 0, 480, 0), {"reply_to": "r1", "reply_handle": "lenapark", "text_prefix": "@lenapark "}),
    ("r2", "tomasbuilds", 55, "First one has more tension, which might be what onboarding needs? Calm can read as \"nothing happens\".",
     None, (2, 0, 44, 0, 900, 3), {"reply_to": "f2", "reply_handle": "mirakoski", "text_prefix": "@mirakoski @lenapark "}),
    ("r3", "ravimenon", 50, "Could you do a version with the arch moved left? Asking for the empty-state variant.",
     None, (1, 0, 17, 0, 410, 1), {"reply_to": "f2", "reply_handle": "mirakoski", "text_prefix": "@mirakoski "}),
    ("r3a", "mirakoski", 41, "yes — doing that tomorrow.",
     None, (0, 0, 9, 0, 250, 0), {"reply_to": "r3", "reply_handle": "ravimenon", "text_prefix": "@ravimenon "}),
    ("r4", "inesduarte", 38, "Calm one. Always the calm one.",
     None, (0, 0, 12, 0, 300, 0), {"reply_to": "f2", "reply_handle": "mirakoski", "text_prefix": "@mirakoski "}),
    ("r5", "anyavoss", 30, "Second. Fewer competing focal points, and the negative space does real work.",
     None, (0, 1, 38, 0, 690, 2), {"reply_to": "f2", "reply_handle": "mirakoski", "text_prefix": "@mirakoski "}),
    ("q1", "mirakoski", 280, "It really is. Did you try the long-press on the compose button too?",
     None, (1, 0, 8, 0, 120, 0), {"reply_to": "o1", "reply_handle": "noralind", "text_prefix": "@noralind "}),
    ("q1a", "noralind", 270, "Just did. The glass menu is gorgeous.",
     None, (0, 0, 3, 0, 60, 0), {"reply_to": "q1", "reply_handle": "mirakoski", "text_prefix": "@mirakoski "}),
    ("q2", "tomasbuilds", 250, "Details are the whole thing. Saving this one.",
     None, (0, 0, 5, 0, 70, 0), {"reply_to": "o1", "reply_handle": "noralind", "text_prefix": "@noralind "}),
    ("x1", "lenapark", 52, "Putting these two side by side in my design crit tomorrow. Great example of tone through shape alone.",
     None, (2, 1, 48, 0, 1400, 6), {"quote": "f2", "hidden_from_feed": True}),
    ("x2", "tomasbuilds", 47, "Love seeing the process, not just the final pick. More of this please.",
     None, (0, 0, 19, 0, 620, 1), {"quote": "f2", "hidden_from_feed": True}),
    ("x3", "junocooks", 33, "This is how I feel choosing between two bread recipes.",
     None, (1, 0, 27, 0, 880, 0), {"quote": "f2", "hidden_from_feed": True}),
]

REPOSTS = {"f2": "kitwren", "f14": "noralind"}

TRANSLATIONS = {"f15": "Today the sea was so calm it looked like a mirror. I kept watching until the sun disappeared."}

ASK = {
    "explain": "The author is describing how air scatters sunlight. Short wavelengths (blue) scatter far more than long ones (red), so at noon the sky glows blue from every direction. At sunset the light crosses much more air, most of the blue is scattered away on the way, and the red and orange are what remain. The key idea is that the same physics produces both colours; only the distance changes.",
    "summary": "Blue light scatters more than red, so the daytime sky looks blue. At sunset light travels through far more atmosphere, the blue is scattered away and the reds are left.",
    "counter": "A fair pushback: the sky isn't violet, even though violet scatters more than blue. That's because the sun emits less violet and our eyes are less sensitive to it. The thread skips that detail, but it doesn't change the main point.",
    "eli5": "Sunlight is secretly all the colours mixed. The air bounces blue light around like a pinball, so you see blue everywhere. When the sun is low, the light has to travel through so much air that all the blue bounces away, and only red is left.",
    "entities": "Concepts: Rayleigh scattering, atmosphere, wavelength, sunset. People: none. Places: none.",
}
BRIEF = ("Dr. Anya Voss explains physics for a general audience: short threads that start from an everyday puzzle "
         "(why the sky is blue, why glasses sing) and end on the one idea that explains it. Tone is warm and exact; "
         "posts usually carry a diagram or a photo. Most-engaged topics: light, sound, resonance.")

FILTER_TOPICS = [
    "politics and election drama", "outrage bait", "engagement bait", "celebrity gossip",
    "crypto shilling", "culture-war threads",
]

ANALYTICS = {
    "o1": {"impressions": 1873, "engagements": 94, "detail_expands": 41, "profile_visits": 12, "link_clicks": 0,
           "follows": 2, "hourly_impressions": [3, 9, 24, 61, 140, 262, 318, 290, 224, 171, 130, 96, 74, 58, 44,
                                                  35, 28, 22, 17, 14, 11, 9, 7, 6, 5, 4, 4, 3, 3, 2, 2]},
    "o2": {"impressions": 2911, "engagements": 188, "detail_expands": 77, "profile_visits": 31, "link_clicks": 0,
           "follows": 5, "hourly_impressions": [12, 40, 98, 210, 380, 460, 410, 330, 250, 190, 150, 120, 98, 80, 66,
                                                  54, 44, 36, 30, 25, 21, 18, 15, 13, 11, 9, 8, 7]},
}


LAB = False


def lab_dims(name: str) -> tuple[int, int]:
    """The pixel size a media-lab chart is named for: `lab_1080x1920_b` or `vlab_720x720`."""
    w, h = name.split("_")[1].split("x")
    return int(w), int(h)


def lab_posts() -> list:
    """One post per case in the media lab: every aspect ratio alone, photo groups
    of two to five, clips, a link card and a quote of a tall photo."""
    def photos(*sizes):
        seen: dict[str, int] = {}
        names = []
        for size in sizes:
            count = seen.get(size, 0)
            seen[size] = count + 1
            names.append(f"lab_{size}" + (f"_{'abcde'[count - 1]}" if count else ""))
        return ("photos", names)

    counts = (3, 5, 120, 1, 2400, 12)
    cases = [
        ("1:1 square", photos("1080x1080")), ("4:3 landscape", photos("1600x1200")),
        ("3:2 landscape", photos("1620x1080")), ("16:9", photos("1920x1080")),
        ("21:9 ultrawide", photos("2100x900")), ("3:1 panorama", photos("3000x1000")),
        ("5:1 banner", photos("3000x600")), ("4:5 portrait", photos("1080x1350")),
        ("3:4 phone portrait", photos("1200x1600")), ("2:3 portrait", photos("1000x1500")),
        ("9:16 story", photos("1080x1920")), ("1:2 tall screenshot", photos("900x1800")),
        ("1:3 long screenshot", photos("1000x3000")), ("1:5 very long", photos("600x3000")),
        ("200×150 tiny", photos("200x150")),
        ("two landscapes", photos("1600x1200", "1600x1200")), ("two portraits", photos("1200x1600", "1200x1600")),
        ("landscape + portrait", photos("1600x1200", "1200x1600")),
        ("landscape + two portraits", photos("1600x1200", "1200x1600", "1200x1600")),
        ("portrait + two landscapes", photos("1200x1600", "1600x1200", "1600x1200")),
        ("four squares", photos("1080x1080", "1080x1080", "1080x1080", "1080x1080")),
        ("four mixed", photos("1920x1080", "1080x1920", "1080x1080", "1600x1200")),
        ("four stories", photos("1080x1920", "1080x1920", "1080x1920", "1080x1920")),
        ("two panoramas", photos("3000x1000", "3000x1000")), ("five photos", photos("1080x1080", "1600x1200", "1200x1600", "1920x1080", "1080x1080")),
        ("two long screenshots", photos("1000x3000", "1000x3000")),
        ("16:9 clip", ("video", "vlab_1280x720")), ("9:16 clip", ("video", "vlab_720x1280")),
        ("1:1 clip", ("video", "vlab_720x720")), ("4:5 clip", ("video", "vlab_864x1080")),
        ("21:9 clip", ("video", "vlab_1260x540")), ("9:16 GIF", ("gif", "vlab_720x1280")),
        ("1.91:1 link card", ("card", {"cover": "lab_1200x628", "title": "A link with a wide cover image",
                                       "description": "The cover is drawn whole, whatever its shape.",
                                       "domain": "example.com", "target": "https://example.com/a"})),
    ]
    posts = []
    for i, (title, media) in enumerate(cases):
        posts.append((f"m{i:02d}", "medialab", 5 + i * 2, f"{title}", media, counts, {}))
    posts.append(("m90", "medialab", 90, "quoting a 1:3 long screenshot", None, counts, {"quote": "m12"}))
    return posts


def enable_lab() -> None:
    """Turns the mock into the media lab: the Home feed becomes the lab posts."""
    global LAB
    LAB = True
    CAST.append(("medialab", "Media Lab", True, 1000, 10, "a05", "b05", ("Finland", "FI", "🇫🇮")))
    HANDLES["medialab"] = len(CAST)
    POSTS[:] = lab_posts() + POSTS


class World:
    def __init__(self, base: str):
        self.base = base.rstrip("/")
        self.by_key = {}
        self.ids = {}
        for i, post in enumerate(POSTS):
            self.ids[post[0]] = snowflake(i + 1)
        self.users = {c[0]: self._user(c) for c in CAST}
        for post in POSTS:
            self.by_key[post[0]] = self._tweet(post)


    def asset(self, kind: str, name: str, ext: str = "jpg") -> str:
        return f"{self.base}/assets/{kind}/{name}.{ext}"

    def _user(self, c, *, banner: bool = False) -> dict:
        handle, name, verified, followers, following, avatar, banner_name, _ = c
        user = {
            "rest_id": str(1000 + HANDLES[handle]), "handle": handle, "name": name, "verified": verified,
            "followers": followers, "following": following,
            "avatar_url": self.asset("avatars", avatar),
        }
        if banner:
            user["banner_url"] = self.asset("banners", banner_name)
        return user

    def profile_user(self, handle: str) -> dict:
        c = next(c for c in CAST if c[0] == handle)
        user = self._user(c, banner=True)
        user["followed_by_me"] = handle in ("mirakoski", "fieldnotes", "anyavoss", "kitwren", "quietfern")
        details = PROFILES.get(handle)
        if details:
            bio, location, website, joined = details
            user["description"] = bio
            user["location"] = location
            if website:
                user["website"] = website
            user["joined_at"] = joined
        if handle in PROTECTED:
            user["protected"] = True
        return user

    def _media(self, spec, tweet_key):
        if spec is None:
            return []
        kind, value = spec
        if kind == "photos":
            out = []
            for name in value:
                group = name.split("_")[0]
                w, h = lab_dims(name) if group == "lab" else MEDIA_DIMS[group]
                alt = "A test chart with a smiley, a circle and a coloured triangle in each corner" if name.startswith("lab_1600x1200") else None
                out.append({"kind": "photo", "url": self.asset("photos", name), "video_url": None,
                            "alt_text": alt, "width": w, "height": h})
            return out
        if kind in ("video", "gif"):
            if value.startswith("vlab_"):
                w, h = lab_dims(value)
            else:
                vertical = value.startswith("v_port")
                w, h = (9, 16) if vertical else (16, 9)
            return [{"kind": "video" if kind == "video" else "animated_gif", "url": self.asset("videos", value),
                     "video_url": self.asset("videos", value, "mp4"), "alt_text": None, "width": w, "height": h}]
        if kind == "card":
            return [{"kind": {"link_card": {"title": value["title"], "description": value["description"],
                                            "domain": value["domain"], "target_url": value["target"]}},
                     "url": self.asset("photos", value["cover"]), "video_url": None, "alt_text": None}]
        raise ValueError(kind)

    def _tweet(self, post) -> dict:
        key, handle, minutes, text, media, counts, extra = post
        replies, reposts, likes, quotes, views, bookmarks = counts
        rid = self.ids[key]
        tweet = {
            "rest_id": rid,
            "author": self.users[handle],
            "created_at": ago(minutes=minutes),
            "text": extra.get("text_prefix", "") + text,
            "reply_count": replies, "retweet_count": reposts, "like_count": likes, "quote_count": quotes,
            "view_count": views, "bookmark_count": bookmarks,
            "favorited": False, "retweeted": False, "bookmarked": False,
            "lang": extra.get("lang", "en"),
            "in_reply_to_tweet_id": None,
            "quoted_tweet": None,
            "media": self._media(media, key),
            "url": f"https://x.com/{handle}/status/{rid}",
            "urls": [],
        }
        if "reply_to" in extra:
            tweet["in_reply_to_tweet_id"] = self.ids[extra["reply_to"]]
            tweet["in_reply_to_handle"] = extra["reply_handle"]
        return tweet

    def tweet(self, key: str) -> dict:
        tweet = dict(self.by_key[key])
        spec = next(p for p in POSTS if p[0] == key)
        quote = spec[6].get("quote")
        if quote:
            tweet["quoted_tweet"] = dict(self.by_key[quote])
        return tweet

    def home_tweet(self, key: str) -> dict:
        tweet = self.tweet(key)
        reposter = REPOSTS.get(key)
        if reposter:
            tweet["retweeted_by"] = self.users[reposter]
            tweet["retweeted"] = tweet["retweeted"] or reposter == ME
        return tweet

    def quotes_of(self, key: str) -> list[dict]:
        return [self.tweet(p[0]) for p in POSTS if p[6].get("quote") == key]

    def tweet_by_id(self, rest_id: str):
        for key, rid in self.ids.items():
            if rid == rest_id:
                return key
        return None


    def home_keys(self) -> list[str]:
        if LAB:
            return [p[0] for p in POSTS if p[1] == "medialab"]
        keys = []
        for post in POSTS:
            key, extra = post[0], post[6]
            if key.startswith(("r", "q", "a", "o")) and key != "f6":
                continue
            if extra.get("hidden_from_feed") or extra.get("feed") is False:
                continue
            keys.append(key)
        keys.insert(2, "o1")
        return keys

    def hidden_reason(self, rest_id: str):
        key = self.tweet_by_id(rest_id)
        if not key:
            return None
        spec = next(p for p in POSTS if p[0] == key)
        return spec[6].get("hide")

    def user_keys(self, handle: str) -> list[str]:
        return [p[0] for p in POSTS if p[1] == handle and not p[0].startswith(("r", "q"))]

    def thread(self, key: str) -> dict:
        focal = self.tweet(key)
        ancestors = []
        parent = self.by_key[key].get("in_reply_to_tweet_id")
        while parent:
            pk = self.tweet_by_id(parent)
            ancestors.insert(0, self.tweet(pk))
            parent = self.by_key[pk].get("in_reply_to_tweet_id")
        replies = []

        def walk(parent_id):
            children = [p[0] for p in POSTS
                        if self.by_key[p[0]].get("in_reply_to_tweet_id") == parent_id and p[0] != "f6"]
            for child in children:
                replies.append(self.tweet(child))
                walk(self.ids[child])

        walk(self.ids[key])
        return {"focal": focal, "ancestors": ancestors, "replies": replies, "cursor": None}

    def many_notifications(self) -> list[dict]:
        """A long run of older activity, all kinds, for scrolling into its later pages."""
        handles = [c[0] for c in CAST if c[0] != ME]
        kinds = ["Like", "Like", "Retweet", "Like", "Follow", "Reply", "Like", "Mention"]
        texts = ["More like Coinbased.", "Robert knows ball", "Short one.",
                 "I am excited about my token limits resetting. In the pre-LLM age, I used to feel like this after I had been on vacation from work for over 3 weeks. I couldn't WAIT to get back at it.",
                 "Nice thread", "Seconded.", "Why does this keep happening? Every single time, the same thing, and nobody learns."]
        out = []
        for index in range(90):
            handle = handles[index % len(handles)]
            kind = kinds[index % len(kinds)]
            user = self.users[handle]
            actor = {"handle": user["handle"], "name": user["name"], "rest_id": user["rest_id"],
                     "verified": user["verified"], "avatar_url": user["avatar_url"]}
            item = {"id": f"old{index}", "type": kind, "actors": [actor], "target_media": [],
                    "timestamp": ago(hours=8 + index * 3)}
            if kind != "Follow":
                item["target_tweet_id"] = self.ids["o1"]
                item["target_tweet_snippet"] = texts[index % len(texts)]
                item["target_tweet_like_count"] = (index * 7) % 40
            out.append(item)
        return out

    def notifications(self) -> list[dict]:
        def actor(handle):
            u = self.users[handle]
            return {"handle": u["handle"], "name": u["name"], "rest_id": u["rest_id"], "verified": u["verified"],
                    "avatar_url": u["avatar_url"]}

        o1 = self.by_key["o1"]
        o2 = self.by_key["o2"]
        clip = self.by_key["f17"]
        return [
            {"id": "n1", "type": "Like", "actors": [actor("mirakoski"), actor("anyavoss"), actor("fieldnotes")],
             "others_count": 41, "target_tweet_id": o2["rest_id"], "target_tweet_snippet": o2["text"],
             "target_tweet_like_count": 1432, "target_media": o2["media"], "timestamp": ago(minutes=6)},
            {"id": "n2", "type": "Reply", "actors": [actor("tomasbuilds")], "target_tweet_id": self.ids["q2"],
             "target_tweet_snippet": "Details are the whole thing. Saving this one. Also: the way the tab bar tucks away on scroll is the nicest thing I have used all year 🙌",
             "target_media": [], "timestamp": ago(minutes=11)},
            {"id": "n3", "type": "Follow", "actors": [actor("kitwren"), actor("junocooks")], "others_count": 6,
             "target_media": [], "timestamp": ago(minutes=38)},
            {"id": "n3b", "type": "Follow", "actors": [actor("maxplays")], "target_media": [],
             "timestamp": ago(minutes=52)},
            {"id": "n4", "type": "Retweet", "actors": [actor("orbitaldaily")], "target_tweet_id": o1["rest_id"],
             "target_tweet_snippet": o1["text"], "target_tweet_like_count": 61, "target_media": [],
             "timestamp": ago(minutes=64)},
            {"id": "n5", "type": "Mention", "actors": [actor("lenapark")], "target_tweet_id": self.ids["f6"],
             "target_tweet_snippet": "@noralind have you seen Mira's two onboarding directions?", "target_media": [],
             "timestamp": ago(minutes=95)},
            {"id": "n6", "type": "Like", "actors": [actor("ravimenon"), actor("inesduarte")], "others_count": 4,
             "target_tweet_id": o1["rest_id"], "target_tweet_snippet": o1["text"], "target_tweet_like_count": 61,
             "target_media": [], "timestamp": ago(minutes=130)},
            {"id": "n6b", "type": "Quote", "actors": [actor("fieldnotes")], "target_tweet_id": self.ids["q2"],
             "target_tweet_snippet": "This is the whole job, really. Taste is just noticing more than other people do.",
             "target_media": clip["media"], "timestamp": ago(hours=4)},
            {"id": "n7", "type": "Follow", "actors": [actor("quietfern")], "target_media": [],
             "timestamp": ago(hours=6)},
            {"id": "n8", "type": "Like", "actors": [actor("samreyes_")], "target_tweet_id": o2["rest_id"],
             "target_tweet_snippet": "", "target_tweet_like_count": 1432, "target_media": o2["media"],
             "timestamp": ago(hours=19)},
            {"id": "n9", "type": "Poll", "actors": [], "message": "Your poll has ended", "target_media": [],
             "timestamp": ago(hours=26)},
            {"id": "n10", "type": "Reply", "actors": [actor("thelongwalk")], "target_tweet_id": self.ids["q2"],
             "target_tweet_snippet": "Seconded.", "target_media": [], "timestamp": ago(days=2)},
            {"id": "n11", "type": "Like", "actors": [actor("orbitaldaily"), actor("junocooks"), actor("kitwren")],
             "others_count": 1200, "target_tweet_id": o1["rest_id"], "target_tweet_snippet": o1["text"],
             "target_tweet_like_count": 18400, "target_media": [], "timestamp": ago(days=3)},
            {"id": "n12", "type": "Follow", "actors": [actor("hottakeshourly")], "target_media": [],
             "timestamp": ago(days=9)},
        ]
