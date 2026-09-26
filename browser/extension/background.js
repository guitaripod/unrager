// Talks to `unrager serve` from the extension's own origin, which x.com's
// Content-Security-Policy (a strict connect-src allowlist with no localhost)
// can't block. Endpoint override, from this worker's devtools console:
//   chrome.storage.local.set({ endpoint: "http://100.x.y.z:7777/api/classify" })
const DEFAULT_ENDPOINT = "http://localhost:7777/api/classify";
// Generous on purpose: the first batch after an idle spell can wait on the
// server cold-loading its model, and aborting would cancel that work too.
const TIMEOUT_MS = 120000;

async function endpoint() {
  const { endpoint: configured } = await chrome.storage.local.get("endpoint");
  return configured || DEFAULT_ENDPOINT;
}

async function classify(tweets) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(await endpoint(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tweets }),
      signal: controller.signal,
    });
    if (!res.ok) throw new Error(`http ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = await res.json();
    return body.verdicts || [];
  } finally {
    clearTimeout(timer);
  }
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.type !== "classify" || !Array.isArray(msg.tweets)) return false;
  classify(msg.tweets).then(
    (verdicts) => sendResponse({ ok: true, verdicts }),
    (err) => sendResponse({ ok: false, error: String((err && err.message) || err) })
  );
  return true;
});
