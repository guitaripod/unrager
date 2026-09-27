/// Talks to `unrager serve` from the extension's own origin, which x.com's
/// Content-Security-Policy (a strict connect-src allowlist with no localhost)
/// can't block. The server address is set from the popup.
const DEFAULT_SERVER = "http://localhost:7777";
/// Generous on purpose: the first batch after an idle spell can wait on the
/// model cold-loading, and aborting would cancel that work too.
const TIMEOUT_MS = 120000;
const OVERRIDE_TIMEOUT_MS = 10000;
/// The server answers a warm-up at once and loads the model on its own time.
const WARM_TIMEOUT_MS = 5000;
const EXTENSION_VERSION = chrome.runtime.getManifest().version;
const X_HOME = ["https://x.com/home*", "https://twitter.com/home*"];

const BADGE = {
  count: "#1F6F8B",
  error: "#B45309",
  paused: "#64748B",
  update: "#6D28D9",
};

/// Set while the server answering is a different version than this
/// extension, which the badge then flags on every tab until the user
/// reloads the extension (or updates unrager).
let versionMismatch = false;
const restored = chrome.storage.session
  .get("versionMismatch")
  .then((stored) => {
    versionMismatch = !!stored.versionMismatch;
  })
  .catch(() => {});

async function serverUrl() {
  const { server } = await chrome.storage.local.get("server");
  return (server || DEFAULT_SERVER).replace(/\/+$/, "");
}

async function post(path, body, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${await serverUrl()}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    noteServerVersion(res.headers.get("x-unrager-version"));
    if (!res.ok) throw new Error(`http ${res.status}: ${(await res.text()).slice(0, 200)}`);
    return res;
  } finally {
    clearTimeout(timer);
  }
}

async function classify(tweets, cachedOnly) {
  const res = await post("/api/classify", { tweets, cached_only: !!cachedOnly }, TIMEOUT_MS);
  const body = await res.json();
  return body.verdicts || [];
}

async function override(ids, verdict) {
  await post("/api/filter/overrides", { ids, verdict }, OVERRIDE_TIMEOUT_MS);
}

/// The extension's version is the crate's without any pre-release suffix.
function sameVersion(serverVersion) {
  return String(serverVersion).split(/[-+]/)[0] === EXTENSION_VERSION;
}

async function noteServerVersion(serverVersion) {
  if (!serverVersion) return;
  await restored;
  const mismatch = !sameVersion(serverVersion);
  if (mismatch === versionMismatch) return;
  versionMismatch = mismatch;
  chrome.storage.session.set({ versionMismatch }).catch(() => {});
  const tabs = await chrome.tabs.query({}).catch(() => []);
  if (mismatch) {
    chrome.action.setTitle({ title: "unrager: open to finish updating" }).catch(() => {});
    chrome.action.setBadgeText({ text: "↑" }).catch(() => {});
    chrome.action.setBadgeBackgroundColor({ color: BADGE.update }).catch(() => {});
    for (const tab of tabs) setBadge(tab.id, {});
    return;
  }
  chrome.action.setTitle({ title: "unrager" }).catch(() => {});
  chrome.action.setBadgeText({ text: "" }).catch(() => {});
  for (const tab of tabs) {
    chrome.action.setBadgeText({ tabId: tab.id, text: "" }).catch(() => {});
    chrome.tabs.sendMessage(tab.id, { type: "republish" }).catch(() => {});
  }
}

function setBadge(tabId, { hidden, state }) {
  if (versionMismatch) {
    chrome.action.setBadgeText({ tabId, text: "↑" }).catch(() => {});
    chrome.action.setBadgeBackgroundColor({ tabId, color: BADGE.update }).catch(() => {});
    return;
  }
  const text = state === "paused" ? "off" : state === "error" ? "!" : hidden > 0 ? String(hidden) : "";
  const color = BADGE[state === "ok" ? "count" : state] || BADGE.count;
  chrome.action.setBadgeText({ tabId, text }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId, color }).catch(() => {});
}

/// Checks the server's version as the browser starts or the extension is
/// installed or updated, so the badge can flag a mismatch before any post
/// is checked.
async function checkServerVersion() {
  try {
    const res = await fetch(`${await serverUrl()}/api/health`);
    noteServerVersion(res.headers.get("x-unrager-version"));
  } catch (_) {}
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: "hide",
      title: "Hide this post",
      contexts: ["all"],
      documentUrlPatterns: X_HOME,
    });
    chrome.contextMenus.create({
      id: "keep",
      title: "Show this post",
      contexts: ["all"],
      documentUrlPatterns: X_HOME,
    });
  });
  checkServerVersion();
});

chrome.runtime.onStartup.addListener(checkServerVersion);

/// The content script knows which post was right-clicked; the menu only
/// says what to do with it.
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (!tab || tab.id === undefined) return;
  const verdict = info.menuItemId === "hide" ? "hide" : "keep";
  chrome.tabs.sendMessage(tab.id, { type: "overrule", verdict }, { frameId: info.frameId }).catch(() => {});
});

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return false;
  if (msg.type === "classify" && Array.isArray(msg.tweets)) {
    classify(msg.tweets, msg.cachedOnly).then(
      (verdicts) => sendResponse({ ok: true, verdicts }),
      (err) => sendResponse({ ok: false, error: String((err && err.message) || err) })
    );
    return true;
  }
  if (msg.type === "warm") {
    post("/api/filter/warm", {}, WARM_TIMEOUT_MS).catch(() => {});
    return false;
  }
  if (msg.type === "override" && Array.isArray(msg.ids)) {
    override(msg.ids, msg.verdict).then(
      () => sendResponse({ ok: true }),
      (err) => sendResponse({ ok: false, error: String((err && err.message) || err) })
    );
    return true;
  }
  if (msg.type === "badge" && sender.tab && sender.tab.id !== undefined) {
    restored.then(() => setBadge(sender.tab.id, msg));
  }
  return false;
});
