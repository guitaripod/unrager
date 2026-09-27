/// Isolated-world half of the filter: takes the timeline bodies page-hook.js
/// hands over, asks the background worker for verdicts, and marks cells so
/// content.css can hide them. Fails open: any error leaves the timeline
/// exactly as X rendered it.
(() => {
  const CHUNK = 10;
  /// The top of a timeline goes to the model on its own, so what's on screen
  /// first is judged, and shown, first.
  const FIRST_CHUNK = 5;
  const RETRY_DELAY_MS = 20000;
  const MAX_ATTEMPTS = 3;
  /// Posts remembered with their text, so resuming or a rules change can
  /// re-check what's already on the page without waiting for X to resend it.
  const MAX_KNOWN = 400;
  /// How long a post nobody has judged yet stays out of view. A loaded model
  /// answers a page well within it; when it's still loading (or down), the
  /// post is shown anyway once this runs out.
  const HOLD_MS = 2500;
  /// How long a post already in view takes to fold away when a late verdict
  /// hides it, and a held one to fade in.
  const FOLD_MS = 220;
  const ENTER_MS = 200;
  /// Once the timeline has waited this long, its loading edge shows the
  /// spinner at once as it moves down, rather than fading it in again.
  const EDGE_STEADY_MS = 450;
  /// How long, and for how many calm frames, the post in view is held in
  /// place after posts above it come or go: X moves its cells a frame or two
  /// after one changes size.
  const SETTLE_MS = 1000;
  const SETTLE_FRAMES = 6;
  /// A tab asks for the model to be loaded at most this often; the server
  /// skips one that just answered anyway.
  const WARM_EVERY_MS = 30000;
  const MAX_ON_SCREEN = 1000;
  /// How long the Not interested button waits for X's menu to open or close.
  const MENU_WAIT_MS = 1500;
  const MENU = '#layers [role="menu"]';
  const FROWN =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="8.75"/>' +
    '<path d="M8.6 16.3c.85-1.2 2-1.8 3.4-1.8s2.55.6 3.4 1.8"/>' +
    '<circle class="unrager-ni-eye" cx="9.2" cy="10.1" r="1.2"/><circle class="unrager-ni-eye" cx="14.8" cy="10.1" r="1.2"/></svg>';
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
  /// Posts X's own menu offers "Not interested in this post" for, by the id
  /// their cell shows, with the menu item's label.
  const offers = new Map();
  /// Conversations X shows as one block, a post with the replies under it:
  /// each block's posts by the id their cell shows, with their place in it.
  const threads = new Map();
  /// Replies kept out of view while the post above them waits for its
  /// verdict, with when that post is shown anyway.
  const threadHolds = new Map();
  /// Posts that have been on screen, by the id their cell shows. They're
  /// never held back again: nothing already read disappears to wait.
  const onScreen = new Set();
  /// Cells without a post (Who to follow, X's own spinner) that have been
  /// on screen.
  const cellsOnScreen = new WeakSet();
  /// Whether each cell showed its post after the last pass, to tell which
  /// ones changed.
  const lastShown = new WeakMap();
  /// Cells folding out of view, with their animation.
  const folding = new Map();
  const warned = new Set();
  const health = { failing: false, lastError: null, shapeProblem: null };
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let generation = 0;
  let lastBadge = "";
  let marksOnPage = false;
  let contextTarget = null;
  /// When the timeline's loading edge appeared, or 0 while there's none.
  let waitingSince = 0;
  /// The post kept in place while posts above it come and go.
  let anchor = null;
  let lastInput = 0;
  let lastWarm = 0;

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
      held: holds.size + threadHolds.size,
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
    if (info.inherited) return "Hidden: reply to a hidden post";
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
    const title = info.inherited
      ? "Hidden because the post it replies to is hidden"
      : info.reason && !info.overridden
        ? `Hidden for: ${info.reason}`
        : text;
    if (label.textContent !== text) label.textContent = text;
    if (label.title !== title) label.title = title;
    return true;
  }

  /// Whether For you is the tab showing: X's menu offers "Not interested"
  /// only there, and the same post can turn up under Following too.
  function onForYou() {
    const tabs = document.querySelectorAll('[data-testid="primaryColumn"] [role="tablist"] [role="tab"]');
    return tabs.length === 0 || tabs[0].getAttribute("aria-selected") === "true";
  }

  /// Polls once a frame until `find` returns something, or gives up with null.
  function waitFor(find, ms) {
    return new Promise((resolve) => {
      const until = Date.now() + ms;
      const poll = () => {
        const found = find();
        if (found || Date.now() > until) resolve(found || null);
        else requestAnimationFrame(poll);
      };
      poll();
    });
  }

  function closeMenu(dropdown) {
    const layer = dropdown && dropdown.closest('[role="group"]');
    const mask = layer && layer.firstElementChild && layer.firstElementChild.firstElementChild;
    if (mask && !mask.contains(dropdown)) mask.click();
    else document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", keyCode: 27, bubbles: true }));
  }

  /// X's own "Not interested in this post", minus the menu: opens the post's
  /// "More" menu out of sight and picks the item X labelled `prompt`, so X
  /// sends its feedback and swaps in its usual confirmation, Undo included.
  async function pickNotInterested(article, prompt) {
    const caret = article.querySelector('[data-testid="caret"]');
    if (!caret) return false;
    root.setAttribute("data-unrager-quiet-menu", "");
    let picked = false;
    try {
      caret.click();
      const dropdown = await waitFor(() => document.querySelector(`${MENU} [data-testid="Dropdown"]`), MENU_WAIT_MS);
      const items = dropdown ? [...dropdown.querySelectorAll('[role="menuitem"]')] : [];
      const item = items.find((el) => el.textContent.trim() === prompt);
      if (item) {
        item.click();
        picked = true;
      } else if (dropdown) {
        closeMenu(dropdown);
      }
      await waitFor(() => !document.querySelector(MENU), MENU_WAIT_MS);
    } finally {
      root.removeAttribute("data-unrager-quiet-menu");
    }
    return picked;
  }

  /// Keeps a press on the button from reaching the post, which X opens on
  /// any click inside it.
  function swallow(e) {
    e.stopPropagation();
  }

  async function onNotInterested(e) {
    e.preventDefault();
    e.stopPropagation();
    const button = e.currentTarget;
    const cell = button.closest('[data-testid="cellInnerDiv"]');
    const article = button.closest('article[data-testid="tweet"]');
    const id = cell ? cellTweetId(cell) : null;
    const prompt = id === null ? null : offers.get(id);
    if (!article || !prompt || button.dataset.state === "busy") return;
    button.dataset.state = "busy";
    if (await pickNotInterested(article, prompt)) {
      delete button.dataset.state;
      return;
    }
    button.dataset.state = "failed";
    button.title = "X's menu didn't offer this for this post";
    setTimeout(() => {
      delete button.dataset.state;
      button.title = prompt;
    }, 2000);
  }

  /// Where the button goes in the post's header: just before the Grok
  /// button's branch of the row it shares with "More", or before "More"
  /// itself where there's no Grok button.
  function slotFor(article, caret) {
    const grok = article.querySelector('[aria-label*="Grok"]:is(button, [role="button"])');
    if (grok) {
      let branch = grok;
      while (branch.parentElement && branch.parentElement !== article && !branch.parentElement.contains(caret)) {
        branch = branch.parentElement;
      }
      const row = branch.parentElement;
      if (row && row !== article && row.contains(caret) && !row.querySelector('[data-testid="tweetText"]')) {
        return { row, before: branch, gap: caret.getBoundingClientRect().left - grok.getBoundingClientRect().right };
      }
    }
    let branch = caret;
    while (branch.parentElement && branch.parentElement !== article && branch.parentElement.childElementCount === 1) {
      branch = branch.parentElement;
    }
    return branch.parentElement && branch.parentElement !== article ? { row: branch.parentElement, before: branch, gap: 0 } : null;
  }

  /// The one-click Not interested button, sized and coloured from the post's
  /// own "More" button so it sits in X's header like one of X's.
  function buildButton(caret, prompt, gap) {
    const wrap = document.createElement("div");
    wrap.className = "unrager-ni-wrap";
    const button = document.createElement("button");
    button.type = "button";
    button.className = "unrager-ni";
    button.title = prompt;
    button.setAttribute("aria-label", prompt);
    button.innerHTML = FROWN;
    const box = caret.getBoundingClientRect();
    if (box.width && box.height) {
      button.style.width = `${box.width}px`;
      button.style.height = `${box.height}px`;
    }
    const icon = caret.querySelector("svg");
    if (icon) button.style.color = getComputedStyle(icon).color;
    if (gap > 0) wrap.style.marginRight = `${gap}px`;
    button.addEventListener("click", onNotInterested);
    for (const type of ["pointerdown", "pointerup", "mousedown", "mouseup"]) button.addEventListener(type, swallow);
    wrap.append(button);
    return wrap;
  }

  /// Adds the button to a post X offers "Not interested" for, and takes it
  /// off a cell X has since reused for a post it doesn't. A cell out of view
  /// gets it once it shows, when X's header can be measured to match.
  function syncButton(cell, id, show) {
    const article = cell.querySelector('article[data-testid="tweet"]');
    if (!article) return;
    const existing = article.querySelector(".unrager-ni-wrap");
    const prompt = show && id !== null ? offers.get(id) : undefined;
    if (!prompt) {
      if (existing) existing.remove();
      return;
    }
    if (existing) return;
    const caret = article.querySelector('[data-testid="caret"]');
    const slot = caret && slotFor(article, caret);
    if (slot) slot.row.insertBefore(buildButton(caret, prompt, slot.gap), slot.before);
  }

  /// The cells of the timeline on screen, top to bottom. A dialog X lays
  /// over it (a photo with its replies) has cells of its own, left alone.
  function timelineCells() {
    const cell = '[data-testid="cellInnerDiv"]';
    const column = document.querySelector('[data-testid="primaryColumn"]');
    const inColumn = column ? column.querySelectorAll(cell) : [];
    return [...(inColumn.length ? inColumn : document.querySelectorAll(cell))];
  }

  function wasOnScreen(cell, id) {
    return id === null ? cellsOnScreen.has(cell) : onScreen.has(id);
  }

  function noteOnScreen(cell, id) {
    if (id === null) {
      cellsOnScreen.add(cell);
      return;
    }
    if (onScreen.has(id)) return;
    onScreen.add(id);
    if (onScreen.size > MAX_ON_SCREEN) onScreen.delete(onScreen.values().next().value);
  }

  /// What each cell should show, top to bottom. A new post shows once it's
  /// judged and every new post above it has shown or been hidden, so the
  /// timeline fills in from the top and nothing lands above a post already
  /// on screen; the first one still waiting is the loading edge. A post
  /// that's been on screen is never held again.
  function planCells(cells, filtering) {
    let edge = -1;
    const rows = cells.map((cell, i) => {
      const id = cellTweetId(cell);
      const info = id === null ? undefined : hidden.get(id);
      const waiting = id !== null && (holds.has(id) || threadHolds.has(id));
      let mark = null;
      if (info) mark = "hidden";
      else if (!wasOnScreen(cell, id) && (waiting || (filtering && edge >= 0))) mark = "held";
      if (filtering && mark === "held" && edge < 0) edge = i;
      return { cell, id, info, mark, shows: !filtering || mark === null };
    });
    return { rows, edge };
  }

  function hasNote(cell) {
    const first = cell.firstElementChild;
    return !!first && first.classList.contains("unrager-note");
  }

  /// The first cell in view when it reaches above the top of the window, so
  /// posts before it are out of sight above; null when the timeline's top
  /// is in view, where posts arriving above should push it down.
  function firstInView(rows) {
    for (const { cell } of rows) {
      const box = cell.getBoundingClientRect();
      if (box.height > 0 && box.bottom > 0) {
        return box.top <= 0 ? { cell, top: box.top, since: performance.now(), until: 0, calm: 0, running: false } : null;
      }
    }
    return null;
  }

  /// Reads, before anything is written, which cells change and where: a
  /// post in view that a late verdict hides folds away, and returns whether
  /// posts coming or going above the one in view need making up for.
  function measure(rows, home, filtering) {
    const motion = home && !reducedMotion.matches;
    let first = -1;
    rows.forEach((row, i) => {
      const was = lastShown.get(row.cell);
      const noted = hasNote(row.cell) !== (!!row.info && settings.reveal && !settings.paused);
      row.changed = was !== undefined && (was !== row.shows || noted);
      row.enter = motion && row.changed && row.shows && was === false;
      if (row.changed && first < 0) first = i;
    });
    if (first < 0 || !home) return false;
    for (const row of rows) {
      if (!row.changed || row.shows || row.mark !== "hidden" || !filtering || !motion || folding.has(row.cell)) continue;
      const box = row.cell.getBoundingClientRect();
      if (box.height > 0 && box.bottom > 0 && box.top < window.innerHeight) {
        row.fold = true;
        row.height = box.height;
      }
    }
    const kept =
      anchor && anchor.running && anchor.cell.isConnected && rows.some((r) => r.cell === anchor.cell)
        ? anchor
        : firstInView(rows);
    if (!kept || rows.findIndex((r) => r.cell === kept.cell) <= first) return false;
    anchor = kept;
    return true;
  }

  /// Holds the post in view where the reader had it while posts above it
  /// come or go: X positions its cells itself, a frame or two after one
  /// changes size, where the browser's own scroll anchoring can't follow.
  /// Stops as soon as the reader scrolls, or once nothing has moved for a
  /// few frames.
  function keepInPlace() {
    const current = anchor;
    current.until = performance.now() + SETTLE_MS;
    current.calm = 0;
    if (current.running) return;
    current.running = true;
    const step = () => {
      if (anchor !== current) return;
      const box = current.cell.isConnected ? current.cell.getBoundingClientRect() : null;
      const done = !box || !box.height || lastInput > current.since || performance.now() > current.until;
      if (!done) {
        const drift = box.top - current.top;
        if (Math.abs(drift) >= 0.5) {
          window.scrollBy(0, drift);
          current.calm = 0;
        } else {
          current.calm += 1;
        }
      }
      if (done || current.calm >= SETTLE_FRAMES) {
        anchor = null;
        return;
      }
      requestAnimationFrame(step);
    };
    step();
  }

  /// Folds a post in view away, so the posts under it slide up rather than
  /// jump, and marks it hidden once it's flat.
  function foldAway(cell, height) {
    cell.dataset.unragerFolding = "";
    const animation = cell.animate(
      [
        { height: `${height}px`, opacity: 1 },
        { height: "0px", opacity: 0 },
      ],
      { duration: FOLD_MS, easing: "cubic-bezier(0.4, 0, 0.2, 1)", fill: "forwards" }
    );
    folding.set(cell, animation);
    animation.finished.then(
      () => {
        if (folding.get(cell) !== animation) return;
        folding.delete(cell);
        delete cell.dataset.unragerFolding;
        const id = cellTweetId(cell);
        if (id !== null && hidden.has(id)) cell.dataset.unrager = "hidden";
        animation.cancel();
        scheduleApply();
      },
      () => {}
    );
  }

  function unfold(cell) {
    const animation = folding.get(cell);
    folding.delete(cell);
    delete cell.dataset.unragerFolding;
    animation.cancel();
  }

  /// Marks cells instead of removing them: X's React tree owns these nodes,
  /// and pulling one out from under it breaks its next unmount. Re-checking
  /// every cell lets a recycled cell showing a different post come back.
  function applyHides() {
    const now = Date.now();
    for (const [domId, until] of holds) if (until <= now) holds.delete(domId);
    for (const [domId, until] of threadHolds) if (until <= now) threadHolds.delete(domId);
    const home = onHome();
    root.toggleAttribute("data-unrager-away", !home);
    const filtering = home && !settings.paused && !settings.reveal;
    const buttons = offers.size > 0 && !settings.paused && home && onForYou();
    const { rows, edge } = planCells(timelineCells(), filtering);
    const settle = measure(rows, home, filtering);
    if (edge < 0) waitingSince = 0;
    else if (!waitingSince) waitingSince = now;
    const edgeShows = edge >= 0 && rows.slice(edge + 1).every((r) => !r.shows);
    const edgeState = now - waitingSince > EDGE_STEADY_MS ? "steady" : "";
    const entering = [];
    let marks = false;
    rows.forEach((row, i) => {
      const { cell, id, info, mark } = row;
      if (folding.has(cell)) {
        if (mark === "hidden" && filtering) {
          marks = true;
          return;
        }
        unfold(cell);
      }
      if (row.fold) {
        foldAway(cell, row.height);
        lastShown.set(cell, false);
        marks = true;
        return;
      }
      if (mark) {
        if (cell.dataset.unrager !== mark) cell.dataset.unrager = mark;
        marks = true;
      } else if (cell.dataset.unrager) {
        delete cell.dataset.unrager;
      }
      if (i === edge && edgeShows) {
        if (cell.dataset.unragerEdge !== edgeState) cell.dataset.unragerEdge = edgeState;
      } else if (cell.dataset.unragerEdge !== undefined) {
        delete cell.dataset.unragerEdge;
      }
      if (row.enter) {
        cell.dataset.unragerEnter = "";
        entering.push(cell);
      }
      if (syncNote(cell, info)) marks = true;
      syncButton(cell, id, buttons && (!mark || (mark === "hidden" && settings.reveal)));
      if (home && row.shows) noteOnScreen(cell, id);
      lastShown.set(cell, row.shows);
    });
    if (entering.length) {
      setTimeout(() => {
        for (const cell of entering) delete cell.dataset.unragerEnter;
      }, ENTER_MS + 100);
    }
    if (settle) keepInPlace();
    marksOnPage = marks;
  }

  let scheduled = false;
  function scheduleApply() {
    const idle = hidden.size === 0 && holds.size === 0 && threadHolds.size === 0 && folding.size === 0;
    if (scheduled || (idle && !marksOnPage && offers.size === 0)) {
      return;
    }
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
    if (tweet.notInterested) {
      offers.delete(tweet.domId);
      offers.set(tweet.domId, tweet.notInterested);
      if (offers.size > MAX_KNOWN) offers.delete(offers.keys().next().value);
    }
    if (tweet.thread) {
      if (!threads.has(tweet.thread)) threads.set(tweet.thread, new Map());
      threads.get(tweet.thread).set(tweet.domId, { position: tweet.position, own: tweet.own });
      if (threads.size > MAX_KNOWN) threads.delete(threads.keys().next().value);
    }
  }

  /// Whether the user chose to always show the post a cell shows.
  function keptByUser(domId) {
    for (const t of known.values()) {
      if (t.domId !== domId) continue;
      const v = verdicts.get(t.id);
      if (v && v.overridden && v.verdict === "keep") return true;
    }
    return false;
  }

  /// A reply under a hidden post in one of X's conversation blocks is hidden
  /// with it, and waits while that post waits for its verdict, so a followed
  /// account's reply never sits on the timeline answering nothing. The
  /// user's own conversations and replies they chose to show are left alone.
  function syncThreads() {
    for (const posts of threads.values()) {
      let hiddenAbove = false;
      let waitUntil = 0;
      for (const [domId, post] of [...posts].sort((a, b) => a[1].position - b[1].position)) {
        const info = hidden.get(domId);
        const follows = !post.own && !keptByUser(domId);
        if (hiddenAbove && follows) {
          if (!info) hidden.set(domId, { reason: null, overridden: false, inherited: true });
        } else if (info && info.inherited) {
          hidden.delete(domId);
        }
        if (!hidden.has(domId) && waitUntil && follows) threadHolds.set(domId, waitUntil);
        else threadHolds.delete(domId);
        if (hidden.has(domId)) hiddenAbove = true;
        if (holds.has(domId)) waitUntil = Math.max(waitUntil, holds.get(domId));
      }
    }
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
    syncThreads();
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
    syncThreads();
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
    for (let i = 0; i < fresh.length; ) {
      const size = i === 0 ? FIRST_CHUNK : CHUNK;
      classifyChunk(fresh.slice(i, i + size));
      i += size;
    }
  }

  /// Asks unrager to load the model before X's posts arrive: after an idle
  /// spell that takes a second or two, which the first posts would
  /// otherwise spend waiting out of view.
  function warm() {
    if (settings.paused || Date.now() - lastWarm < WARM_EVERY_MS) return;
    lastWarm = Date.now();
    sendToExtension({ type: "warm" }).catch(() => {});
  }

  /// The user's own call on the post a cell shows, from the page's context
  /// menu or a note's "Show this post". It applies here at once, and unrager
  /// keeps it, so every client and every later visit respects it.
  function overrule(domId, verdict) {
    const ids = new Set([domId]);
    for (const t of known.values()) if (t.domId === domId) ids.add(t.id);
    for (const id of ids) apply(id, { id, verdict, reason: null, overridden: true });
    syncThreads();
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
    syncThreads();
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
    syncThreads();
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
      if (window.location.pathname === "/home") warm();
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

  document.addEventListener("unrager:loading", () => {
    if (settingsLoaded) warm();
    else ready.then(warm);
  });

  /// A reader scrolling takes over from keepInPlace at once.
  for (const type of ["wheel", "touchmove", "keydown", "mousedown"]) {
    window.addEventListener(
      type,
      () => {
        lastInput = performance.now();
      },
      { capture: true, passive: true }
    );
  }

  new MutationObserver(scheduleApply).observe(root, { childList: true, subtree: true });

  document.addEventListener("DOMContentLoaded", publish, { once: true });
  console.info("[unrager] active");
})();
