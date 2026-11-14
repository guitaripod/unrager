"""Stands in for a full `unrager serve` while the pictures are shot: the
routes the browser extension's stats on your own posts use, answered from
`world.World` (made-up analytics, likers, reposters and quotes), plus the
filter routes the rest of the extension calls so nothing on the page waits.
"""

from __future__ import annotations

import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from world import ME, ME_NAME, World

VERSION = "0.32.0"


def make_handler(world: World, self_id: str):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            return

        def answer(self, status: int, body) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("x-unrager-version", VERSION)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            path = urlparse(self.path).path
            length = int(self.headers.get("content-length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
            if path == "/api/classify":
                return self.answer(200, {"verdicts": [{"id": t["id"], "verdict": "keep"} for t in body.get("tweets", [])]})
            if path.startswith("/api/users/") and path.endswith("/follow"):
                return self.answer(200, {"ok": True, "following": True})
            return self.answer(202, {"ok": True})

        def do_GET(self):
            url = urlparse(self.path)
            path = url.path
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            if path == "/api/health":
                return self.answer(200, {"ok": True, "name": "unrager", "version": VERSION, "filter_only": False,
                                         "build": {"profile": "release", "features": {"server": True, "tui": True}}})
            if path == "/api/whoami":
                return self.answer(200, {"handle": ME, "name": ME_NAME, "rest_id": self_id})
            if path == "/api/filter/status":
                return self.answer(200, {"state": "ready", "model": "unrager-4b", "backend": "ollama", "host": "http://localhost:11434"})
            m = re.match(r"^/api/tweets/(\d+)/(insights|reposters|quotes)$", path)
            likers = re.match(r"^/api/likers/(\d+)$", path)
            post_id = (m and m.group(1)) or (likers and likers.group(1))
            post = world.by_id.get(post_id) if post_id else None
            if (m or likers) and not post:
                return self.answer(404, {"error": "no such post", "kind": "not_found"})
            if likers:
                return self.answer(200, world.page(post["liker_handles"], q.get("cursor"), int(q.get("count", 50))))
            if m and m.group(2) == "reposters":
                return self.answer(200, world.page(post["reposter_handles"], q.get("cursor"), int(q.get("count", 50))))
            if m and m.group(2) == "quotes":
                return self.answer(200, {"tweets": world.quote_tweets(post), "cursor": None})
            if m and m.group(2) == "insights":
                parts = [p for p in (q.get("parts") or "analytics,likers,reposters").split(",") if p]
                count = int(q.get("count", 20))
                out = {}
                if "analytics" in parts:
                    out["analytics"] = world.analytics(post)
                if "likers" in parts:
                    out["likers"] = world.page(post["liker_handles"], None, count)
                if "reposters" in parts:
                    out["reposters"] = world.page(post["reposter_handles"], None, count)
                return self.answer(200, out)
            return self.answer(404, {"error": "not here", "kind": "not_found"})

    return Handler


def start(world: World, self_id: str, port: int = 0) -> tuple[ThreadingHTTPServer, int]:
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(world, self_id))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]
