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
  /// A tab asks for the model to be loaded at most this often; the server
  /// skips one that just answered anyway.
  const WARM_EVERY_MS = 30000;
  const MAX_ON_SCREEN = 1000;
  /// Addresses X gives the dialogs it opens over the page you're on (a reply,
  /// a photo), which stays on screen underneath.
  const OVERLAY = /^\/(?:compose\/|[^/]+\/status\/\d+\/(?:photo|video)\/)/;
  /// What X lays over the page for those, and for dialogs that keep its
  /// address.
  const DIALOG = '[aria-modal="true"], [role="dialog"][data-slot="xds-modal-surface"]';
  /// The rows of X's timeline list, which X positions itself as you scroll,
  /// and the post blocks inside them: one per row, or a conversation's
  /// posts in one row. A quoted post is a block nested inside another.
  const ROW = "main li[data-index]";
  const POST = '[role="link"][data-href*="/status/"]';
  /// What `<html>` carries while marked cells are kept out of view: on Home,
  /// not paused, hidden posts not shown.
  const FILTERING = "html:not([data-unrager-paused]):not([data-unrager-reveal]):not([data-unrager-away])";
  /// How long the page has to stay still before rows X measured wrong are
  /// looked for.
  const HEAL_DELAY_MS = 250;
  /// How many times in a row one row is nudged before it's left alone.
  const MAX_NUDGES = 3;
  /// How long the Not interested button waits for X's menu to open or close.
  const MENU_WAIT_MS = 1500;
  const MENU = '[role="menu"]';
  /// How long Home can show posts while no timeline arrives, or none of
  /// them can be found on the page, before the popup says X changed.
  const DRIFT_MS = 10000;
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
  /// Ids of the posts the last pass held back, here or behind a post above.
  let heldIds = new Set();
  /// The style sheet that hides posts by id the moment X adds them.
  const rules = document.createElement("style");
  /// Rows nudged so X's list measures them again, with how often.
  const nudged = new WeakMap();
  let healTimer = 0;
  let nudging = false;
  const warned = new Set();
  const health = { failing: false, lastError: null, shapeProblem: null, layoutProblem: null };
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let generation = 0;
  let lastBadge = "";
  let marksOnPage = false;
  let contextTarget = null;
  /// The page on screen under any dialog.
  let page = null;
  /// When the timeline's loading edge appeared, or 0 while there's none.
  let waitingSince = 0;
  let lastWarm = 0;
  /// Timeline responses read on this tab, and the ids their cells show, for
  /// telling when X's page and its timelines stop matching up.
  let timelinesSeen = 0;
  const seenDomIds = new Set();
  let driftSince = 0;
  let lastDriftCheck = 0;
  let driftTimer = 0;

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
      layoutProblem: health.layoutProblem,
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

  /// Whether a dialog covers the page, as opposed to a bar along its bottom
  /// edge (a cookie notice) that can stay open while you move between pages.
  function dialogOpen() {
    for (const dialog of document.querySelectorAll(DIALOG)) {
      const box = dialog.getBoundingClientRect();
      if (box.height > 0 && box.top < window.innerHeight / 2) return true;
    }
    return false;
  }

  /// Follows which page is on screen. X changes the address when it opens a
  /// reply box or a photo over a page, which stays underneath, so neither an
  /// overlay's address nor one that changed with a dialog open counts.
  function trackPage() {
    const path = window.location.pathname;
    if (path === page || OVERLAY.test(path) || dialogOpen()) return;
    page = path;
  }

  /// Marks the page as Home or not as soon as X changes the address, which
  /// it does before it draws the new page, so Home's rows are filtered from
  /// the moment X adds them on the way back. Leaving Home is left to
  /// `applyHides`, so a hidden post doesn't flash up as the page goes.
  function arrive() {
    if (onHome()) root.removeAttribute("data-unrager-away");
  }

  /// Only the Home timelines are filtered. Anywhere else (a post you opened,
  /// a profile, search) you went looking, so nothing is hidden there. A
  /// dialog over Home keeps it filtered, so the timeline under a reply box
  /// doesn't shift and is where you left it when the box closes.
  function onHome() {
    trackPage();
    return page === "/home";
  }

  /// The post a cell shows: a post block's permalink, which for a repost is
  /// the original's. A row without a post (Who to follow) shows none.
  function cellTweetId(cell) {
    const m = /\/status\/(\d+)/.exec(cell.getAttribute("data-href") || "");
    return m ? m[1] : null;
  }

  /// The post block `el` is in, past any quoted post it's inside.
  function postOf(el) {
    let post = null;
    for (let block = el.closest(POST); block; block = block.parentElement && block.parentElement.closest(POST)) {
      post = block;
    }
    return post;
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
    for (const type of ["pointerdown", "pointerup", "mousedown", "mouseup"]) show.addEventListener(type, swallow);
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

  /// A post's own "More" button: the menu button in its header, not one in
  /// its action bar (Repost, Share) or in a post it quotes.
  function moreButton(post) {
    for (const button of post.querySelectorAll('button[aria-haspopup="menu"]')) {
      if (button.closest(POST) === post && !button.closest('[role="group"]')) return button;
    }
    return null;
  }

  /// The menu `trigger` opened, which X portals to the end of the page and
  /// labels by its trigger, so another post's menu is never mistaken for it.
  function menuOf(trigger) {
    return trigger.id ? document.querySelector(`${MENU}[aria-labelledby="${CSS.escape(trigger.id)}"]`) : null;
  }

  function closeMenu() {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", keyCode: 27, bubbles: true }));
  }

  /// X's own "Not interested in this post", minus the menu: opens the post's
  /// "More" menu out of sight and picks the item X labelled `prompt`, so X
  /// sends its feedback and swaps in its usual confirmation, Undo included.
  async function pickNotInterested(post, prompt) {
    const more = moreButton(post);
    if (!more || !more.id) return false;
    root.setAttribute("data-unrager-quiet-menu", "");
    let picked = false;
    try {
      more.click();
      const menu = await waitFor(() => menuOf(more), MENU_WAIT_MS);
      const items = menu ? [...menu.querySelectorAll('[role="menuitem"]')] : [];
      const item = items.find((el) => el.textContent.trim() === prompt);
      if (item) {
        item.click();
        picked = true;
      } else if (menu || (await waitFor(() => menuOf(more), MENU_WAIT_MS))) {
        closeMenu();
      }
      await waitFor(() => !menuOf(more), MENU_WAIT_MS);
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
    const post = postOf(button);
    const id = post ? cellTweetId(post) : null;
    const prompt = id === null ? null : offers.get(id);
    if (!prompt || button.dataset.state === "busy") return;
    button.dataset.state = "busy";
    if (await pickNotInterested(post, prompt)) {
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

  /// The one-click Not interested button, sized, spaced and coloured from
  /// the post's own "More" button so it sits in X's header like one of X's.
  function buildButton(more, prompt) {
    const wrap = document.createElement("div");
    wrap.className = "unrager-ni-wrap";
    wrap.style.margin = getComputedStyle(more).margin;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "unrager-ni";
    button.title = prompt;
    button.setAttribute("aria-label", prompt);
    button.innerHTML = FROWN;
    const box = more.getBoundingClientRect();
    if (box.width && box.height) {
      button.style.width = `${box.width}px`;
      button.style.height = `${box.height}px`;
    }
    const icon = more.querySelector("svg");
    if (icon) {
      const glyph = icon.getBoundingClientRect();
      const svg = button.querySelector("svg");
      if (glyph.width && glyph.height) {
        svg.style.width = `${glyph.width}px`;
        svg.style.height = `${glyph.height}px`;
      }
      button.style.color = getComputedStyle(icon).color;
    }
    button.addEventListener("click", onNotInterested);
    for (const type of ["pointerdown", "pointerup", "mousedown", "mouseup"]) button.addEventListener(type, swallow);
    wrap.append(button);
    return wrap;
  }

  /// Adds the button to a post X offers "Not interested" for, and takes it
  /// off a cell X has since reused for a post it doesn't. It goes first in
  /// the row "More" leads, before X's Grok button. A cell out of view gets
  /// it once it shows, when X's header can be measured to match.
  function syncButton(cell, id, show) {
    const existing = cell.querySelector(".unrager-ni-wrap");
    const prompt = show && id !== null ? offers.get(id) : undefined;
    if (!prompt) {
      if (existing) existing.remove();
      return;
    }
    if (existing) return;
    const more = moreButton(cell);
    const row = more && more.parentElement;
    if (row) row.insertBefore(buildButton(more, prompt), row.firstElementChild);
  }

  /// The cells of the timeline X has rendered, top to bottom: each row's
  /// post blocks, or the row itself when it holds no post. A dialog X lays
  /// over it (a photo with its replies) has rows of its own, left alone.
  function timelineCells() {
    const cells = [];
    for (const row of timelineRows()) {
      const posts = [...row.querySelectorAll(POST)].filter((block) => postOf(block) === block);
      if (posts.length) {
        cells.push(...posts);
        clearMarks(row);
      } else {
        cells.push(row);
      }
    }
    return cells;
  }

  /// The rows of X's timeline list in `data-index` order, without those of
  /// a list nested in a row or of a dialog laid over the page.
  function timelineRows() {
    const rows = [...document.querySelectorAll(ROW)].filter(
      (row) => !row.parentElement.closest(`li[data-index], ${DIALOG}`)
    );
    return rows.sort((a, b) => Number(a.dataset.index) - Number(b.dataset.index));
  }

  /// Takes the marks off a row X now fills with posts, which carry their own:
  /// a row held while it showed no post would otherwise hide them.
  function clearMarks(row) {
    if (row.dataset.unrager !== undefined) delete row.dataset.unrager;
    if (row.dataset.unragerEdge !== undefined) delete row.dataset.unragerEdge;
    if (row.dataset.unragerEnter !== undefined) delete row.dataset.unragerEnter;
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

  /// Reads, before anything is written, which cells change: a post in view
  /// that a late verdict hides folds away. Posts coming or going above the
  /// one in view need no making up for: X's list moves the page by what a
  /// row above it gains or loses, so the post being read stays put.
  function measure(rows, home, filtering) {
    const motion = home && !reducedMotion.matches;
    let changed = false;
    for (const row of rows) {
      const was = lastShown.get(row.cell);
      const noted = hasNote(row.cell) !== (!!row.info && settings.reveal && !settings.paused);
      row.changed = was !== undefined && (was !== row.shows || noted);
      row.enter = motion && row.changed && row.shows && was === false;
      if (row.changed) changed = true;
    }
    if (!changed || !home) return;
    for (const row of rows) {
      if (!row.changed || row.shows || row.mark !== "hidden" || !filtering || !motion || folding.has(row.cell)) continue;
      const box = row.cell.getBoundingClientRect();
      if (box.height > 0 && box.bottom > 0 && box.top < window.innerHeight) {
        row.fold = true;
        row.height = box.height;
      }
    }
  }

  /// Folds a post in view away, so the posts under it slide up rather than
  /// jump, and marks it hidden once it's flat. Its padding and divider fold
  /// with it.
  function foldAway(cell, height) {
    cell.dataset.unragerFolding = "";
    const animation = cell.animate(
      [
        { height: `${height}px`, opacity: 1 },
        { height: "0px", paddingTop: "0px", paddingBottom: "0px", borderBottomWidth: "0px", opacity: 0 },
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
    const buttons = offers.size > 0 && !settings.paused && home;
    const { rows, edge } = planCells(timelineCells(), filtering);
    measure(rows, home, filtering);
    if (edge < 0) waitingSince = 0;
    else if (!waitingSince) waitingSince = now;
    const edgeShows = edge >= 0 && rows.slice(edge + 1).every((r) => !r.shows);
    const edgeState = now - waitingSince > EDGE_STEADY_MS ? "steady" : "";
    const entering = [];
    const held = new Set();
    let marks = false;
    rows.forEach((row, i) => {
      const { cell, id, info, mark } = row;
      if (mark === "held" && id !== null) held.add(id);
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
      } else if (id !== null) {
        if (cell.dataset.unrager !== "shown") cell.dataset.unrager = "shown";
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
    marksOnPage = marks;
    heldIds = held;
    syncRules();
    if (home) scheduleHeal();
  }

  /// The posts X must find out of view the moment it adds them: hidden ones,
  /// and held ones that haven't been on screen. X's list measures a row in
  /// the same task that adds it, before any script can mark it, and keeps
  /// that height; only a style sheet applies in time. Only posts a timeline
  /// brought can be among them.
  function hiddenOnArrival() {
    const ids = [];
    for (const id of seenDomIds) {
      if (!/^\d+$/.test(id)) continue;
      const waiting = holds.has(id) || threadHolds.has(id) || heldIds.has(id);
      if (hidden.has(id) || (waiting && !onScreen.has(id))) ids.push(id);
    }
    return ids;
  }

  /// Keeps the style sheet hiding `hiddenOnArrival` current. A post already
  /// marked shown is left to `applyHides`, so a late verdict still folds it
  /// away, and so is the loading edge's spinner; a quoted post never hides
  /// on its own, nor does a reply in a dialog over the timeline.
  function syncRules() {
    const ids = hiddenOnArrival();
    const text = ids.length
      ? `${FILTERING} ${ROW} ${POST}:is(${ids.map((id) => `[data-href$="/status/${id}"]`).join(", ")})` +
        `:not([data-unrager="shown"], [data-unrager-edge], [role="link"] *, :is(${DIALOG}) *) { display: none !important; }`
      : "";
    if (!rules.isConnected) root.append(rules);
    if (rules.textContent !== text) rules.textContent = text;
  }

  /// Looks for rows X measured wrong once the page has been still a moment.
  function scheduleHeal() {
    clearTimeout(healTimer);
    healTimer = setTimeout(healGaps, HEAL_DELAY_MS);
  }

  /// X's list places each row where the one above it ends, by the height it
  /// measured. A row whose next row doesn't start where it ends changed
  /// height without X noticing (it was measured before a mark applied, and
  /// went out of view before X looked again), leaving a gap under it or an
  /// overlap. Growing it by a pixel for a couple of frames makes X measure
  /// every row it shows again. A row that lines up again gets its tries back.
  function healGaps() {
    healTimer = 0;
    if (document.hidden) return;
    if (folding.size || nudging) {
      scheduleHeal();
      return;
    }
    if (!onHome()) return;
    let above = null;
    for (const row of timelineRows()) {
      const index = Number(row.dataset.index);
      const box = row.getBoundingClientRect();
      if (above && index === above.index + 1) {
        if (Math.abs(box.top - above.bottom) <= 1) nudged.delete(above.row);
        else if (nudge(above.row)) return;
      }
      above = { row, index, bottom: box.bottom };
    }
  }

  /// Returns whether it nudged: a row still out of line after `MAX_NUDGES`
  /// tries is left as it is, and the rows under it are still looked at.
  function nudge(row) {
    const times = nudged.get(row) || 0;
    if (times >= MAX_NUDGES) return false;
    nudged.set(row, times + 1);
    nudging = true;
    row.dataset.unragerNudge = "";
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        delete row.dataset.unragerNudge;
        nudging = false;
        scheduleHeal();
      })
    );
    return true;
  }

  function needsApply() {
    const idle = hidden.size === 0 && holds.size === 0 && threadHolds.size === 0 && folding.size === 0;
    return !idle || marksOnPage || offers.size > 0;
  }

  let scheduled = false;
  function scheduleApply() {
    if (scheduled || !needsApply()) return;
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
    seenDomIds.delete(tweet.domId);
    seenDomIds.add(tweet.domId);
    if (seenDomIds.size > MAX_ON_SCREEN) seenDomIds.delete(seenDomIds.values().next().value);
    if (tweet.notInterested) {
      offers.delete(tweet.domId);
      offers.set(tweet.domId, tweet.notInterested);
      if (offers.size > MAX_KNOWN) offers.delete(offers.keys().next().value);
    }
    if (tweet.thread) {
      if (!threads.has(tweet.thread)) threads.set(tweet.thread, new Map());
      const posts = threads.get(tweet.thread);
      posts.set(tweet.domId, { own: tweet.own });
      if (threads.size > MAX_KNOWN) threads.delete(threads.keys().next().value);
      if (tweet.own || [...posts.values()].some((post) => post.own)) claimThread(posts);
    }
  }

  /// A conversation the user took part in is theirs as a whole, including
  /// posts X showed before it added their reply to the block: none of them
  /// is held or hidden any more.
  function claimThread(posts) {
    for (const [domId, post] of posts) {
      if (post.own) continue;
      post.own = true;
      hidden.delete(domId);
      holds.delete(domId);
      for (const t of known.values()) if (t.domId === domId) t.own = true;
    }
  }

  /// Orders a conversation block's posts top first: a reply is always newer
  /// than the post it answers, and post ids grow with time.
  function byAge([a], [b]) {
    return a.length - b.length || (a < b ? -1 : a > b ? 1 : 0);
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
      for (const [domId, post] of [...posts].sort(byAge)) {
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
    syncRules();
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
    syncRules();
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
    timelinesSeen += 1;
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
    syncRules();
    scheduleApply();
    publish();
  }

  /// What's wrong when Home shows posts the filter can't work on: no
  /// timeline ever arrived (X renamed its request), or none of the posts
  /// on screen is one a timeline brought (X changed its page).
  function driftProblem() {
    if (!timelinesSeen) return "no timeline responses seen; X may have renamed its timeline request";
    const ids = timelineCells().map(cellTweetId);
    if (ids.some((id) => id !== null && seenDomIds.has(id))) return null;
    return "the posts on the page don't match the timeline; X may have changed its page";
  }

  /// Notices X changing under the filter, which otherwise just stops
  /// hiding anything: a problem that lasts `DRIFT_MS` goes to the popup,
  /// checked again then even if the page has gone still. Page changes check
  /// at most once a second.
  function checkDrift() {
    const now = Date.now();
    if (now - lastDriftCheck < 1000) return;
    assessDrift();
  }

  function assessDrift() {
    const now = Date.now();
    lastDriftCheck = now;
    const problem = onHome() && document.querySelector("main article") ? driftProblem() : null;
    if (!problem) driftSince = 0;
    else if (!driftSince) driftSince = now;
    const report = problem && now - driftSince >= DRIFT_MS ? problem : null;
    if (problem && !report && !driftTimer) {
      driftTimer = setTimeout(() => {
        driftTimer = 0;
        assessDrift();
      }, driftSince + DRIFT_MS - now + 50);
    }
    if (report === health.layoutProblem) return;
    health.layoutProblem = report;
    if (report) warn(report);
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
      const post = e.target instanceof Element && e.target.closest(ROW) ? postOf(e.target) : null;
      contextTarget = post ? cellTweetId(post) : null;
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

  const ADDED = `li[data-index], ${POST}`;

  /// Whether X just put timeline rows or posts on the page. X adds them
  /// from its own animation frame callbacks, so a frame requested now would
  /// mark them only after they've been painted once.
  function addsCells(mutations) {
    for (const m of mutations) {
      for (const node of m.addedNodes) {
        if (node instanceof Element && (node.matches(ADDED) || node.querySelector(ADDED))) return true;
      }
    }
    return false;
  }

  /// New rows are marked before the browser paints them; anything else
  /// waits for the next frame.
  new MutationObserver((mutations) => {
    trackPage();
    if (addsCells(mutations) && needsApply()) applyHides();
    else scheduleApply();
    checkDrift();
  }).observe(root, { childList: true, subtree: true });

  if (window.navigation) window.navigation.addEventListener("currententrychange", arrive);
  window.addEventListener("popstate", arrive);
  window.addEventListener("scroll", () => marksOnPage && scheduleHeal(), { passive: true });

  syncRules();
  document.addEventListener("DOMContentLoaded", publish, { once: true });
  console.info("[unrager] active");
})();
