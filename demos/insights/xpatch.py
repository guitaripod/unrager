"""Turns X's own answers about the signed-in account into Nora Lind's, so
x.com's real web app draws the made-up profile and posts in `world` exactly
as it draws anyone's. The account's real responses are only templates: every
field a picture could show (names, bio, counts, posts, pictures, the birthday
on the profile) is replaced, and anything about other real accounts (who to
follow, conversations) is dropped.
"""

from __future__ import annotations

import copy
import json
from datetime import datetime

from world import AVATAR_BASE, ME, ME_BIO, ME_FOLLOWERS, ME_FOLLOWING, ME_LOCATION, ME_NAME, ME_POSTS, World

ME_AVATAR = f"{AVATAR_BASE}/a01_normal.jpg"
ME_BANNER = "https://pbs.twimg.com/profile_banners/demo/b01"
MEDIA_BASE = "https://pbs.twimg.com/media/demo_"
CARD_BASE = "https://pbs.twimg.com/card_img/demo/"


def x_time(when: datetime) -> str:
    return when.strftime("%a %b %d %H:%M:%S +0000 %Y")


class Patcher:
    def __init__(self, world: World, real_id: str, real_handle: str, real_name: str):
        self.world = world
        self.real_id = real_id
        self.real_handle = real_handle
        self.real_name = real_name
        self.templates: dict[str, dict] = {}
        self.entry_template: dict | None = None
        self.pin_template: dict | None = None
        self.template_post_id: str | None = None
        self.me_user: dict | None = None
        self.real_avatar_ids: set[str] = set()

    def text(self, body: str) -> str:
        """Plain replacements for what isn't worth parsing (the page's
        initial state, small viewer answers)."""
        for real_avatar in self.real_avatar_ids:
            body = body.replace(real_avatar, ME_AVATAR)
        return body.replace(self.real_handle, ME).replace(self.real_name, ME_NAME)

    def patch_user(self, u: dict) -> dict:
        avatar = (u.get("avatar") or {}).get("image_url")
        if avatar:
            self.real_avatar_ids.add(avatar)
        u["core"] = {"created_at": "Thu Mar 12 09:00:00 +0000 2015", "name": ME_NAME, "screen_name": ME}
        u["avatar"] = {"image_url": ME_AVATAR}
        u["banner"] = {"image_url": ME_BANNER}
        u["profile_bio"] = {"description": ME_BIO, "entities": {"description": {"urls": []}}}
        u["location"] = {"location": ME_LOCATION}
        u["relationship_counts"] = {"followers": ME_FOLLOWERS, "following": ME_FOLLOWING}
        u["tweet_counts"] = {"tweets": ME_POSTS, "media_tweets": 312}
        u["is_blue_verified"] = False
        u["verification"] = {"verified": False}
        u["creator_subscriptions_count"] = 0
        u["has_hidden_subscriptions_on_profile"] = False
        u["pinned_items"] = {"tweet_ids_str": [self.world.by_key["hero"]["id"]]}
        u["profile_image_shape"] = "Circle"
        for key in ("website", "legacy_extended_profile", "professional", "highlights_info", "verification_info",
                    "affiliates_highlighted_label", "business_account", "user_seed_tweet_count"):
            u.pop(key, None)
        legacy = u.get("legacy")
        if isinstance(legacy, dict):
            legacy.update({
                "name": ME_NAME, "screen_name": ME, "description": ME_BIO, "location": ME_LOCATION,
                "followers_count": ME_FOLLOWERS, "friends_count": ME_FOLLOWING, "statuses_count": ME_POSTS,
                "profile_image_url_https": ME_AVATAR, "profile_banner_url": ME_BANNER, "url": None,
                "entities": {"description": {"urls": []}},
            })
        return u

    def walk_users(self, node) -> None:
        """Every user object that is the signed-in account, wherever it sits."""
        if isinstance(node, dict):
            if node.get("rest_id") == self.real_id and ("core" in node or "legacy" in node) and node.get("__typename", "User") == "User":
                self.patch_user(node)
                if self.me_user is None:
                    self.me_user = copy.deepcopy(node)
            for value in node.values():
                self.walk_users(value)
        elif isinstance(node, list):
            for value in node:
                self.walk_users(value)

    def learn(self, instructions: list) -> None:
        """Keeps one of the account's own posts of each kind (plain, one
        photo, a link card) as the template the made-up posts are cut from."""
        for ins in instructions:
            entries = ins.get("entries") or ([ins["entry"]] if ins.get("entry") else [])
            if ins.get("type") == "TimelinePinEntry" and ins.get("entry"):
                self.pin_template = self.pin_template or copy.deepcopy(ins)
            for entry in entries:
                item = (entry.get("content") or {}).get("itemContent")
                if not item or item.get("itemType") != "TimelineTweet":
                    continue
                result = item["tweet_results"].get("result") or {}
                result = result.get("tweet", result)
                legacy = result.get("legacy") or {}
                if legacy.get("user_id_str") != self.real_id or result.get("quoted_status_result"):
                    continue
                media = (legacy.get("extended_entities") or {}).get("media") or []
                kind = "card" if result.get("card") else "photo" if len(media) == 1 and media[0].get("type") == "photo" else "plain" if not media else None
                if kind and kind not in self.templates:
                    self.templates[kind] = copy.deepcopy(result)
                    if kind == "plain":
                        self.template_post_id = result["rest_id"]
                if self.entry_template is None and entry.get("entryId", "").startswith("tweet-"):
                    self.entry_template = copy.deepcopy(entry)

    def tweet(self, post: dict) -> dict:
        kind = "card" if post.get("card") and "card" in self.templates else "photo" if post.get("photo") and "photo" in self.templates else "plain"
        r = copy.deepcopy(self.templates.get(kind) or self.templates["plain"])
        pid = post["id"]
        r["__typename"] = "Tweet"
        r["rest_id"] = pid
        for key in ("card", "quoted_status_result", "note_tweet", "previous_counts", "birdwatch_pivot", "grok_annotations"):
            r.pop(key, None)
        counts = post["counts"]
        text = post["text"]
        legacy = r["legacy"]
        for key in ("extended_entities", "quoted_status_id_str", "quoted_status_permalink", "in_reply_to_status_id_str",
                    "in_reply_to_user_id_str", "in_reply_to_screen_name", "retweeted_status_result"):
            legacy.pop(key, None)
        legacy.update({
            "id_str": pid, "conversation_id_str": pid, "user_id_str": self.real_id, "created_at": x_time(post["created"]),
            "full_text": text, "display_text_range": [0, len(text)], "lang": "en", "is_quote_status": False,
            "favorite_count": counts["likes"], "retweet_count": counts["reposts"], "reply_count": counts["replies"],
            "quote_count": counts["quotes"], "bookmark_count": counts["bookmarks"],
            "favorited": False, "retweeted": False, "bookmarked": False, "possibly_sensitive": False,
            "entities": {"hashtags": [], "symbols": [], "timestamps": [], "urls": [], "user_mentions": []},
        })
        r["views"] = {"count": str(counts["views"]), "state": "EnabledWithCount"}
        if r.get("edit_control"):
            r["edit_control"] = {"edit_tweet_ids": [pid], "editable_until_msecs": "0", "edits_remaining": "0", "is_edit_eligible": False}
        if self.me_user:
            r["core"] = {"user_results": {"result": copy.deepcopy(self.me_user)}}
        tco = f"https://t.co/demo{pid[-6:]}"
        if kind == "photo":
            name, width, height = post["photo"]
            media = copy.deepcopy(self.templates["photo"]["legacy"]["extended_entities"]["media"][0])
            media_id = str(int(pid) + 17)
            media.update({
                "id_str": media_id, "media_key": f"3_{media_id}", "media_results": {"result": {"media_key": f"3_{media_id}"}},
                "media_url_https": f"{MEDIA_BASE}{name}.jpg", "url": tco, "display_url": f"pic.x.com/demo{pid[-6:]}",
                "expanded_url": f"https://x.com/{ME}/status/{pid}/photo/1", "indices": [len(text) + 1, len(text) + 1 + len(tco)],
                "original_info": {"width": width, "height": height, "focus_rects": []},
                "sizes": {
                    "large": {"w": width, "h": height, "resize": "fit"}, "medium": {"w": 1200, "h": round(1200 * height / width), "resize": "fit"},
                    "small": {"w": 680, "h": round(680 * height / width), "resize": "fit"}, "thumb": {"w": 150, "h": 150, "resize": "crop"},
                },
                "features": {}, "ext_alt_text": None,
            })
            media.pop("ext_alt_text", None)
            legacy["full_text"] = f"{text} {tco}"
            legacy["entities"]["media"] = [media]
            legacy["extended_entities"] = {"media": [media]}
        if kind == "card":
            card = post["card"]
            legacy["full_text"] = f"{text} {tco}"
            legacy["entities"]["urls"] = [{
                "url": tco, "expanded_url": card["url"], "display_url": card["url"].split("://", 1)[1],
                "indices": [len(text) + 1, len(text) + 1 + len(tco)],
            }]
            template = self.templates["card"]["card"]["legacy"]
            strings = {"title": card["title"], "description": card["description"], "domain": card["domain"],
                       "vanity_url": card["domain"], "card_url": tco}
            bindings = []
            for binding in copy.deepcopy(template["binding_values"]):
                key, value = binding["key"], binding["value"]
                if key.startswith("app_") or key == "site":
                    continue
                if value.get("type") == "IMAGE":
                    query = value["image_value"]["url"].split("?", 1)[1] if "?" in value["image_value"]["url"] else ""
                    value["image_value"]["url"] = f"{CARD_BASE}{card['image']}?{query}"
                elif key in strings:
                    value["string_value"] = strings[key]
                bindings.append(binding)
            r["card"] = {
                "rest_id": tco,
                "legacy": {
                    "binding_values": bindings,
                    "card_platform": template.get("card_platform"),
                    "name": "summary_large_image",
                    "url": tco,
                    "user_refs_results": [],
                },
            }
        return r

    def entry(self, post: dict) -> dict:
        e = copy.deepcopy(self.entry_template)
        e["entryId"] = f"tweet-{post['id']}"
        e["sortIndex"] = post["id"]
        item = e["content"]["itemContent"]
        item["tweet_results"] = {"result": self.tweet(post)}
        item.pop("socialContext", None)
        item["tweetDisplayType"] = "Tweet"
        return e

    def timeline(self, body: dict, page_after_first: bool) -> dict:
        """The profile's posts: the hero pinned, then the rest newest first;
        a request for the next page gets nothing more."""
        timeline = body["data"]["user"]["result"]["timeline"]["timeline"]
        instructions = timeline["instructions"]
        self.walk_users(body)
        self.learn(instructions)
        cursors = []
        for ins in instructions:
            for entry in ins.get("entries") or []:
                if entry.get("entryId", "").startswith("cursor-"):
                    cursors.append(entry)
        if page_after_first or not self.entry_template:
            timeline["instructions"] = [{"type": "TimelineAddEntries", "entries": []}]
            return body
        hero = self.world.by_key["hero"]
        entries = [self.entry(p) for p in self.world.posts if p is not hero]
        out = [{"type": "TimelineClearCache"}]
        if self.pin_template:
            pin = copy.deepcopy(self.pin_template)
            pin["entry"]["entryId"] = f"tweet-{hero['id']}"
            pin["entry"]["sortIndex"] = hero["id"]
            pin["entry"]["content"]["itemContent"]["tweet_results"] = {"result": self.tweet(hero)}
            out.append(pin)
        else:
            entries.insert(0, self.entry(hero))
        out.append({"type": "TimelineAddEntries", "entries": entries + [c for c in cursors if "top" in c["entryId"]]})
        timeline["instructions"] = out
        return body

    def detail(self, body: dict, focal_id: str) -> dict:
        """A post's own page for one of the made-up posts: the post alone,
        nobody's replies."""
        self.walk_users(body)
        post = self.world.by_id.get(focal_id)
        data = body.get("data", {}).get("threaded_conversation_with_injections_v2", {})
        for ins in data.get("instructions", []):
            if ins.get("type") != "TimelineAddEntries":
                continue
            keep = []
            for entry in ins.get("entries", []):
                item = (entry.get("content") or {}).get("itemContent")
                if item and item.get("itemType") == "TimelineTweet" and post and entry["entryId"] == f"tweet-{self.template_post_id}":
                    entry["entryId"] = f"tweet-{focal_id}"
                    entry["sortIndex"] = focal_id
                    item["tweet_results"] = {"result": self.tweet(post)}
                    keep.append(entry)
            ins["entries"] = keep
        return body


def loads(text: str):
    try:
        return json.loads(text)
    except ValueError:
        return None
