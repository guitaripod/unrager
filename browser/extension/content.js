/// Isolated-world half of the filter: takes the timeline bodies page-hook.js
/// hands over, asks the background worker for verdicts, and marks cells so
/// content.css can hide them. Fails open: any error leaves the timeline
/// exactly as X rendered it.
(() => {
  const CHUNK = 10;
  const RETRY_DELAY_MS = 20000;
  const MAX_ATTEMPTS = 3;
  /// Posts remembered with their text, so resuming or a rules change can
  /// re-check what's already on the page without waiting for X to resend it.
  const MAX_KNOWN = 400;
  /// How long a post nobody has judged yet stays out of view. A loaded model
  /// answers a page well within it; when it's still loading (or down), the
  /// post is shown anyway once this runs out.
  const HOLD_MS = 2500;
  const TIMELINE_OPS = ["HomeTimeline", "HomeLatestTimeline"];
  const origin = window.location.origin;
  const root = document.documentElement;

  const settings = { paused: false, reveal: false };
  let settingsLoaded = false;
  const known = new Map();
  const verdicts = new Map();
  const pending = new Set();
  /// Posts seen for the first time and not judged yet, by the id their cell
  /// shows, with when they're shown anyway.
  const holds = new Map();
  /// Cells to hide, by the id they show, with the rule behind it.
  const hidden = new Map();
  const warned = new Set();
  const health = { failing: false, lastError: null, shapeProblem: null };
  let generation = 0;
  let lastBadge = "";
  let marksOnPage = false;
  let contextTarget = null;

  function state() {
    if (settings.paused) return "paused";
    return health.failing ? "error" : "ok";
  }

  function stats() {
    return {
      state: state(),
      hidden: hidden.size,
      checked: verdicts.size,
      pending: pending.size,
      held: holds.size,
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
    scheduleApply();
  }

  /// The signed-in account's id, from X's `twid` cookie (`u=<id>`), so the
  /// user's own posts are never judged.
  function selfId() {
    const cookie = /(?:^|;\s*)twid=([^;]*)/.exec(document.cookie);
    if (!cookie) return null;
    let value = cookie[1];
    try {
      value = decodeURIComponent(value);
    } catch (_) {}
    const id = /^"?u=(\d+)"?$/.exec(value);
    return id ? id[1] : null;
  }

  /// Only the Home timelines are filtered. Anywhere else (a post you opened,
  /// a profile, search) you went looking, so nothing is hidden there.
  function onHome() {
    return window.location.pathname === "/home";
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

  /// A rule's leading phrase, "war" for "war, military conflict, …"; the
  /// whole rule goes in the label's tooltip.
  function shortRule(rule) {
    return rule.split(/[,:;(—]/)[0].trim() || rule;
  }

  function noteText(info) {
    if (info.overridden) return "Hidden by you";
    return info.reason ? `Hidden: ${shortRule(info.reason)}` : "Hidden by unrager";
  }

  /// The label on a hidden post while hidden posts are shown: why it was
  /// hidden, and a button to always show it. A real element rather than CSS
  /// content so the button can be clicked; X's React tree owns the cell but
  /// leaves an extra first child alone.
  function buildNote(cell) {
    const note = document.createElement("div");
    note.className = "unrager-note";
    const label = document.createElement("span");
    label.className = "unrager-reason";
    const show = document.createElement("button");
    show.type = "button";
    show.textContent = "Show this post";
    show.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const id = cellTweetId(cell);
      if (id) overrule(id, "keep");
    });
    note.append(label, show);
    cell.prepend(note);
    return note;
  }

  /// Adds, updates or removes a cell's note; returns whether it has one.
  function syncNote(cell, info) {
    const first = cell.firstElementChild;
    const existing = first && first.classList.contains("unrager-note") ? first : null;
    if (!info || !settings.reveal || settings.paused) {
      if (existing) existing.remove();
      return false;
    }
    const label = (existing || buildNote(cell)).firstElementChild;
    const text = noteText(info);
    const title = info.reason && !info.overridden ? `Hidden for: ${info.reason}` : text;
    if (label.textContent !== text) label.textContent = text;
    if (label.title !== title) label.title = title;
    return true;
  }

  /// Marks cells instead of removing them: X's React tree owns these nodes,
  /// and pulling one out from under it breaks its next unmount. Re-checking
  /// every cell lets a recycled cell showing a different post come back.
  function applyHides() {
    const now = Date.now();
    for (const [domId, until] of holds) if (until <= now) holds.delete(domId);
    root.toggleAttribute("data-unrager-away", !onHome());
    let marks = false;
    for (const cell of document.querySelectorAll('[data-testid="cellInnerDiv"]')) {
      const id = cellTweetId(cell);
      const info = id === null ? undefined : hidden.get(id);
      const mark = info ? "hidden" : id !== null && holds.has(id) ? "held" : null;
      if (mark) {
        if (cell.dataset.unrager !== mark) cell.dataset.unrager = mark;
        marks = true;
      } else if (cell.dataset.unrager) {
        delete cell.dataset.unrager;
      }
      if (syncNote(cell, info)) marks = true;
    }
    marksOnPage = marks;
  }

  let scheduled = false;
  function scheduleApply() {
    if (scheduled || (hidden.size === 0 && holds.size === 0 && !marksOnPage)) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      applyHides();
    });
  }

  function remember(tweet) {
    const before = known.get(tweet.id);
    if (before && before.own) tweet.own = true;
    known.delete(tweet.id);
    known.set(tweet.id, tweet);
    if (known.size > MAX_KNOWN) known.delete(known.keys().next().value);
  }

  /// Takes in one verdict and updates whether its post's cell is hidden.
  /// Returns 1 when that newly hid the cell.
  function apply(id, verdict) {
    verdicts.set(id, verdict);
    const t = known.get(id);
    const domId = (t && t.domId) || id;
    holds.delete(domId);
    if (verdict.verdict !== "hide" || (t && t.own)) {
      hidden.delete(domId);
      return 0;
    }
    const newly = hidden.has(domId) ? 0 : 1;
    hidden.set(domId, { reason: verdict.reason || null, overridden: !!verdict.overridden });
    return newly;
  }

  /// Takes in verdicts and returns how many posts they newly hid.
  function record(list) {
    let newlyHidden = 0;
    for (const v of list || []) newlyHidden += apply(v.id, v);
    return newlyHidden;
  }

  /// Keeps posts seen for the first time out of view until they're judged,
  /// so a post never shows up only to vanish a moment later.
  function hold(tweets) {
    const until = Date.now() + HOLD_MS;
    let added = false;
    for (const t of tweets) {
      if (t.own || verdicts.has(t.id) || holds.has(t.domId)) continue;
      holds.set(t.domId, until);
      added = true;
    }
    if (added) setTimeout(scheduleApply, HOLD_MS + 50);
  }

  /// Shows posts the model couldn't judge now rather than when their hold
  /// runs out.
  function release(tweets) {
    for (const t of tweets) holds.delete(t.domId);
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
      release(rest);
      retryLater(rest, attempt);
      scheduleApply();
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
    release(unanswered);
    retryLater(unanswered, attempt);
    scheduleApply();
    publish();
  }

  function classify(tweets) {
    const fresh = tweets.filter((t) => !t.own && !verdicts.has(t.id) && !pending.has(t.id));
    for (const t of fresh) pending.add(t.id);
    for (let i = 0; i < fresh.length; i += CHUNK) classifyChunk(fresh.slice(i, i + CHUNK));
  }

  /// The user's own call on the post a cell shows, from the page's context
  /// menu or a note's "Show this post". It applies here at once, and unrager
  /// keeps it, so every client and every later visit respects it.
  function overrule(domId, verdict) {
    const ids = new Set([domId]);
    for (const t of known.values()) if (t.domId === domId) ids.add(t.id);
    for (const id of ids) apply(id, { id, verdict, reason: null, overridden: true });
    scheduleApply();
    publish();
    sendToExtension({ type: "override", ids: [...ids], verdict }).then(
      (resp) => {
        if (!resp || !resp.ok) warn(`couldn't save your choice: ${(resp && resp.error) || "no response"}`);
      },
      (e) => warn(`couldn't save your choice: ${(e && e.message) || e}`)
    );
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
    const { tweets, problem } = unragerTimeline.extractTweets(json, selfId());
    health.shapeProblem = problem;
    if (problem) warn(`${op}: ${problem} — X may have changed its response shape`);
    const firstSeen = tweets.filter((t) => !known.has(t.id));
    for (const t of tweets) {
      remember(t);
      const v = verdicts.get(t.id);
      if (t.own) hidden.delete(t.domId);
      else if (v) apply(t.id, v);
    }
    if (!settings.paused) {
      hold(firstSeen);
      classify(tweets);
    }
    scheduleApply();
    publish();
  }

  /// The rules changed: every verdict on this page was made under the old
  /// ones, so check the remembered posts again. Hidden posts stay hidden
  /// until their new verdict comes in, rather than all coming back while the
  /// model works through them.
  function reset() {
    generation += 1;
    verdicts.clear();
    pending.clear();
    holds.clear();
    health.failing = false;
    if (!settings.paused) classify([...known.values()]);
    scheduleApply();
    publish();
  }

  const ready = chrome.storage.local.get(["paused", "reveal"]).then(
    (stored) => {
      settings.paused = !!stored.paused;
      settings.reveal = !!stored.reveal;
      settingsLoaded = true;
      applySettings();
    },
    () => {
      settingsLoaded = true;
    }
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
    if (!msg) return false;
    if (msg.type === "stats") sendResponse(stats());
    if (msg.type === "overrule" && contextTarget) overrule(contextTarget, msg.verdict);
    if (msg.type === "republish") {
      lastBadge = "";
      publish();
    }
    return false;
  });

  /// Remembers which post a right-click landed on, for the "Hide this post"
  /// and "Show this post" menu items.
  document.addEventListener(
    "contextmenu",
    (e) => {
      const cell = e.target instanceof Element ? e.target.closest('[data-testid="cellInnerDiv"]') : null;
      contextTarget = cell ? cellTweetId(cell) : null;
    },
    true
  );

  /// Timeline bodies arrive synchronously, while X is still handling the
  /// response, so first-seen posts are held before React can paint them.
  for (const op of TIMELINE_OPS) {
    document.addEventListener(`unrager:${op}`, (e) => {
      const body = e.detail;
      if (typeof body !== "string") return;
      if (settingsLoaded) handleTimeline(op, body);
      else ready.then(() => handleTimeline(op, body));
    });
  }

  new MutationObserver(scheduleApply).observe(root, { childList: true, subtree: true });

  document.addEventListener("DOMContentLoaded", publish, { once: true });
  console.info("[unrager] active");
})();
