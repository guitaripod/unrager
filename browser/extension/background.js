/// Talks to `unrager serve` from the extension's own origin, which x.com's
/// Content-Security-Policy (a strict connect-src allowlist with no localhost)
/// can't block. The server address is set from the popup.
const DEFAULT_SERVER = "http://localhost:7777";
/// Generous on purpose: the first batch after an idle spell can wait on the
/// model cold-loading, and aborting would cancel that work too.
const TIMEOUT_MS = 120000;

const BADGE = {
  count: "#1F6F8B",
  error: "#B45309",
  paused: "#64748B",
};

async function serverUrl() {
  const { server } = await chrome.storage.local.get("server");
  return (server || DEFAULT_SERVER).replace(/\/+$/, "");
}

async function classify(tweets, cachedOnly) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${await serverUrl()}/api/classify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tweets, cached_only: !!cachedOnly }),
      signal: controller.signal,
    });
    if (!res.ok) throw new Error(`http ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = await res.json();
    return body.verdicts || [];
  } finally {
    clearTimeout(timer);
  }
}

function setBadge(tabId, { hidden, state }) {
  const text = state === "paused" ? "off" : state === "error" ? "!" : hidden > 0 ? String(hidden) : "";
  const color = BADGE[state === "ok" ? "count" : state] || BADGE.count;
  chrome.action.setBadgeText({ tabId, text }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId, color }).catch(() => {});
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return false;
  if (msg.type === "classify" && Array.isArray(msg.tweets)) {
    classify(msg.tweets, msg.cachedOnly).then(
      (verdicts) => sendResponse({ ok: true, verdicts }),
      (err) => sendResponse({ ok: false, error: String((err && err.message) || err) })
    );
    return true;
  }
  if (msg.type === "badge" && sender.tab && sender.tab.id !== undefined) {
    setBadge(sender.tab.id, msg);
  }
  return false;
});
