#!/usr/bin/env python3
"""A stand-in for `unrager serve` that answers with a made-up world.

The iPhone app talks to it exactly as it talks to the real server (same paths
and JSON), so a demo can be recorded without anyone's real timeline on screen.

    python3 mock_server.py [--port 8790] [--assets assets]

Then launch the app with `-unrager.serverURL http://127.0.0.1:8790`.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import demo_world as dw  # noqa: E402

PAGE = 8
STATE = {"filter_enabled": True, "likes": set(), "bookmarks": set(), "retweets": set(), "overrides": {},
         "deleted": set(), "muting": {"hottakeshourly"}, "blocking": set(), "replies": []}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    assets_dir = "assets"

    def log_message(self, fmt, *args):
        if os.environ.get("MOCK_VERBOSE"):
            sys.stderr.write("%s %s\n" % (self.command, self.path))

    @property
    def world(self) -> dw.World:
        return dw.World("http://" + (self.headers.get("Host") or "127.0.0.1:8790"))


    def send_json(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("x-unrager-version", "0.24.0")
        self.end_headers()
        self.wfile.write(data)

    def send_error_json(self, status, kind, message):
        self.send_json({"error": message, "kind": kind}, status)

    def send_unavailable(self, reason, message):
        self.send_json({"error": message, "kind": "unavailable", "reason": reason}, 410)

    @staticmethod
    def hides_posts(handle):
        """A protected account's posts, which only its approved followers see."""
        return handle in dw.PROTECTED

    def moderate(self, path, on):
        """`POST`/`DELETE /api/users/{id}/mute|block`: flips the flag the
        profile reports, keyed by rest_id or handle as the server accepts."""
        m = re.fullmatch(r"/api/users/(\w+)/(mute|block)", path)
        if not m:
            return False
        ident, action = m.groups()
        handle = next((h for h, i in dw.HANDLES.items() if str(1000 + i) == ident), ident.lower())
        key = "muting" if action == "mute" else "blocking"
        (STATE[key].add if on else STATE[key].discard)(handle)
        self.send_json({"ok": True, key: on})
        return True

    def read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def sse(self, events, delay=0.0):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for event in events:
                self.wfile.write(b"data: " + (event if isinstance(event, str) else json.dumps(event)).encode() + b"\n\n")
                self.wfile.flush()
                if delay:
                    time.sleep(delay)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def tokens(self, text, delay=0.03):
        words = re.findall(r"\S+\s*", text)
        events = [{"token": w, "done": False} for w in words] + [{"token": "", "done": True}]
        self.sse(events, delay)


    def serve_asset(self, path: str):
        rel = path[len("/assets/"):]
        full = os.path.normpath(os.path.join(self.assets_dir, rel))
        root = os.path.abspath(self.assets_dir)
        if not os.path.abspath(full).startswith(root) or not os.path.isfile(full):
            return self.send_error_json(404, "not_found", "no such asset")
        size = os.path.getsize(full)
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        start, end = 0, size - 1
        status = 200
        match = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
        if match:
            if match.group(1):
                start = int(match.group(1))
            if match.group(2):
                end = min(int(match.group(2)), size - 1)
            if not match.group(1) and match.group(2):
                start, end = max(0, size - int(match.group(2))), size - 1
            status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        try:
            with open(full, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass


    def do_GET(self):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        q = lambda name, default=None: (query.get(name) or [default])[0]
        w = self.world

        if path.startswith("/assets/"):
            return self.serve_asset(path)
        if path == "/api/health":
            return self.send_json({"ok": True, "name": "unrager", "version": "0.24.0"})
        if path == "/api/whoami":
            me = w.users[dw.ME]
            return self.send_json({"handle": me["handle"], "name": me["name"], "rest_id": me["rest_id"]})
        if path == "/api/session":
            return self.send_json({"current_source": None, "feed_mode": "all", "filter_enabled": STATE["filter_enabled"], "theme": None})
        if path == "/api/config/filter":
            return self.send_json({
                "drop_topics": dw.FILTER_TOPICS, "extra_guidance": "", "strictness": "balanced",
                "built_in_rules": ["outrage bait", "engagement bait", "rage framing", "doom spirals", "dunking"],
                "ollama": {"backend": "ollama", "model": "gemma4:26b", "host": "localhost:11434"},
            })
        if path == "/api/feed/status":
            return self.send_json({"feeds": [
                {"variant": "home_foryou", "last_ingest_at": int(time.time()) - 140, "last_ingest_count": 40, "age_secs": 140},
                {"variant": "home_following", "last_ingest_at": int(time.time()) - 140, "last_ingest_count": 40, "age_secs": 140},
            ]})
        if path == "/api/sources/home":
            keys = [k for k in w.home_keys() if w.ids[k] not in STATE["deleted"]]
            return self.send_json(self.page([self.engaged(w.home_tweet(k)) for k in keys], q("cursor")))
        if path.startswith("/api/sources/user/"):
            handle = path.split("/")[4]
            if handle in dw.SUSPENDED:
                return self.send_unavailable("suspended", "This account is suspended.")
            if self.hides_posts(handle):
                return self.send_unavailable("protected", "These posts are protected.")
            tail = path.split("/")[5:] and path.split("/")[5]
            keys = [k for k in w.user_keys(handle) if w.ids[k] not in STATE["deleted"]]
            if tail == "replies":
                keys = keys + [p[0] for p in dw.POSTS if p[1] == handle and p[0].startswith(("r", "q"))]
            page = self.page([w.tweet(k) for k in keys], q("cursor"))
            pinned = dw.PINNED.get(handle)
            if pinned and tail != "replies" and not q("cursor") and w.ids[pinned] not in STATE["deleted"]:
                page["pinned"] = w.tweet(pinned)
            return self.send_json(page)
        if path == "/api/sources/search":
            text = (q("q") or "").lower().lstrip("#")
            hits = [w.tweet(p[0]) for p in dw.POSTS if text and text in p[3].lower() and not p[6].get("hide")]
            return self.send_json({"tweets": hits[:20], "cursor": None})
        if path == "/api/sources/search/people":
            text = (q("q") or "").lower()
            users = [w.profile_user(c[0]) for c in dw.CAST if text in c[0] or text in c[1].lower()]
            return self.send_json({"users": users[:10], "cursor": None})
        if path in ("/api/sources/mentions", "/api/sources/bookmarks"):
            keys = ["r3a", "q1"] if path.endswith("mentions") else ["f1", "f10"]
            return self.send_json({"tweets": [w.tweet(k) for k in keys], "cursor": None})
        if path == "/api/sources/notifications":
            return self.send_json({"notifications": w.notifications(), "cursor": None})
        if path == "/api/notifications/seen":
            return self.send_json({"marker": None})
        m = re.fullmatch(r"/api/tweet/(\d+)", path)
        if m:
            key = w.tweet_by_id(m.group(1))
            return self.send_json(w.tweet(key)) if key else self.send_error_json(404, "not_found", "no such post")
        m = re.fullmatch(r"/api/thread/(\d+)", path)
        if m:
            key = w.tweet_by_id(m.group(1))
            return self.send_json(self.with_posted_replies(w.thread(key))) if key else self.send_error_json(404, "not_found", "no such post")
        m = re.fullmatch(r"/api/profile/(\w+)", path)
        if m:
            handle = m.group(1).lower()
            if handle in dw.SUSPENDED:
                return self.send_unavailable("suspended", "This account is suspended.")
            if handle not in {c[0] for c in dw.CAST}:
                return self.send_error_json(404, "not_found", f"@{handle} doesn't exist.")
            user = w.profile_user(handle)
            user["muting"] = handle in STATE["muting"]
            user["blocking"] = handle in STATE["blocking"]
            hidden = q("tweets") == "false" or self.hides_posts(handle)
            keys = [] if hidden else [k for k in w.user_keys(handle) if w.ids[k] not in STATE["deleted"]]
            return self.send_json({"user": user, "pinned": None,
                                   "recent": [w.tweet(k) for k in keys[:8]], "cursor": None})
        m = re.fullmatch(r"/api/about/(\d+)", path)
        if m:
            handle = q("screen_name", "")
            cast = next((c for c in dw.CAST if c[0] == handle), None)
            if not cast:
                return self.send_json({"status": "none"})
            country, alpha2, flag = cast[7]
            return self.send_json({"status": "resolved", "alpha2": alpha2, "flag": flag, "profile": {
                "rest_id": m.group(1), "handle": handle, "name": cast[1], "account_based_in": country,
                "is_blue_verified": cast[2], "verified": cast[2]}})
        m = re.fullmatch(r"/api/likers/(\d+)", path)
        if m:
            return self.send_json({"users": [w.profile_user(h) for h in ("mirakoski", "anyavoss", "fieldnotes", "kitwren", "lenapark")], "cursor": None})
        m = re.fullmatch(r"/api/users/(\d+)/(followers|following)", path)
        if m:
            handles = [c[0] for c in dw.CAST if c[0] != dw.ME][:12]
            return self.send_json({"users": [w.profile_user(h) for h in handles], "cursor": None})
        m = re.fullmatch(r"/api/tweets/(\d+)/quotes", path)
        if m:
            key = w.tweet_by_id(m.group(1))
            if not key:
                return self.send_error_json(404, "not_found", "no such post")
            return self.send_json(self.page(w.quotes_of(key), q("cursor")))
        m = re.fullmatch(r"/api/tweets/(\d+)/analytics", path)
        if m:
            key = w.tweet_by_id(m.group(1))
            data = dw.ANALYTICS.get(key)
            return self.send_json(data) if data else self.send_error_json(404, "not_found", "no analytics for this post")
        m = re.fullmatch(r"/api/seen/(\d+)", path)
        if m:
            return self.send_json({"id": m.group(1), "seen": False})
        if path == "/api/sse/filter":
            ids = [i for i in (q("ids") or "").split(",") if i]
            events = []
            for rid in ids:
                reason = w.hidden_reason(rid)
                if STATE["filter_enabled"] and reason and rid not in STATE["overrides"]:
                    events.append({"id": rid, "verdict": "hide", "reason": reason})
                else:
                    events.append({"id": rid, "verdict": "keep"})
            return self.sse(events, 0.02)
        if path == "/api/sse/ask":
            return self.tokens(dw.ASK.get(q("preset", "explain"), dw.ASK["explain"]))
        if path == "/api/sse/translate":
            key = w.tweet_by_id(q("tweet_id", ""))
            return self.tokens(dw.TRANSLATIONS.get(key, "Today the sea was so calm it looked like a mirror."))
        if path == "/api/sse/brief":
            return self.tokens(dw.BRIEF)
        return self.send_error_json(404, "not_found", f"no route for {path}")

    def do_POST(self):
        path = urlparse(self.path).path
        body = self.read_body()
        if path == "/api/seen":
            ids = json.loads(body or b"{}").get("ids", [])
            return self.send_json({"marked": len(ids)})
        if path == "/api/filter/overrides":
            data = json.loads(body or b"{}")
            for rid in data.get("ids", []):
                STATE["overrides"][rid] = data.get("verdict")
            return self.send_json({"ok": True})
        if path == "/api/sse/ask":
            return self.tokens(dw.ASK["explain"])
        if self.moderate(path, True):
            return
        m = re.fullmatch(r"/api/engage/(\d+)/(like|unlike)", path)
        if m:
            (STATE["likes"].add if m.group(2) == "like" else STATE["likes"].discard)(m.group(1))
        if re.fullmatch(r"/api/(engage|tweets)/.+", path) or path.startswith("/api/users/"):
            return self.send_json({"ok": True, "idempotent": False, "following": "unfollow" not in path})
        if path.startswith("/api/reply/"):
            reply = self.posted_reply(path.rsplit("/", 1)[1], body)
            STATE["replies"].append(reply)
            return self.send_json({"id": reply["rest_id"], "url": reply["url"], "idempotent": False})
        if path == "/api/compose":
            return self.send_json({"id": dw.snowflake(999), "url": "https://x.com/noralind/status/1", "idempotent": False})
        return self.send_error_json(404, "not_found", f"no route for {path}")

    def do_PATCH(self):
        path = urlparse(self.path).path
        body = json.loads(self.read_body() or b"{}")
        if path == "/api/session":
            if "filter_enabled" in body:
                STATE["filter_enabled"] = bool(body["filter_enabled"])
            return self.do_GET()
        return self.do_GET()

    do_PUT = do_PATCH

    def do_DELETE(self):
        if self.moderate(urlparse(self.path).path, False):
            return
        m = re.fullmatch(r"/api/tweets/(\d+)", urlparse(self.path).path)
        if m:
            already = m.group(1) in STATE["deleted"]
            STATE["deleted"].add(m.group(1))
            return self.send_json({"ok": True, "idempotent": already})
        return self.send_json({"ok": True, "idempotent": False, "following": False})


    @staticmethod
    def engaged(tweet):
        """`tweet` as the signed-in account last left it: liked, and counting
        the replies posted to it here."""
        tweet = dict(tweet)
        if tweet["rest_id"] in STATE["likes"] and not tweet["favorited"]:
            tweet["favorited"] = True
            tweet["like_count"] += 1
        tweet["reply_count"] += sum(r["in_reply_to_tweet_id"] == tweet["rest_id"] for r in STATE["replies"])
        return tweet

    def with_posted_replies(self, thread):
        """The thread with the replies posted here placed under their parents."""
        thread = dict(thread, focal=self.engaged(thread["focal"]),
                      ancestors=[self.engaged(t) for t in thread["ancestors"]])
        replies = [self.engaged(t) for t in thread["replies"]]
        for posted in STATE["replies"]:
            ids = [thread["focal"]["rest_id"]] + [t["rest_id"] for t in replies]
            if posted["in_reply_to_tweet_id"] not in ids:
                continue
            parent = ids.index(posted["in_reply_to_tweet_id"])
            replies.insert(parent, posted)
        thread["replies"] = replies
        return thread

    def posted_reply(self, parent_id, body):
        """The signed-in account's reply to `parent_id`, with the multipart
        form's text."""
        w = self.world
        match = re.search(rb'name="text"\r\n\r\n(.*?)\r\n--', body, re.S)
        rest_id = dw.snowflake(900 + len(STATE["replies"]))
        parent_key = w.tweet_by_id(parent_id)
        parent_handle = w.by_key[parent_key]["author"]["handle"] if parent_key else None
        return dict(w.tweet("o1"), rest_id=rest_id, created_at=dw.ago(seconds=1),
                    text=(match.group(1).decode() if match else ""), media=[], quoted_tweet=None,
                    reply_count=0, retweet_count=0, like_count=0, quote_count=0, view_count=0, bookmark_count=0,
                    in_reply_to_tweet_id=parent_id, in_reply_to_handle=parent_handle,
                    url=f"https://x.com/{dw.ME}/status/{rest_id}")

    @staticmethod
    def page(tweets, cursor):
        start = int(cursor[1:]) if cursor and cursor.startswith("p") and cursor[1:].isdigit() else 0
        chunk = tweets[start:start + PAGE]
        nxt = start + PAGE
        return {"tweets": chunk, "cursor": f"p{nxt}" if nxt < len(tweets) else None}


class Server(ThreadingHTTPServer):
    """`HTTPServer.server_bind` asks DNS for the host's name, which can take
    minutes on a Mac without a resolver; nothing here needs it."""

    daemon_threads = True

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--assets", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets"))
    parser.add_argument("--lab", action="store_true",
                        help="serve the media lab (python3 make_lab.py first): a feed of test charts in every aspect ratio")
    args = parser.parse_args()
    if args.lab:
        dw.enable_lab()
        global PAGE
        PAGE = 60
    Handler.assets_dir = args.assets
    server = Server(("0.0.0.0", args.port), Handler)
    print(f"mock unrager on :{args.port} (assets {args.assets})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
