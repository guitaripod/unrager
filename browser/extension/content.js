// Isolated-world content script: receives timeline bodies from page-hook.js,
// asks the background worker for verdicts, and hides HIDE tweets. Fails open:
// any error leaves the timeline exactly as X rendered it.
(() => {
  const CHUNK = 10;
  const RETRY_DELAY_MS = 20000;
  const MAX_ATTEMPTS = 3;
  const origin = window.location.origin;

  const verdicts = new Map();
  const domIdFor = new Map();
  const pending = new Set();
  const hiddenDomIds = new Set();
  const stats = { batches: 0, classified: 0, hidden: 0, errors: 0, lastError: null };
  const warned = new Set();

  function publish() {
    window.postMessage(
      {
        source: "unrager-content",
        type: "status",
        status: { loaded: true, ...stats, pending: pending.size, hiddenIds: hiddenDomIds.size },
      },
      origin
    );
  }

  function warn(message) {
    stats.lastError = message;
    if (warned.has(message)) return;
    warned.add(message);
    console.warn("[unrager]", message);
  }

  /// The tweet a cell shows: its first permalink wrapping a <time>. A quoted
  /// tweet's own timestamp link comes later in the cell, so it never wins.
  function cellTweetId(cell) {
    for (const a of cell.querySelectorAll('a[href*="/status/"]')) {
      if (!a.querySelector("time")) continue;
      const m = /\/status\/(\d+)/.exec(a.getAttribute("href") || "");
      if (m) return m[1];
    }
    return null;
  }

  /// Hides via display:none rather than removing the node: X's React tree
  /// owns these elements, and pulling one out from under it breaks its next
  /// unmount. The marker lets a recycled cell showing a different tweet come back.
  function applyHides() {
    for (const cell of document.querySelectorAll('[data-testid="cellInnerDiv"]')) {
      const id = cellTweetId(cell);
      const hide = id !== null && hiddenDomIds.has(id);
      if (hide && cell.dataset.unragerHidden !== "1") {
        cell.style.setProperty("display", "none", "important");
        cell.dataset.unragerHidden = "1";
      } else if (!hide && cell.dataset.unragerHidden === "1") {
        cell.style.removeProperty("display");
        delete cell.dataset.unragerHidden;
      }
    }
  }

  let scheduled = false;
  function scheduleApply() {
    if (scheduled || hiddenDomIds.size === 0) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      applyHides();
    });
  }

  function markHidden(tweetId) {
    const domId = domIdFor.get(tweetId) || tweetId;
    if (hiddenDomIds.has(domId)) return 0;
    hiddenDomIds.add(domId);
    return 1;
  }

  /// The server leaves out tweets its model never answered for (cold start,
  /// restart); those stay visible and are asked about again a little later.
  function retryLater(op, chunk, attempt) {
    if (!chunk.length || attempt >= MAX_ATTEMPTS) return;
    for (const t of chunk) pending.add(t.id);
    setTimeout(() => classifyChunk(op, chunk, attempt + 1), RETRY_DELAY_MS);
  }

  async function classifyChunk(op, chunk, attempt = 1) {
    let resp;
    try {
      resp = await chrome.runtime.sendMessage({
        type: "classify",
        tweets: chunk.map(({ id, text }) => ({ id, text })),
      });
    } catch (e) {
      resp = { ok: false, error: String((e && e.message) || e) };
    }
    for (const t of chunk) pending.delete(t.id);
    if (!resp || !resp.ok) {
      stats.errors += 1;
      warn(`classify failed, leaving these tweets visible: ${(resp && resp.error) || "no response"}`);
      retryLater(op, chunk, attempt);
      publish();
      return;
    }
    let newlyHidden = 0;
    for (const v of resp.verdicts || []) {
      verdicts.set(v.id, v.verdict);
      stats.classified += 1;
      if (v.verdict === "hide") newlyHidden += markHidden(v.id);
    }
    const unanswered = chunk.filter((t) => !verdicts.has(t.id));
    stats.batches += 1;
    stats.hidden += newlyHidden;
    console.info(
      `[unrager] ${op}: classified ${chunk.length - unanswered.length}/${chunk.length}, hid ${newlyHidden}`
    );
    retryLater(op, unanswered, attempt);
    scheduleApply();
    publish();
  }

  function handleTimeline(op, body) {
    let json;
    try {
      json = JSON.parse(body);
    } catch (_) {
      warn(`${op}: response was not JSON`);
      return;
    }
    const { tweets, problem } = unragerTimeline.extractTweets(json);
    if (problem) warn(`${op}: ${problem} — X may have changed its response shape`);
    const unknown = [];
    for (const t of tweets) {
      domIdFor.set(t.id, t.domId);
      const known = verdicts.get(t.id);
      if (known === "hide") markHidden(t.id);
      else if (known === undefined && !pending.has(t.id)) unknown.push(t);
    }
    scheduleApply();
    for (const t of unknown) pending.add(t.id);
    for (let i = 0; i < unknown.length; i += CHUNK) classifyChunk(op, unknown.slice(i, i + CHUNK));
    publish();
  }

  window.addEventListener("message", (e) => {
    if (e.source !== window || e.origin !== origin) return;
    const d = e.data;
    if (!d || d.source !== "unrager-page" || d.type !== "timeline" || typeof d.body !== "string") return;
    handleTimeline(d.op, d.body);
  });

  new MutationObserver(scheduleApply).observe(document.documentElement, {
    childList: true,
    subtree: true,
  });

  document.addEventListener("DOMContentLoaded", publish, { once: true });
  console.info("[unrager] active");
})();
