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
/// Reads from X through the server: a glance at a post, a page of people.
const READ_TIMEOUT_MS = 20000;
const WHOAMI_TIMEOUT_MS = 8000;
/// Posts whose glances stay cached, newest first.
const MAX_GLANCES = 300;
const GLANCE_PARTS = ["analytics", "likers", "reposters"];
const PEOPLE_PAGE = 50;
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

/// POSTs `body` and hands the response to `read`, all under one timeout, so
/// a server that sends its headers and then stalls can't hang the caller.
async function post(path, body, timeoutMs, read = (res) => res) {
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
    return await read(res);
  } finally {
    clearTimeout(timer);
  }
}

/// Reads `path` as JSON. A failure carries the server's `kind` and
/// `retry_after_secs` when it sent them, so a caller can tell "rate
/// limited, ask again later" from "this server can't do that".
async function getJson(path, timeoutMs = READ_TIMEOUT_MS, method = "GET") {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${await serverUrl()}${path}`, { method, signal: controller.signal });
    noteServerVersion(res.headers.get("x-unrager-version"));
    const text = await res.text();
    let body = null;
    try {
      body = text ? JSON.parse(text) : null;
    } catch (_) {}
    if (!res.ok) {
      const err = new Error((body && body.error) || `http ${res.status}`);
      err.status = res.status;
      err.kind = body && body.kind;
      err.retryAfter = body && body.retry_after_secs;
      throw err;
    }
    return body;
  } finally {
    clearTimeout(timer);
  }
}

/// What a content script gets back when a request fails.
function failure(err) {
  const aborted = err && err.name === "AbortError";
  return {
    ok: false,
    error: String((err && err.message) || err),
    kind: (err && err.kind) || (aborted ? "timeout" : err && err.status ? "http" : "unreachable"),
    status: (err && err.status) || null,
    retryAfter: (err && err.retryAfter) || null,
  };
}

/// What the stats on the user's own posts show of a person, kept small so a
/// page of them fits in session storage.
function slimUser(u) {
  return {
    rest_id: u.rest_id,
    handle: u.handle,
    name: u.name,
    verified: !!u.verified,
    avatar_url: u.avatar_url || "",
    followers: u.followers || 0,
    follows_me: u.follows_me,
    followed_by_me: u.followed_by_me,
  };
}

function slimPage(page) {
  return page ? { users: (page.users || []).map(slimUser), cursor: page.cursor || null } : null;
}

function slimTweet(t) {
  return {
    rest_id: t.rest_id,
    author: slimUser(t.author || {}),
    created_at: t.created_at,
    text: t.text || "",
    like_count: t.like_count || 0,
    reply_count: t.reply_count || 0,
    retweet_count: t.retweet_count || 0,
    view_count: t.view_count == null ? null : t.view_count,
    url: t.url || "",
  };
}

/// Each post's glance parts as last fetched, `{analytics|likers|reposters:
/// {at, value}}`, mirrored into session storage so the worker going to
/// sleep, another tab or a reload doesn't spend X's budget on them again.
const glances = new Map();
const glancesInFlight = new Map();
const GLANCE_KEY = (id) => `glance:${id}`;

async function cachedGlance(id) {
  if (glances.has(id)) return glances.get(id);
  const key = GLANCE_KEY(id);
  const stored = await chrome.storage.session.get(key).catch(() => ({}));
  if (glances.has(id)) return glances.get(id);
  const entry = stored[key] || {};
  glances.set(id, entry);
  return entry;
}

/// Glance writes, one after another, each with its index update, so two
/// glances landing together can't drop each other's entry or parts.
let glanceWrites = Promise.resolve();

/// Merges freshly fetched parts into the post's cached glance, as it stands
/// by the time they land, and keeps the glances of the `MAX_GLANCES` posts
/// fetched most recently.
function storeGlance(id, parts) {
  const write = glanceWrites.then(async () => {
    const entry = { ...(await cachedGlance(id)), ...parts };
    glances.set(id, entry);
    const { glanceIndex = {} } = await chrome.storage.session.get("glanceIndex");
    glanceIndex[id] = Date.now();
    const ids = Object.keys(glanceIndex).sort((a, b) => glanceIndex[b] - glanceIndex[a]);
    const dropped = ids.slice(MAX_GLANCES);
    for (const old of dropped) {
      delete glanceIndex[old];
      glances.delete(old);
    }
    await chrome.storage.session.set({ [GLANCE_KEY(id)]: entry, glanceIndex });
    if (dropped.length) await chrome.storage.session.remove(dropped.map(GLANCE_KEY));
    return entry;
  });
  glanceWrites = write.catch(() => {});
  return write.catch(() => ({ ...(glances.get(id) || {}), ...parts }));
}

/// A glance at one of the user's posts: each part asked for comes from the
/// cache while it's younger than `maxAgeMs`, and only the rest from the
/// server. A part the server held back or failed on is left out, and the
/// answer says which and when to ask again.
async function glance(id, asked, maxAgeMs) {
  const parts = asked.filter((part) => GLANCE_PARTS.includes(part));
  let entry = await cachedGlance(id);
  const now = Date.now();
  const stale = parts.filter((part) => !entry[part] || now - entry[part].at > maxAgeMs);
  let deferred = [];
  let failed = [];
  let retryAfter = null;
  if (stale.length) {
    const key = `${id}:${stale.join(",")}`;
    let pending = glancesInFlight.get(key);
    if (!pending) {
      const path = `/api/tweets/${encodeURIComponent(id)}/insights?parts=${stale.join(",")}`;
      pending = getJson(path).finally(() => glancesInFlight.delete(key));
      glancesInFlight.set(key, pending);
    }
    const body = (await pending) || {};
    deferred = body.deferred || [];
    failed = body.failed || [];
    retryAfter = body.retry_after_secs || null;
    const fetchedAt = Date.now();
    const fresh = {};
    for (const part of stale) {
      if (deferred.includes(part) || failed.includes(part)) continue;
      fresh[part] = { at: fetchedAt, value: part === "analytics" ? body.analytics || null : slimPage(body[part]) };
    }
    entry = await storeGlance(id, fresh);
  }
  const value = { deferred, failed, retryAfter };
  for (const part of parts) {
    if (entry[part]) value[part] = { at: entry[part].at, value: entry[part].value };
  }
  return value;
}

async function people(kind, id, cursor) {
  const query = `count=${PEOPLE_PAGE}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
  const path =
    kind === "reposters"
      ? `/api/tweets/${encodeURIComponent(id)}/reposters?${query}`
      : `/api/likers/${encodeURIComponent(id)}?${query}`;
  return slimPage(await getJson(path));
}

async function quotes(id, cursor) {
  const query = cursor ? `?cursor=${encodeURIComponent(cursor)}` : "";
  const page = await getJson(`/api/tweets/${encodeURIComponent(id)}/quotes${query}`);
  return { tweets: ((page && page.tweets) || []).map(slimTweet), cursor: (page && page.cursor) || null };
}

/// Answers a content script's request with `{ok, value}` or a failure.
function reply(promise, sendResponse) {
  promise.then(
    (value) => sendResponse({ ok: true, value }),
    (err) => sendResponse(failure(err))
  );
  return true;
}

async function classify(tweets, cachedOnly) {
  const body = await post("/api/classify", { tweets, cached_only: !!cachedOnly }, TIMEOUT_MS, (res) =>
    res.json()
  );
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
  if (msg.type === "whoami") return reply(getJson("/api/whoami", WHOAMI_TIMEOUT_MS), sendResponse);
  if (msg.type === "glance" && typeof msg.id === "string" && Array.isArray(msg.parts)) {
    return reply(glance(msg.id, msg.parts, msg.maxAgeMs || 0), sendResponse);
  }
  if (msg.type === "people" && typeof msg.id === "string") {
    return reply(people(msg.kind, msg.id, msg.cursor), sendResponse);
  }
  if (msg.type === "quotes" && typeof msg.id === "string") {
    return reply(quotes(msg.id, msg.cursor), sendResponse);
  }
  if (msg.type === "follow" && typeof msg.userId === "string") {
    const path = `/api/users/${encodeURIComponent(msg.userId)}/follow`;
    return reply(getJson(path, OVERRIDE_TIMEOUT_MS, "POST"), sendResponse);
  }
  if (msg.type === "badge" && sender.tab && sender.tab.id !== undefined) {
    restored.then(() => setBadge(sender.tab.id, msg));
  }
  return false;
});
