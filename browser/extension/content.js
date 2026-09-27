/// Isolated-world half of the filter: takes the timeline bodies page-hook.js
/// forwards, asks the background worker for verdicts, and marks HIDE cells so
/// content.css can hide them. Fails open: any error leaves the timeline
/// exactly as X rendered it.
(() => {
  const CHUNK = 10;
  const RETRY_DELAY_MS = 20000;
  const MAX_ATTEMPTS = 3;
  /// Posts remembered with their text, so resuming or a rules change can
  /// re-check what's already on the page without waiting for X to resend it.
  const MAX_KNOWN = 400;
  const origin = window.location.origin;
  const root = document.documentElement;

  const settings = { paused: false, reveal: false };
  const known = new Map();
  const verdicts = new Map();
  const pending = new Set();
  const hiddenDomIds = new Set();
  const warned = new Set();
  const health = { failing: false, lastError: null, shapeProblem: null };
  let generation = 0;
  let lastBadge = "";

  function state() {
    if (settings.paused) return "paused";
    return health.failing ? "error" : "ok";
  }

  function stats() {
    return {
      state: state(),
      hidden: hiddenDomIds.size,
      checked: verdicts.size,
      pending: pending.size,
      lastError: health.lastError,
      shapeProblem: health.shapeProblem,
    };
  }

  /// Chrome invalidates this script's extension context when the extension
  /// is reloaded; the page lives on, so every call back into it must survive.
  function sendToExtension(message) {
    try {
      return chrome.runtime.sendMessage(message);
    } catch (e) {
      return Promise.reject(e);
    }
  }

  function publish() {
    const s = stats();
    window.postMessage({ source: "unrager-content", type: "status", status: { loaded: true, ...s } }, origin);
    const badge = `${s.state}:${s.hidden}`;
    if (badge === lastBadge) return;
    lastBadge = badge;
    sendToExtension({ type: "badge", state: s.state, hidden: s.hidden }).catch(() => {});
  }

  function warn(message) {
    if (warned.has(message)) return;
    warned.add(message);
    console.warn("[unrager]", message);
  }

  function applySettings() {
    root.toggleAttribute("data-unrager-paused", settings.paused);
    root.toggleAttribute("data-unrager-reveal", settings.reveal);
  }

  /// The post a cell shows: its first permalink wrapping a <time>. A quoted
  /// post's own timestamp link comes later in the cell, so it never wins.
  function cellTweetId(cell) {
    for (const a of cell.querySelectorAll('a[href*="/status/"]')) {
      if (!a.querySelector("time")) continue;
      const m = /\/status\/(\d+)/.exec(a.getAttribute("href") || "");
      if (m) return m[1];
    }
    return null;
  }

  /// Marks cells instead of removing them: X's React tree owns these nodes,
  /// and pulling one out from under it breaks its next unmount. Re-checking
  /// every cell lets a recycled cell showing a different post come back.
  function applyHides() {
    for (const cell of document.querySelectorAll('[data-testid="cellInnerDiv"]')) {
      const id = cellTweetId(cell);
      if (id !== null && hiddenDomIds.has(id)) {
        if (cell.dataset.unrager !== "hidden") cell.dataset.unrager = "hidden";
      } else if (cell.dataset.unrager) {
        delete cell.dataset.unrager;
      }
    }
  }

  function clearMarks() {
    for (const cell of document.querySelectorAll('[data-unrager="hidden"]')) delete cell.dataset.unrager;
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

  function remember(tweet) {
    known.delete(tweet.id);
    known.set(tweet.id, tweet);
    if (known.size > MAX_KNOWN) known.delete(known.keys().next().value);
  }

  function markHidden(tweetId) {
    const t = known.get(tweetId);
    const domId = (t && t.domId) || tweetId;
    if (hiddenDomIds.has(domId)) return 0;
    hiddenDomIds.add(domId);
    return 1;
  }

  /// The server leaves out posts its model never answered for (cold start,
  /// restart); those stay visible and are asked about again a little later.
  function retryLater(chunk, attempt) {
    if (!chunk.length || attempt >= MAX_ATTEMPTS) return;
    const gen = generation;
    for (const t of chunk) pending.add(t.id);
    setTimeout(() => {
      if (gen !== generation) return;
      if (settings.paused) {
        for (const t of chunk) pending.delete(t.id);
        publish();
        return;
      }
      classifyChunk(chunk, attempt + 1);
    }, RETRY_DELAY_MS);
  }

  /// Asks the server about `tweets` through the background worker. With
  /// `cachedOnly`, only the posts it has already judged come back, and at
  /// once, even while the model is still loading.
  async function ask(tweets, cachedOnly) {
    try {
      return await sendToExtension({
        type: "classify",
        cachedOnly,
        tweets: tweets.map(({ id, text }) => ({ id, text })),
      });
    } catch (e) {
      return { ok: false, error: String((e && e.message) || e) };
    }
  }

  /// Takes in verdicts and returns how many posts they newly hid.
  function record(list) {
    let newlyHidden = 0;
    for (const v of list || []) {
      verdicts.set(v.id, v.verdict);
      if (v.verdict === "hide") newlyHidden += markHidden(v.id);
    }
    return newlyHidden;
  }

  /// Hides what the server has already judged straight away, then waits on
  /// the model for the rest, which can take a minute after an idle spell. A
  /// reply from before the last rules change is dropped outright: reset()
  /// already queued those posts again under the new rules.
  async function classifyChunk(chunk, attempt = 1) {
    const gen = generation;
    let hid = 0;
    if (attempt === 1) {
      const cached = await ask(chunk, true);
      if (gen !== generation) return;
      if (cached && cached.ok && cached.verdicts.length) {
        hid += record(cached.verdicts);
        for (const t of chunk) if (verdicts.has(t.id)) pending.delete(t.id);
        scheduleApply();
        publish();
      }
    }
    const rest = chunk.filter((t) => !verdicts.has(t.id));
    if (!rest.length) {
      health.failing = false;
      console.debug(`[unrager] checked ${chunk.length}/${chunk.length} from cache, hid ${hid}`);
      publish();
      return;
    }
    const resp = await ask(rest, false);
    if (gen !== generation) return;
    for (const t of rest) pending.delete(t.id);
    if (!resp || !resp.ok) {
      health.failing = true;
      health.lastError = (resp && resp.error) || "no response";
      warn(`couldn't check posts, leaving them visible: ${health.lastError}`);
      retryLater(rest, attempt);
      publish();
      return;
    }
    hid += record(resp.verdicts);
    const unanswered = rest.filter((t) => !verdicts.has(t.id));
    health.failing = unanswered.length === rest.length;
    if (health.failing) {
      health.lastError = "the model didn't answer";
      warn("the model didn't answer; leaving these posts visible");
    }
    console.debug(`[unrager] checked ${chunk.length - unanswered.length}/${chunk.length}, hid ${hid}`);
    retryLater(unanswered, attempt);
    scheduleApply();
    publish();
  }

  function classify(tweets) {
    const fresh = tweets.filter((t) => !verdicts.has(t.id) && !pending.has(t.id));
    for (const t of fresh) pending.add(t.id);
    for (let i = 0; i < fresh.length; i += CHUNK) classifyChunk(fresh.slice(i, i + CHUNK));
  }

  function handleTimeline(op, body) {
    let json;
    try {
      json = JSON.parse(body);
    } catch (_) {
      health.shapeProblem = "response was not JSON";
      warn(`${op}: response was not JSON`);
      publish();
      return;
    }
    const { tweets, problem } = unragerTimeline.extractTweets(json);
    health.shapeProblem = problem;
    if (problem) warn(`${op}: ${problem} — X may have changed its response shape`);
    for (const t of tweets) {
      remember(t);
      if (verdicts.get(t.id) === "hide") markHidden(t.id);
    }
    scheduleApply();
    if (!settings.paused) classify(tweets);
    publish();
  }

  /// The rules changed: every verdict on this page was made under the old
  /// ones, so forget them all and check the remembered posts again.
  function reset() {
    generation += 1;
    verdicts.clear();
    pending.clear();
    hiddenDomIds.clear();
    health.failing = false;
    clearMarks();
    if (!settings.paused) classify([...known.values()]);
    publish();
  }

  const ready = chrome.storage.local.get(["paused", "reveal"]).then(
    (stored) => {
      settings.paused = !!stored.paused;
      settings.reveal = !!stored.reveal;
      applySettings();
    },
    () => {}
  );

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    if (changes.reveal) {
      settings.reveal = !!changes.reveal.newValue;
      applySettings();
    }
    if (changes.paused) {
      settings.paused = !!changes.paused.newValue;
      applySettings();
      if (!settings.paused) classify([...known.values()]);
      publish();
    }
    if (changes.rulesChangedAt) reset();
  });

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg && msg.type === "stats") sendResponse(stats());
    return false;
  });

  window.addEventListener("message", (e) => {
    if (e.source !== window || e.origin !== origin) return;
    const d = e.data;
    if (!d || d.source !== "unrager-page" || d.type !== "timeline" || typeof d.body !== "string") return;
    ready.then(() => handleTimeline(d.op, d.body));
  });

  new MutationObserver(scheduleApply).observe(root, { childList: true, subtree: true });

  document.addEventListener("DOMContentLoaded", publish, { once: true });
  console.info("[unrager] active");
})();
