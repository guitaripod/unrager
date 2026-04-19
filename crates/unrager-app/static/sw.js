// unrager service worker
// - precaches the app shell (HTML + WASM) so the SPA loads offline
// - never caches /api/* (live data) or /api/sse/* (streaming)
// - stale-while-revalidate for the WASM bundle

const SHELL_CACHE = "unrager-shell-v1";
const SHELL = [
  "/",
  "/manifest.webmanifest",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE).then((cache) => cache.addAll(SHELL)).catch(() => {}),
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(
        names
          .filter((n) => n.startsWith("unrager-shell-") && n !== SHELL_CACHE)
          .map((n) => caches.delete(n)),
      ),
    ),
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // Never intercept non-GET, SSE, or explicit API writes
  if (event.request.method !== "GET") return;
  if (url.pathname.startsWith("/api/sse/")) return;
  if (url.pathname.startsWith("/api/engage/")) return;
  if (url.pathname === "/api/compose") return;
  if (url.pathname.startsWith("/api/reply/")) return;
  if (url.pathname === "/api/seen") return;

  // For API GETs, network-first with no cache fallback (data freshness > offline)
  if (url.pathname.startsWith("/api/")) {
    event.respondWith(
      fetch(event.request).catch(() => new Response(
        JSON.stringify({ error: "offline", kind: "sw_offline" }),
        { status: 503, headers: { "content-type": "application/json" } },
      )),
    );
    return;
  }

  // Shell + WASM + static assets: stale-while-revalidate
  event.respondWith(
    caches.open(SHELL_CACHE).then(async (cache) => {
      const cached = await cache.match(event.request);
      const network = fetch(event.request)
        .then((resp) => {
          if (resp && resp.ok && resp.type === "basic") {
            cache.put(event.request, resp.clone()).catch(() => {});
          }
          return resp;
        })
        .catch(() => cached);
      return cached || network;
    }),
  );
});
