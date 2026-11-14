/// Stats on the user's own posts, drawn into X's own action bar without
/// making it any bigger: who liked and reposted a post as small faces beside
/// its counts, how much each count rose since the user last looked, link
/// clicks and new followers beside its views, and a card on hover (or
/// click) with X's analytics, the first two days' impressions hour by hour,
/// and everyone who liked, reposted or quoted it. Everything sits in a gap
/// X's bar already leaves, positioned over it, and anything that doesn't
/// fit is left out. The numbers come from unrager's server (X's analytics,
/// Favoriters, Retweeters), which only a full `unrager serve` answers; the
/// rises since the last look are read off X's own labels and need nothing.
(() => {
  const M = unragerInsightsModel;
  const root = document.documentElement;
  const BAR = '[role="group"]';
  const POST_BLOCK = '[role="link"][data-href*="/status/"]';
  const CONTROLS = {
    replies: '[data-testid="reply"], [data-engagement-action="reply"]',
    reposts: '[data-testid="retweet"], [data-testid="unretweet"], [data-engagement-action="retweet"]',
    likes: '[data-testid="like"], [data-testid="unlike"], [data-engagement-action="like"]',
    bookmarks: '[data-testid="bookmark"], [data-testid="removeBookmark"], [data-engagement-action="bookmark"]',
  };
  /// The slots a bar gets drawn into, each named for the count it follows.
  const SLOTS = ["replies", "reposts", "likes", "views"];
  /// The card tab hovering each slot's additions opens.
  const SLOT_TAB = { replies: "overview", reposts: "reposts", likes: "likes", views: "overview" };
  /// How often a post in view is asked about again. The server answers
  /// from its own cache and decides when X is asked, so this is cheap.
  const CHECK_EVERY_MS = 30000;
  /// How long posts wait to be asked about together, how many go in one
  /// glance, and how many glances may be out at once.
  const FLUSH_MS = 40;
  const MAX_BATCH = 40;
  const MAX_IN_FLIGHT = 2;
  /// When to ask again for parts the server was still asking X for.
  const RECHECK_MS = [900, 1800, 3500, 7000, 15000];
  const PARTS = ["analytics", "likers", "reposters"];
  /// How long a post stays in view before what it shows counts as seen.
  const SEEN_AFTER_MS = 1200;
  /// Posts whose last-seen counts are kept, most recent first.
  const MAX_SEEN = 600;
  /// After the tab was hidden this long, rises are counted from the last
  /// look before the break rather than from the one this page started with.
  const NEW_LOOK_AFTER_MS = 20 * 60000;
  const HOVER_OPEN_MS = 260;
  const HOVER_CLOSE_MS = 280;
  /// The space kept between a count and what's drawn after it, between the
  /// things drawn, and before the next control.
  const LEAD = 5;
  const ITEM_GAP = 4;
  const TAIL = 4;
  const FACE = 18;
  const FACE_STEP = 12;
  const FONT = 'TwitterChirp, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif';
  const ICONS = {
    link:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M10 14a4.6 4.6 0 0 0 6.5 0l3.2-3.2a4.6 4.6 0 0 0-6.5-6.5l-1.5 1.5"/><path d="M14 10a4.6 4.6 0 0 0-6.5 0l-3.2 3.2a4.6 4.6 0 0 0 6.5 6.5l1.5-1.5"/></svg>',
    follows:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="9.5" cy="8" r="3.7"/><path d="M3 19.5c.8-3.3 3.4-5.3 6.5-5.3s5.7 2 6.5 5.3"/><path d="M18.5 7.5v6M15.5 10.5h6"/></svg>',
    visits:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2.5 12s3.4-6.5 9.5-6.5S21.5 12 21.5 12s-3.4 6.5-9.5 6.5S2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/></svg>',
    out: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/></svg>',
    close: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>',
    verified:
      '<svg viewBox="0 0 22 22" aria-hidden="true" class="tick"><path d="M20.4 11c0-1.4-.8-2.6-2-3.2.4-1.3.1-2.8-.9-3.7-1-1-2.4-1.3-3.7-.9C13.2 2 12 1.2 11 1.2S8.8 2 8.2 3.2c-1.3-.4-2.8-.1-3.7.9-1 1-1.3 2.4-.9 3.7C2.4 8.4 1.6 9.6 1.6 11s.8 2.6 2 3.2c-.4 1.3-.1 2.8.9 3.7 1 1 2.4 1.3 3.7.9.6 1.2 1.8 2 3.2 2s2.6-.8 3.2-2c1.3.4 2.8.1 3.7-.9 1-1 1.3-2.4.9-3.7 1.2-.6 2-1.8 2-3.2z"/><path class="check" d="M9.6 14.6l-3-3 1.4-1.4 1.6 1.6 4.4-4.8 1.5 1.4z"/></svg>',
  };
  const STANDING_LABEL = { mutual: "Mutual", follower: "Follows you", following: "Following" };
  const FOLLOW_LABEL = { busy: "Following…", failed: "Couldn't follow", later: "Try later" };
  const LENSES = [
    ["all", "All"],
    ["followers", "Follow you"],
    ["followBack", "Follow back"],
    ["following", "You follow"],
    ["verified", "Verified"],
  ];
  const TABS = [
    ["overview", "Overview"],
    ["likes", "Likes"],
    ["reposts", "Reposts"],
    ["quotes", "Quotes"],
  ];

  const settings = { off: false, loaded: false };
  /// The signed-in account: its id from X's `twid` cookie, its handle from
  /// the server (or the page), and whether the server reads X as that same
  /// account, which is what makes its analytics the user's.
  const self = { id: null, handle: null };
  const server = { state: "unknown", checkedAt: 0, timer: 0 };
  /// Every own post's action bar on the page, with what was drawn in it.
  const bars = new Map();
  /// Bars looked at and found to be someone else's, or not a post's.
  const notOurs = new WeakMap();
  /// How soon a bar whose post couldn't be read yet is looked at again.
  const NOT_A_POST_RECHECK_MS = 1500;
  /// What's known of each of the user's posts on the page, by id.
  const posts = new Map();
  /// What the user last saw of each post (`{t, c: counts, a: analytics}`),
  /// shared by every tab through extension storage.
  let seen = {};
  let seenLoaded = false;
  let seenWrite = 0;
  let hiddenSince = 0;
  /// Posts waiting to be asked about, and to be read from storage.
  const wanted = new Set();
  const storedWanted = new Set();
  let flushTimer = 0;
  let inFlight = 0;
  let passFrame = 0;
  let retryTimer = 0;
  let measureCanvas = null;
  const hoverBound = new WeakSet();
  /// Follow backs sent from the card and not yet answered, or just failed,
  /// by the person's id.
  const followState = new Map();
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const card = {
    host: null,
    shadow: null,
    el: null,
    id: null,
    bar: null,
    trigger: null,
    tab: "overview",
    pinned: false,
    openTimer: 0,
    closeTimer: 0,
    animate: false,
    lens: "all",
    side: null,
  };

  /// Chrome invalidates this script's extension context when the extension
  /// is reloaded; the page lives on, so every call back into it must survive.
  function send(message) {
    try {
      return chrome.runtime.sendMessage(message).then(
        (answer) => answer || { ok: false, kind: "unreachable" },
        () => ({ ok: false, kind: "unreachable" })
      );
    } catch (_) {
      return Promise.resolve({ ok: false, kind: "unreachable" });
    }
  }

  /// The signed-in account's id, from X's `twid` cookie (`u=<id>`).
  function cookieSelfId() {
    const cookie = /(?:^|;\s*)twid=([^;]*)/.exec(document.cookie);
    if (!cookie) return null;
    let value = cookie[1];
    try {
      value = decodeURIComponent(value);
    } catch (_) {}
    const id = /^"?u=(\d+)"?$/.exec(value);
    return id ? id[1] : null;
  }

  /// The user's handle as X's own navigation links to their profile, for
  /// when the server can't say.
  function pageHandle() {
    const link = document.querySelector(
      '[data-testid="AppTabBar_Profile_Link"], nav a[aria-label="Profile"], header a[aria-label="Profile"]'
    );
    const m = link && /^\/([A-Za-z0-9_]{1,15})$/.exec(link.getAttribute("href") || "");
    return m ? m[1] : null;
  }

  function serverReady() {
    return server.state === "ok";
  }

  /// Asks the server who it reads X as. Its analytics are the user's only
  /// when that's the account signed in on this page; otherwise the bar still
  /// shows rises since the last look, which need nothing from it.
  async function checkServer() {
    clearTimeout(server.timer);
    if (settings.off) return;
    self.id = cookieSelfId();
    const answer = await send({ type: "whoami" });
    server.checkedAt = Date.now();
    if (answer.ok && answer.value && answer.value.handle) {
      const sameAccount = !self.id || answer.value.rest_id === self.id;
      server.state = sameAccount ? "ok" : "other_account";
      if (sameAccount) {
        self.handle = answer.value.handle;
        chrome.storage.local.set({ insightsSelf: { id: self.id, handle: self.handle } }).catch(() => {});
      }
    } else {
      server.state = answer.kind || "unreachable";
    }
    if (!self.handle) self.handle = pageHandle();
    if (!serverReady()) {
      const later = server.state === "filter_only" ? 5 * 60000 : 60000;
      server.timer = setTimeout(checkServer, later);
    }
    schedulePass();
    for (const st of bars.values()) {
      if (st.near) want(st.id);
    }
  }

  /// X's theme, from the background behind `from` (the post, when there is
  /// one), else the page's: light, dim or lights out.
  function palette(from) {
    let rgb = null;
    const chain = [];
    for (let el = from; el && el !== document.documentElement; el = el.parentElement) chain.push(el);
    chain.push(document.body, document.documentElement);
    for (const el of chain) {
      if (!el) continue;
      const m = /rgba?\(([^)]+)\)/.exec(getComputedStyle(el).backgroundColor);
      if (!m) continue;
      const [r, g, b, a = 1] = m[1].split(",").map((v) => parseFloat(v));
      if (a > 0.5) {
        rgb = [r, g, b];
        break;
      }
    }
    if (!rgb) rgb = window.matchMedia("(prefers-color-scheme: dark)").matches ? [0, 0, 0] : [255, 255, 255];
    const [r, g, b] = rgb;
    const dark = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 < 0.5;
    const dim = dark && r + g + b > 40;
    return {
      bg: `rgb(${r}, ${g}, ${b})`,
      fg: dark ? "rgb(231, 233, 234)" : "rgb(15, 20, 25)",
      sub: dark ? (dim ? "rgb(139, 152, 165)" : "rgb(113, 118, 123)") : "rgb(83, 100, 113)",
      line: dark ? (dim ? "rgb(56, 68, 77)" : "rgb(47, 51, 54)") : "rgb(239, 243, 244)",
      wash: dark ? "rgba(255, 255, 255, 0.06)" : "rgba(15, 20, 25, 0.04)",
      shadow: dark
        ? "rgba(255, 255, 255, 0.2) 0 0 15px, rgba(255, 255, 255, 0.15) 0 0 3px 1px"
        : "rgba(101, 119, 134, 0.2) 0 0 15px, rgba(101, 119, 134, 0.15) 0 0 3px 1px",
      dark,
    };
  }

  function applyPalette(host, from) {
    const p = palette(from);
    for (const [name, value] of Object.entries(p)) {
      if (typeof value === "string") host.style.setProperty(`--${name}`, value);
    }
    host.toggleAttribute("data-dark", p.dark);
  }

  /// How wide `text` is in the page's font, to know what fits before
  /// anything is drawn.
  function textWidth(text, font) {
    measureCanvas = measureCanvas || document.createElement("canvas");
    const ctx = measureCanvas.getContext("2d");
    ctx.font = font;
    return Math.ceil(ctx.measureText(text).width);
  }

  /// A small element builder: text only ever goes in as text, never markup.
  function h(tag, attrs, ...children) {
    const el = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs || {})) {
      if (value === null || value === undefined || value === false) continue;
      if (key === "class") el.className = value;
      else if (key === "text") el.textContent = value;
      else if (key === "html") el.innerHTML = value;
      else if (key === "style") Object.assign(el.style, value);
      else if (key.startsWith("on")) el.addEventListener(key.slice(2), value);
      else el.setAttribute(key, value === true ? "" : value);
    }
    for (const child of children.flat()) {
      if (child === null || child === undefined || child === false) continue;
      el.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return el;
  }

  /// The post an action bar belongs to: the new app's post block, rweb's
  /// article (its own timestamp, not a quoted post's), or on a post's own
  /// page the post whose timestamp links to that page. `anchor` and `attr`
  /// name the permalink it was read from, to tell later that it's unchanged.
  function postOfBar(bar) {
    let block = null;
    for (let b = bar.closest(POST_BLOCK); b; b = b.parentElement && b.parentElement.closest(POST_BLOCK)) block = b;
    if (block) {
      const post = M.postPath(block.getAttribute("data-href"));
      return post && { ...post, container: block, anchor: block, attr: "data-href" };
    }
    const article = bar.closest("article");
    if (article) {
      for (const a of article.querySelectorAll('a[href*="/status/"]')) {
        if (!a.querySelector("time")) continue;
        const quoted = a.parentElement && a.parentElement.closest('[role="link"]');
        if (quoted && article.contains(quoted)) continue;
        const post = M.postPath(a.getAttribute("href"));
        if (post) return { ...post, container: article, anchor: a, attr: "href" };
      }
      return null;
    }
    let el = bar.parentElement;
    for (let depth = 0; el && el !== document.body && depth < 8; depth += 1, el = el.parentElement) {
      for (const a of el.querySelectorAll('a[aria-current="page"][href*="/status/"]')) {
        if (a.closest(POST_BLOCK)) continue;
        const post = M.postPath(a.getAttribute("href"));
        if (post && window.location.pathname.startsWith(`/${post.handle}/status/${post.id}`)) {
          return { ...post, container: el, anchor: a, attr: "href" };
        }
      }
    }
    return null;
  }

  /// The views count beside a post: in its bar, or on a post's own page the
  /// "Views" line under it.
  function viewsControl(bar, container, id) {
    const inBar =
      bar.querySelector('a[href$="/analytics"]') ||
      (bar.querySelector('use[href*="bar-chart"]') && bar.querySelector('use[href*="bar-chart"]').closest("a, button"));
    if (inBar) return inBar;
    if (!container) return null;
    const own = container.querySelector(`a[href$="/status/${id}/analytics"]`);
    if (own && !own.closest(BAR)) return own;
    for (const a of container.querySelectorAll(`a[href$="/status/${id}"]`)) {
      if (!a.querySelector("time") && /\bviews?\b/i.test(a.textContent || "")) return a;
    }
    return null;
  }

  /// The child of the bar holding `control`, or for the views line under a
  /// post, the line itself: the stretch the control's additions may use.
  function slotOf(control, bar) {
    if (!bar.contains(control)) return control.parentElement;
    let el = control;
    while (el.parentElement && el.parentElement !== bar) el = el.parentElement;
    return el;
  }

  function controlsOf(bar, post) {
    const controls = {};
    for (const [kind, selector] of Object.entries(CONTROLS)) {
      const found = bar.querySelector(selector);
      const control = found && (found.matches("button, a") ? found : found.querySelector("button, a") || found);
      if (control) controls[kind] = control;
    }
    const views = viewsControl(bar, post.container, post.id);
    if (views) controls.views = views;
    return controls;
  }

  /// A post's counts as X labels them right now.
  function readCounts(st) {
    const labels = {};
    for (const kind of M.KINDS) {
      const control = st.controls[kind];
      labels[kind] = control ? control.getAttribute("aria-label") || control.textContent || "" : null;
    }
    const counts = M.readCounts(st.bar.getAttribute("aria-label"), labels);
    if (counts.views == null && st.controls.views) {
      const text = (st.controls.views.textContent || "").trim();
      if (/^\d[\d,.\s]*$/.test(text.split(/\s/)[0] || "")) counts.views = M.leadingCount(text);
    }
    return counts;
  }

  function postState(id) {
    let p = posts.get(id);
    if (!p) {
      p = {
        id,
        handle: null,
        counts: null,
        baseline: undefined,
        glance: {},
        fetchedAt: {},
        loading: false,
        retryAt: 0,
        problem: null,
        lists: {},
        held: {},
        again: false,
        checkedAt: 0,
        countsAtCheck: null,
        recheck: false,
        rechecks: 0,
        recheckTimer: 0,
        sentCounts: null,
        refreshing: [],
        storedRead: false,
      };
      posts.set(id, p);
    }
    return p;
  }

  /// Takes the user's last look at a post as the point its rises are
  /// counted from, once, before this look replaces it.
  function takeBaseline(p) {
    if (p.baseline !== undefined || !seenLoaded) return;
    p.baseline = seen[p.id] ? JSON.parse(JSON.stringify(seen[p.id])) : null;
  }

  const nearObserver = new IntersectionObserver(onNear, { rootMargin: "700px 0px" });
  const seenObserver = new IntersectionObserver(onSeen, { threshold: [0, 0.6] });
  const resizeObserver = new ResizeObserver((entries) => {
    for (const entry of entries) {
      const st = bars.get(entry.target);
      if (st) st.sig = "";
    }
    schedulePass();
  });

  function onNear(entries) {
    for (const entry of entries) {
      const st = bars.get(entry.target);
      if (!st) continue;
      st.near = entry.isIntersecting;
      if (st.near) want(st.id);
    }
  }

  /// Each bar counts as a look at its post once it has stayed mostly in
  /// view for a moment, on its own timer, so a second copy of the post
  /// (someone's repost of it) scrolling by doesn't cancel the first's.
  function onSeen(entries) {
    for (const entry of entries) {
      const st = bars.get(entry.target);
      if (!st) continue;
      clearTimeout(st.seenTimer);
      if (entry.intersectionRatio >= 0.6 && document.visibilityState === "visible") {
        st.seenTimer = setTimeout(() => commitSeen(postState(st.id)), SEEN_AFTER_MS);
      }
    }
  }

  /// Remembers what the user has now seen of a post, for the next look.
  function commitSeen(p) {
    if (!seenLoaded || !p.counts || document.visibilityState !== "visible") return;
    takeBaseline(p);
    const analytics = p.glance.analytics ? analyticsCounts(p.glance.analytics) : (seen[p.id] && seen[p.id].a) || null;
    seen = M.remember(seen, p.id, { t: Date.now(), c: p.counts, a: analytics }, MAX_SEEN);
    clearTimeout(seenWrite);
    seenWrite = setTimeout(writeSeen, 1500);
  }

  /// Writes this tab's looks over what's stored, keeping any look another
  /// tab made since, so no tab's looks are lost to another's write.
  async function writeSeen() {
    try {
      const { insightsSeen } = await chrome.storage.local.get("insightsSeen");
      seen = M.mergeSeen(insightsSeen, seen, MAX_SEEN);
      await chrome.storage.local.set({ insightsSeen: seen });
    } catch (_) {}
  }

  function analyticsCounts(a) {
    return {
      impressions: a.impressions,
      engagements: a.engagements,
      detail_expands: a.detail_expands,
      profile_visits: a.profile_visits,
      link_clicks: a.link_clicks,
      follows: a.follows,
    };
  }

  /// Starts tracking an own post's bar, or stops tracking one X reused.
  function track(bar, post) {
    const st = {
      bar,
      id: post.id,
      handle: post.handle,
      container: post.container,
      anchor: post.anchor,
      href: post.anchor.getAttribute(post.attr),
      attr: post.attr,
      controls: controlsOf(bar, post),
      hosts: {},
      sig: "",
      near: false,
      seenTimer: 0,
    };
    bars.set(bar, st);
    bar.setAttribute("data-unrager-insights", post.id);
    nearObserver.observe(bar);
    seenObserver.observe(bar);
    resizeObserver.observe(bar);
    const p = postState(post.id);
    p.handle = post.handle;
    takeBaseline(p);
    readStored(post.id);
    bindHover(st.controls.views, () => bars.get(bar), "overview");
    return st;
  }

  /// Whether a tracked bar still shows the post it was tracked for: the
  /// permalink it was read from is still there and unchanged.
  function samePost(st) {
    return (
      st.anchor.isConnected && st.container.contains(st.bar) && st.anchor.getAttribute(st.attr) === st.href
    );
  }

  function untrack(bar) {
    const st = bars.get(bar);
    if (!st) return;
    clearTimeout(st.seenTimer);
    for (const host of Object.values(st.hosts)) removeHost(host);
    bars.delete(bar);
    nearObserver.unobserve(bar);
    seenObserver.unobserve(bar);
    resizeObserver.unobserve(bar);
    if (bar.isConnected) bar.removeAttribute("data-unrager-insights");
    if (card.bar === bar) closeCard();
  }

  function isOwn(handle) {
    return !!(self.handle && handle && handle.toLowerCase() === self.handle.toLowerCase());
  }

  function schedulePass() {
    if (passFrame) return;
    passFrame = requestAnimationFrame(() => {
      passFrame = 0;
      pass();
    });
  }

  /// Finds the user's posts' action bars and keeps what's drawn in each in
  /// step with X: new bars are tracked, gone or reused ones dropped, and a
  /// bar whose counts or width changed is laid out again.
  function pass() {
    for (const bar of [...bars.keys()]) {
      if (!bar.isConnected) untrack(bar);
    }
    if (card.trigger && !card.trigger.isConnected && !card.pinned) closeCard();
    if (settings.off || !settings.loaded) return;
    if (!self.handle) self.handle = pageHandle();
    if (!self.handle) return;
    const now = Date.now();
    for (const bar of document.querySelectorAll(BAR)) {
      const tracked = bars.get(bar);
      if (tracked && samePost(tracked)) continue;
      const verdict = notOurs.get(bar);
      if (!tracked && verdict && verdict.handle === self.handle && now < verdict.until) continue;
      if (!bar.querySelector(CONTROLS.likes)) continue;
      const post = postOfBar(bar);
      if (tracked) {
        if (post && post.id === tracked.id) {
          tracked.anchor = post.anchor;
          tracked.attr = post.attr;
          tracked.href = post.anchor.getAttribute(post.attr);
          tracked.container = post.container;
          continue;
        }
        untrack(bar);
      }
      if (!post || !isOwn(post.handle)) {
        notOurs.set(bar, { handle: self.handle, until: post ? Infinity : now + NOT_A_POST_RECHECK_MS });
        continue;
      }
      notOurs.delete(bar);
      track(bar, post);
    }
    const dirty = [];
    let countsChanged = false;
    for (const st of bars.values()) {
      if (Object.values(st.controls).some((control) => !control.isConnected) || !st.controls.views) {
        const post = { id: st.id, container: st.container };
        const controls = controlsOf(st.bar, post);
        if (controls.views !== st.controls.views) bindHover(controls.views, () => bars.get(st.bar), "overview");
        st.controls = controls;
      }
      const p = postState(st.id);
      const counts = readCounts(st);
      const sig = `${JSON.stringify(counts)}|${st.bar.clientWidth}`;
      if (JSON.stringify(counts) !== JSON.stringify(p.counts)) {
        const before = p.counts;
        p.counts = counts;
        if (before && grew(before, counts)) want(st.id);
        if (card.id === st.id) countsChanged = true;
      }
      if (sig !== st.sig) {
        st.sig = sig;
        dirty.push(st);
      }
    }
    for (const st of dirty) draw(st);
    if (countsChanged) renderCard();
  }

  function grew(before, now) {
    return now.likes > (before.likes || 0) || now.reposts > (before.reposts || 0);
  }

  /// Every bar showing post `id`, drawn again (a post and someone's repost of
  /// it can both be on the page).
  function redraw(id) {
    for (const st of bars.values()) {
      if (st.id === id) draw(st);
    }
    if (card.id === id && card.el) renderCard();
  }

  function redrawAll() {
    for (const st of bars.values()) {
      st.sig = "";
    }
    schedulePass();
  }

  /// Whether a post is due to be asked about again: not asked yet on this
  /// page, last asked over `CHECK_EVERY_MS` ago, its counts rose since, or
  /// the server said a part was on its way. Whether X needs asking is the
  /// server's call, from its own cache; this only keeps asking the server
  /// sparse.
  function isDue(p) {
    const now = Date.now();
    if (now < p.retryAt) return false;
    if (p.recheck || !p.checkedAt) return true;
    if (p.counts && p.countsAtCheck && grew(p.countsAtCheck, p.counts)) return true;
    return now - p.checkedAt > CHECK_EVERY_MS;
  }

  /// Queues a glance at post `id`. One asked for while its glance is out is
  /// asked again once that lands.
  function want(id) {
    if (!serverReady() || settings.off) return;
    const p = postState(id);
    if (p.loading) {
      p.again = true;
      return;
    }
    if (!isDue(p)) return;
    wanted.add(id);
    scheduleFlush(FLUSH_MS);
  }

  function scheduleFlush(delay) {
    if (flushTimer) return;
    flushTimer = setTimeout(flushWanted, delay);
  }

  /// Whether any bar of the post is on or near the screen.
  function isNear(id) {
    for (const st of bars.values()) {
      if (st.id === id && st.near) return true;
    }
    return false;
  }

  /// How far the post's bar is from the middle of the screen; a post with
  /// no bar near it counts as far.
  function distance(id) {
    let best = Infinity;
    const middle = window.innerHeight / 2;
    for (const st of bars.values()) {
      if (st.id !== id || !st.near || !st.bar.isConnected) continue;
      const box = st.bar.getBoundingClientRect();
      best = Math.min(best, Math.abs(box.top + box.height / 2 - middle));
    }
    return best;
  }

  /// Sends the posts waiting to be asked about as one glance, those nearest
  /// the middle of the screen first, since the server asks X for what it
  /// lacks in that order.
  async function flushWanted() {
    flushTimer = 0;
    if (inFlight >= MAX_IN_FLIGHT) {
      scheduleFlush(FLUSH_MS * 3);
      return;
    }
    const due = [...wanted].map(postState).filter((p) => !p.loading && isDue(p));
    wanted.clear();
    const away = new Map(due.map((p) => [p.id, distance(p.id)]));
    due.sort((a, b) => away.get(a.id) - away.get(b.id));
    const batch = due.slice(0, MAX_BATCH);
    for (const p of due.slice(MAX_BATCH)) wanted.add(p.id);
    if (!batch.length) return;
    for (const p of batch) {
      p.loading = true;
      p.recheck = false;
      p.sentCounts = p.counts ? { ...p.counts } : null;
    }
    inFlight += 1;
    const answer = await send({
      type: "glances",
      parts: PARTS,
      posts: batch.map((p) => ({ id: p.id, likes: p.counts && p.counts.likes, reposts: p.counts && p.counts.reposts })),
    });
    inFlight -= 1;
    const now = Date.now();
    if (!answer.ok) noteServerProblem(answer);
    for (const p of batch) p.loading = false;
    for (const p of batch) {
      try {
        const value = answer.ok && answer.value.posts[p.id];
        if (value) apply(p, value, now);
        else setBack(p, answer.ok ? { kind: answer.value.errors[p.id] || "http" } : answer, now);
        redraw(p.id);
      } catch (e) {
        console.warn("[unrager] stats for a post failed to draw", e);
      }
      if (p.again) {
        p.again = false;
        want(p.id);
      }
    }
    if (wanted.size) scheduleFlush(0);
  }

  /// Takes in what the server said about a post, and asks again in a
  /// moment for parts it was still asking X for.
  function apply(p, value, now) {
    p.problem = null;
    p.checkedAt = now;
    p.countsAtCheck = p.sentCounts;
    for (const part of value.deferred) p.held[part] = "deferred";
    for (const part of value.failed) p.held[part] = "failed";
    for (const [part, got] of Object.entries(value.parts)) {
      delete p.held[part];
      takePart(p, part, got);
    }
    p.refreshing = value.refreshing;
    clearTimeout(p.recheckTimer);
    if (value.refreshing.length) {
      const delay = RECHECK_MS[Math.min(p.rechecks, RECHECK_MS.length - 1)];
      p.rechecks += 1;
      p.recheckTimer = setTimeout(() => {
        if (!isNear(p.id)) {
          p.rechecks = 0;
          return;
        }
        p.recheck = true;
        want(p.id);
      }, delay);
    } else {
      p.rechecks = 0;
    }
    if (value.deferred.length || value.failed.length) {
      p.retryAt = now + Math.max(15, value.retryAfter || 60) * 1000;
      scheduleRetry();
    }
  }

  /// One part of a post, unless what's held is newer.
  function takePart(p, part, got) {
    if (!got || (p.fetchedAt[part] || 0) > got.at) return;
    p.glance[part] = got.value;
    p.fetchedAt[part] = got.at;
    if (part === "likers") resetList(p, "likes", got.value);
    if (part === "reposters") resetList(p, "reposts", got.value);
  }

  function setBack(p, answer, now) {
    p.problem = answer;
    p.retryAt = now + Math.max(30, answer.retryAfter || 60) * 1000;
    scheduleRetry();
  }

  /// A failure that says the server can't answer at all: check on it again
  /// rather than with every post, in a minute, or in a few seconds when it
  /// only didn't answer (the extension's worker may just have restarted).
  function noteServerProblem(answer) {
    if (answer.kind !== "filter_only" && answer.kind !== "auth" && answer.kind !== "unreachable") return;
    server.state = answer.kind;
    clearTimeout(server.timer);
    server.timer = setTimeout(checkServer, answer.kind === "unreachable" ? 5000 : 60000);
  }

  /// Reads what the extension kept of a post on earlier visits, so its bar
  /// is drawn at once, before the server is asked anything. Posts found in
  /// one pass are read together.
  function readStored(id) {
    const p = postState(id);
    if (p.storedRead) return;
    p.storedRead = true;
    storedWanted.add(id);
    if (storedWanted.size === 1) queueMicrotask(flushStored);
  }

  async function flushStored() {
    const ids = [...storedWanted];
    storedWanted.clear();
    let stored = {};
    try {
      stored = await chrome.storage.local.get(ids.map((id) => `ins:${id}`));
    } catch (_) {}
    for (const id of ids) {
      const entry = stored[`ins:${id}`];
      if (!entry || !entry.parts) continue;
      const p = postState(id);
      for (const [part, got] of Object.entries(entry.parts)) takePart(p, part, got);
      redraw(id);
    }
  }

  /// Asks again for what was held back once the earliest wait is over.
  function scheduleRetry() {
    clearTimeout(retryTimer);
    let soonest = Infinity;
    for (const p of posts.values()) {
      if (p.retryAt > Date.now()) soonest = Math.min(soonest, p.retryAt);
    }
    if (soonest === Infinity) return;
    retryTimer = setTimeout(
      () => {
        for (const st of bars.values()) {
          if (st.near) want(st.id);
        }
        scheduleRetry();
      },
      soonest - Date.now() + 50
    );
  }

  /// A people list for the card, started from what a glance brought.
  function resetList(p, kind, page) {
    const list = p.lists[kind];
    if (list && (list.pages > 1 || list.loading)) return;
    p.lists[kind] = {
      items: page ? page.users || [] : [],
      cursor: page ? page.cursor : null,
      done: !page || !page.cursor || !(page.users || []).length,
      loading: false,
      error: null,
      pages: 1,
    };
  }

  /// What rose since the user last looked at a post, X's counts and its
  /// analytics alike.
  function risesOf(p) {
    if (!p.baseline) return {};
    const out = M.rises(p.baseline.c, p.counts || {});
    if (p.glance.analytics && p.baseline.a) Object.assign(out, M.rises(p.baseline.a, analyticsCounts(p.glance.analytics)));
    return out;
  }

  function facesOf(users, max) {
    return (users || []).filter((u) => u && u.avatar_url).slice(0, max);
  }

  /// Whether a post links out, so its link clicks are worth showing even
  /// at zero.
  function linksOut(container) {
    if (!container) return false;
    for (const a of container.querySelectorAll('a[href^="https://t.co/"], a[href^="http://t.co/"]')) {
      const nested = a.parentElement && a.parentElement.closest(POST_BLOCK + ', [role="link"]');
      if (!nested || nested === container || !container.contains(nested)) return true;
    }
    return !!container.querySelector('[data-testid="card.wrapper"]');
  }

  /// Draws a bar's additions: a rise beside each count that rose, faces
  /// beside likes and reposts, and the analytics X keeps a click away
  /// beside the views, each only as far as the gap after its count allows.
  function draw(st) {
    if (!st.bar.isConnected) return;
    const p = postState(st.id);
    const rises = risesOf(p);
    const plan = { replies: [], reposts: [], likes: [], views: [] };
    for (const kind of SLOTS) {
      const before = p.baseline && p.baseline.c ? p.baseline.c[kind] : 0;
      if (M.notable(kind, rises[kind], before) && st.controls[kind]) plan[kind].push(deltaItem(rises[kind], 1));
    }
    const likers = p.glance.likers && p.glance.likers.users;
    if (likers && likers.length && (p.counts || {}).likes !== 0) plan.likes.push(facesItem(likers, 2, "likes"));
    const reposters = p.glance.reposters && p.glance.reposters.users;
    if (reposters && reposters.length && (p.counts || {}).reposts > 0) plan.reposts.push(facesItem(reposters, 3, "reposts"));
    const a = p.glance.analytics;
    if (a) {
      const chipSlot = st.controls.views ? "views" : "likes";
      const links = linksOut(st.container);
      const rank = chipSlot === "views" ? (links ? [0.3, 0.1, 2] : [0.2, 0.4, 2]) : links ? [6, 5, 7] : [5, 6, 7];
      if (a.follows > 0) {
        plan[chipSlot].push(chipItem("follows", a.follows, `${M.full(a.follows)} new follower${a.follows === 1 ? "" : "s"} from this post`, rank[0], rises.follows));
      }
      if (a.link_clicks > 0 || links) {
        plan[chipSlot].push(chipItem("link", a.link_clicks, `${M.full(a.link_clicks)} link click${a.link_clicks === 1 ? "" : "s"}`, rank[1], rises.link_clicks));
      }
      if (a.profile_visits > 0) {
        plan[chipSlot].push(chipItem("visits", a.profile_visits, `${M.full(a.profile_visits)} profile visit${a.profile_visits === 1 ? "" : "s"} from this post`, rank[2], rises.profile_visits));
      }
    }
    for (const kind of SLOTS) place(st, kind, plan[kind]);
  }

  function deltaItem(n, priority) {
    const text = `+${M.short(n)}`;
    return {
      key: "delta",
      priority,
      widths: [textWidth(text, `700 10.5px ${FONT}`) + 7],
      render: () => h("span", { class: "delta", text }),
    };
  }

  function facesItem(users, priority, kind) {
    const faces = facesOf(users, 3);
    const widths = faces.map((_, i) => FACE + (faces.length - 1 - i) * FACE_STEP);
    return {
      key: "faces",
      priority,
      widths,
      render: (form) =>
        h(
          "span",
          { class: "faces", "data-kind": kind },
          faces.slice(0, faces.length - form).map((u, i) =>
            h("img", {
              class: "face",
              src: M.avatarAt(u.avatar_url, "normal"),
              alt: "",
              draggable: "false",
              "data-standing": M.standing(u),
              style: { zIndex: String(10 - i) },
            })
          )
        ),
    };
  }

  function chipItem(icon, n, title, priority, rise) {
    const text = M.short(n || 0);
    return {
      key: icon,
      priority,
      widths: [14 + 3 + textWidth(text, `400 13px ${FONT}`) + 2],
      render: () => h("span", { class: "chip", "data-icon": icon, title, "data-rose": rise > 0 ? "" : null }, h("span", { class: "icon", html: ICONS[icon] }), text),
    };
  }

  /// Where a control's additions start and how far they may go: just past
  /// its count (or its hover pill, when that's what ends it), up to the end
  /// of `limit` (its slot in the bar, or the post for the views line under
  /// it), centred on its icon.
  function geometry(control, limit) {
    const box = control.getBoundingClientRect();
    const svg = control.querySelector("svg");
    const icon = svg ? svg.getBoundingClientRect() : box;
    let right = svg ? icon.right : box.left;
    const walker = document.createTreeWalker(control, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.textContent.trim()) continue;
      range.selectNodeContents(node);
      const r = range.getBoundingClientRect();
      if (r.width) right = Math.max(right, r.right);
    }
    if (box.right > right && box.right - right <= 14) right = box.right;
    return {
      right,
      centerY: icon.top + icon.height / 2,
      end: limit.getBoundingClientRect().right,
      visible: box.width > 0 && box.height > 0,
    };
  }

  /// Draws one slot's additions, as many as fit, positioned over the gap
  /// after its count so X's layout never changes.
  function place(st, kind, items) {
    const control = st.controls[kind];
    const existing = st.hosts[kind];
    const drop = () => {
      if (existing) removeHost(existing);
      delete st.hosts[kind];
    };
    if (!control || !control.isConnected || !items.length) return drop();
    const slot = slotOf(control, st.bar);
    const geo = geometry(control, st.bar.contains(control) ? slot : st.container || slot);
    if (!geo.visible) return drop();
    const room = geo.end - (geo.right + LEAD) - TAIL;
    const chosen = M.fit(items, room, ITEM_GAP);
    const shown = items.filter((item) => item.key in chosen);
    if (!shown.length) return drop();
    const host = existing && existing.isConnected && existing.parentElement === slot ? existing : clusterHost(st, kind, slot);
    if (existing && existing !== host) removeHost(existing);
    st.hosts[kind] = host;
    const row = host.shadowRoot.querySelector(".row");
    const fresh = shown.map((item) => item.render(chosen[item.key]));
    const signature = fresh.map((el) => el.outerHTML).join("");
    if (row.dataset.sig !== signature) {
      row.replaceChildren(...fresh);
      row.dataset.sig = signature;
    }
    host.setAttribute("aria-label", clusterLabel(st, kind));
    applyPalette(host, st.bar);
    const parent = host.offsetParent;
    if (!parent) return;
    const box = parent.getBoundingClientRect();
    host.style.left = `${Math.round(geo.right + LEAD - box.left - parent.clientLeft + parent.scrollLeft)}px`;
    host.style.top = `${Math.round(geo.centerY - box.top - parent.clientTop + parent.scrollTop)}px`;
  }

  /// Takes a slot's additions away, and the card they opened with them
  /// unless it was pinned: the pointer can't leave what's gone.
  function removeHost(host) {
    if (card.trigger === host && !card.pinned) closeCard();
    host.remove();
  }

  /// What a screen reader says for a slot's additions.
  function clusterLabel(st, kind) {
    const p = postState(st.id);
    if (kind === "likes" || kind === "reposts") {
      const list = kind === "likes" ? p.glance.likers : p.glance.reposters;
      const names = facesOf(list && list.users, 3).map((u) => u.name || u.handle);
      const verb = kind === "likes" ? "Liked" : "Reposted";
      if (names.length) return `${verb} by ${names.join(", ")}${(p.counts || {})[kind] > names.length ? " and others" : ""}. Show who`;
    }
    return "Show this post's stats";
  }

  function clusterHost(st, kind, slot) {
    const host = document.createElement("span");
    host.className = "unrager-insights-slot";
    host.setAttribute("role", "button");
    host.setAttribute("tabindex", "0");
    host.setAttribute("aria-haspopup", "dialog");
    host.dataset.kind = kind;
    Object.assign(host.style, {
      position: "absolute",
      left: "0px",
      top: "0px",
      transform: "translateY(-50%)",
      zIndex: "1",
      display: "block",
    });
    const shadow = host.attachShadow({ mode: "open" });
    shadow.append(h("style", { text: CLUSTER_CSS }), h("span", { class: "row" }));
    for (const type of ["pointerdown", "pointerup", "mousedown", "mouseup", "dblclick"]) {
      host.addEventListener(type, (e) => e.stopPropagation());
    }
    host.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const current = [...bars.values()].find((s) => s.hosts[kind] === host);
      if (!current) return;
      if (card.pinned && card.trigger === host) closeCard();
      else openCard(current, SLOT_TAB[kind], host, true);
    });
    host.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" && e.key !== " ") return;
      e.preventDefault();
      e.stopPropagation();
      const current = [...bars.values()].find((s) => s.hosts[kind] === host);
      if (current) openCard(current, SLOT_TAB[kind], host, true, true);
    });
    bindHover(host, () => [...bars.values()].find((s) => s.hosts[kind] === host), SLOT_TAB[kind]);
    slot.append(host);
    return host;
  }

  /// Opens the card a moment after the pointer settles on `el`, and closes
  /// it a moment after the pointer leaves both, unless it was pinned open.
  function bindHover(el, stateOf, tab) {
    if (!el || hoverBound.has(el)) return;
    hoverBound.add(el);
    el.addEventListener("pointerenter", (e) => {
      if (e.pointerType === "touch" || settings.off) return;
      clearTimeout(card.closeTimer);
      clearTimeout(card.openTimer);
      if (card.pinned) return;
      card.openTimer = setTimeout(() => {
        const st = stateOf();
        if (st && st.bar.isConnected) openCard(st, tab, el, false);
      }, card.el && card.host.isConnected && !card.host.hidden ? 60 : HOVER_OPEN_MS);
    });
    el.addEventListener("pointerleave", () => {
      clearTimeout(card.openTimer);
      if (!card.pinned) scheduleClose();
    });
  }

  function scheduleClose() {
    clearTimeout(card.closeTimer);
    card.closeTimer = setTimeout(closeCard, HOVER_CLOSE_MS);
  }

  function ensureCard() {
    if (card.host && card.host.isConnected) return;
    card.host = document.createElement("div");
    card.host.id = "unrager-insights-card";
    Object.assign(card.host.style, { position: "fixed", left: "0px", top: "0px", zIndex: "2147483000" });
    card.host.hidden = true;
    card.shadow = card.host.attachShadow({ mode: "open" });
    card.el = h("div", { class: "card", role: "dialog", "aria-label": "Post stats" });
    card.shadow.append(h("style", { text: CARD_CSS }), card.el);
    card.host.addEventListener("pointerenter", () => clearTimeout(card.closeTimer));
    card.host.addEventListener("pointerleave", () => {
      if (!card.pinned) scheduleClose();
    });
    for (const type of ["pointerdown", "mousedown", "click", "keydown", "wheel"]) {
      card.host.addEventListener(type, (e) => e.stopPropagation());
    }
    card.host.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        const trigger = card.trigger;
        closeCard();
        if (trigger && trigger.isConnected && trigger.focus) trigger.focus();
      }
    });
    (document.body || root).append(card.host);
  }

  function openCard(st, tab, trigger, pinned, focus) {
    ensureCard();
    clearTimeout(card.closeTimer);
    const same = card.id === st.id && !card.host.hidden;
    const moved = card.trigger !== trigger;
    card.id = st.id;
    card.bar = st.bar;
    card.trigger = trigger;
    if (!same) {
      card.animate = !reducedMotion.matches;
      card.side = null;
      card.lens = "all";
      card.tab = tab;
    } else if (pinned || (moved && !card.pinned)) {
      if (card.tab !== tab) card.lens = "all";
      card.tab = tab;
    }
    card.pinned = pinned || (same && card.pinned);
    applyPalette(card.host, st.bar);
    card.host.hidden = false;
    want(st.id);
    renderCard();
    position();
    if (focus) {
      const first = card.shadow.querySelector('[role="tab"][aria-selected="true"]');
      if (first) first.focus();
    }
  }

  function closeCard() {
    clearTimeout(card.openTimer);
    clearTimeout(card.closeTimer);
    if (!card.host) return;
    card.host.hidden = true;
    card.id = null;
    card.bar = null;
    card.trigger = null;
    card.pinned = false;
  }

  /// Puts the card under the post's bar, or over it when there's more room
  /// above, lined up with what opened it and kept on screen.
  function position() {
    if (!card.host || card.host.hidden || !card.bar) return;
    if (!card.bar.isConnected) {
      closeCard();
      return;
    }
    const anchor = card.bar.getBoundingClientRect();
    const trigger = card.trigger && card.trigger.isConnected ? card.trigger.getBoundingClientRect() : anchor;
    const vw = document.documentElement.clientWidth;
    const vh = window.innerHeight;
    if (anchor.bottom < 0 || anchor.top > vh) {
      if (!card.pinned) closeCard();
      return;
    }
    const width = Math.min(380, vw - 16);
    card.el.style.width = `${width}px`;
    const below = vh - anchor.bottom - 16;
    const above = anchor.top - 16;
    const tabs = card.el.querySelector(".tabs");
    const body = card.el.querySelector(".body");
    const natural = Math.min((tabs ? tabs.offsetHeight : 0) + (body ? body.scrollHeight : 0), 560);
    const fits = (side) => (side === "below" ? below : above) >= Math.min(natural, 240);
    const downward = card.side && fits(card.side) ? card.side === "below" : below >= natural || below >= above;
    card.side = downward ? "below" : "above";
    const room = Math.max(160, downward ? below : above);
    card.el.style.maxHeight = `${Math.min(560, room)}px`;
    const height = Math.min(natural, room, 560);
    const left = Math.min(Math.max(8, trigger.left + trigger.width / 2 - width / 2), vw - width - 8);
    const top = downward ? anchor.bottom + 8 : Math.max(8, anchor.top - 8 - height);
    card.host.style.left = `${Math.round(left)}px`;
    card.host.style.top = `${Math.round(top)}px`;
    card.host.dataset.side = downward ? "below" : "above";
  }

  /// Opens a page of X's the way X's own links do, without reloading it.
  function navigate(path) {
    closeCard();
    if (window.location.pathname === path) return;
    history.pushState(history.state, "", path);
    window.dispatchEvent(new PopStateEvent("popstate", { state: history.state }));
  }

  /// A link inside the card: a plain click moves X to it in place, any
  /// other click (a new tab, a modifier) does what it always does.
  function link(path, attrs, ...children) {
    return h(
      "a",
      {
        ...attrs,
        href: path,
        onclick: (e) => {
          if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
          e.preventDefault();
          navigate(path);
        },
      },
      ...children
    );
  }

  function renderCard() {
    if (!card.el || card.host.hidden) return;
    const p = postState(card.id);
    const scroller = card.el.querySelector(".body");
    const keepScroll = scroller && card.el.dataset.tab === card.tab ? scroller.scrollTop : 0;
    const focused = card.shadow.activeElement;
    const focusKey = focused && focused.dataset ? focused.dataset.key : null;
    card.el.dataset.tab = card.tab;
    card.el.toggleAttribute("data-pinned", card.pinned);
    card.el.replaceChildren(tabStrip(p), h("div", { class: "body", role: "tabpanel" }, tabBody(p)));
    const body = card.el.querySelector(".body");
    body.scrollTop = keepScroll;
    if (focusKey) {
      const again = card.shadow.querySelector(`[data-key="${CSS.escape(focusKey)}"]`);
      if (again) again.focus({ preventScroll: true });
    }
    body.addEventListener("scroll", () => onBodyScroll(p), { passive: true });
    if (card.animate) {
      card.el.classList.add("enter");
      countUp(card.el);
      card.animate = false;
    } else {
      card.el.classList.remove("enter");
    }
    position();
  }

  function tabStrip(p) {
    const counts = p.counts || {};
    const quoteList = p.lists.quotes;
    const n = {
      likes: counts.likes,
      reposts: counts.reposts,
      quotes: quoteList && quoteList.done ? quoteList.items.length : null,
    };
    const strip = h("div", { class: "tabs", role: "tablist" });
    for (const [key, label] of TABS) {
      const selected = card.tab === key;
      strip.append(
        h(
          "button",
          {
            type: "button",
            role: "tab",
            "aria-selected": selected ? "true" : "false",
            tabindex: selected ? "0" : "-1",
            "data-key": `tab:${key}`,
            onclick: () => switchTab(key),
            onkeydown: (e) => {
              if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
              const i = TABS.findIndex(([k]) => k === card.tab);
              const next = TABS[(i + (e.key === "ArrowRight" ? 1 : TABS.length - 1)) % TABS.length][0];
              switchTab(next);
              const tab = card.shadow.querySelector('[role="tab"][aria-selected="true"]');
              if (tab) tab.focus();
            },
          },
          label,
          n[key] != null ? h("span", { class: "n", text: M.short(n[key]) }) : null
        )
      );
    }
    if (card.pinned) {
      strip.append(
        h("button", { type: "button", class: "x", "aria-label": "Close", "data-key": "close", html: ICONS.close, onclick: closeCard })
      );
    }
    return strip;
  }

  function switchTab(tab) {
    card.tab = tab;
    card.pinned = true;
    card.lens = "all";
    renderCard();
  }

  function tabBody(p) {
    if (card.tab === "likes") return peopleTab(p, "likes");
    if (card.tab === "reposts") return peopleTab(p, "reposts");
    if (card.tab === "quotes") return quotesTab(p);
    return overviewTab(p);
  }

  /// Why there's nothing from the server to show, when there isn't.
  function serverNote() {
    if (server.state === "filter_only") {
      return note("Who liked this and X's analytics come from unrager's full server. Turn it on with", "unrager setup --apps");
    }
    if (server.state === "other_account") return note("unrager reads X as another account than this one, so it can't see this post's analytics.");
    if (server.state === "auth") return note("unrager isn't signed in to X. Check it with", "unrager doctor");
    if (server.state === "unreachable" || server.state === "timeout") return note("unrager isn't answering, so only what X shows is here.");
    return null;
  }

  function note(text, command) {
    return h("p", { class: "note" }, text, command ? h("code", { text: command }) : null);
  }

  function overviewTab(p) {
    const a = p.glance.analytics;
    const counts = p.counts || {};
    const rises = risesOf(p);
    const since = p.baseline && p.baseline.t ? M.span(Date.now() - p.baseline.t) : null;
    const out = [];
    const figure = a ? a.impressions : counts.views;
    const rise = a ? rises.impressions : rises.views;
    out.push(
      h(
        "section",
        { class: "hero" },
        h(
          "div",
          { class: "big" },
          h("span", { class: "num count", "data-to": figure == null ? "" : String(figure), text: figure == null ? "—" : M.full(figure) }),
          h("span", { class: "cap", text: a ? "impressions" : "views" })
        ),
        a && M.engaged(a) ? h("span", { class: "pill", text: M.engaged(a) }) : null
      )
    );
    if (rise > 0 && since) out.push(h("p", { class: "since" }, h("b", { text: `+${M.full(rise)}` }), ` since you looked ${since === "now" ? "just now" : `${since} ago`}`));
    if (a) {
      const c = M.curve(a.hourly_impressions);
      if (c) out.push(chart(c));
    } else if (!serverReady()) {
      out.push(serverNote());
    } else if (p.glance.analytics === null) {
      out.push(note("X has no analytics for this post yet."));
    } else if (!p.loading && p.held.analytics === "deferred") {
      const wait = Math.max(0, p.retryAt - Date.now());
      out.push(note(`X's budget for analytics is nearly spent, so they wait until it refills, in about ${M.span(wait) === "now" ? "a minute" : M.span(wait)}.`));
    } else if (!p.loading && (p.held.analytics === "failed" || p.problem)) {
      out.push(note("X didn't send this post's analytics just now. unrager will ask again shortly."));
    } else {
      out.push(h("div", { class: "chart-skeleton" }));
    }
    out.push(tiles(a, counts, rises));
    out.push(peopleRow(p, "likes"), peopleRow(p, "reposts"));
    out.push(
      h(
        "div",
        { class: "foot" },
        h("span", { class: "fine", text: freshness(p, since) }),
        h("a", { class: "out", href: `/${p.handle}/status/${p.id}/analytics`, target: "_blank", rel: "noopener" }, "X analytics", h("span", { class: "icon", html: ICONS.out }))
      )
    );
    return out;
  }

  /// How current the card's numbers are, and what the rises count from.
  function freshness(p, since) {
    const times = Object.values(p.fetchedAt || {}).filter(Number.isFinite);
    const parts = [];
    if (p.refreshing && p.refreshing.length) parts.push("Updating…");
    else if (times.length) {
      const age = M.span(Date.now() - Math.min(...times));
      parts.push(age === "now" ? "Updated just now" : `Updated ${age} ago`);
    }
    if (since) parts.push(`rises since your look ${since === "now" ? "just now" : `${since} ago`}`);
    const text = parts.join(" · ");
    return text ? text.charAt(0).toUpperCase() + text.slice(1) + "." : "";
  }

  function tiles(a, counts, rises) {
    const list = [];
    const add = (label, value, rise) => {
      if (value == null) return;
      list.push(
        h(
          "div",
          { class: "tile" },
          h("span", { class: "num count", "data-to": String(value), text: M.full(value) }),
          h("span", { class: "label", text: label }),
          rise > 0 ? h("span", { class: "rise", text: `+${M.short(rise)}` }) : null
        )
      );
    };
    if (a) {
      add("Engagements", a.engagements, rises.engagements);
      add("Detail expands", a.detail_expands, rises.detail_expands);
      add("Profile visits", a.profile_visits, rises.profile_visits);
      add("Link clicks", a.link_clicks, rises.link_clicks);
      add("New follows", a.follows, rises.follows);
      if (a.video_views != null) add("Video views", a.video_views);
    }
    add("Replies", counts.replies, rises.replies);
    add("Bookmarks", counts.bookmarks, rises.bookmarks);
    if (!a) {
      add("Reposts", counts.reposts, rises.reposts);
      add("Likes", counts.likes, rises.likes);
    }
    if (!list.length) return null;
    while (list.length % 3) list.push(h("div", { class: "tile blank", "aria-hidden": "true" }));
    return h("div", { class: "tiles" }, list);
  }

  /// A line on the overview leading to the people who liked or reposted
  /// the post: a few faces, who they are, and how many follow the user.
  function peopleRow(p, kind) {
    const total = (p.counts || {})[kind];
    if (!total) return null;
    const list = p.lists[kind];
    const users = list ? list.items : [];
    const faces = facesOf(users, 5);
    const named = users.slice(0, 2).map((u) => u.name || `@${u.handle}`);
    const others = Math.max(0, total - named.length);
    const verb = kind === "likes" ? "Liked by" : "Reposted by";
    const t = M.tally(users);
    const followers = t.mutual + t.follower;
    const who = !named.length
      ? `${verb} ${M.full(total)}`
      : others
        ? `${verb} ${named.join(", ")} and ${M.full(others)} other${others === 1 ? "" : "s"}`
        : `${verb} ${named.join(" and ")}`;
    return h(
      "button",
      { type: "button", class: "people-row", "data-key": `row:${kind}`, onclick: () => switchTab(kind) },
      faces.length
        ? h("span", { class: "pile" }, faces.map((u, i) => h("img", { src: M.avatarAt(u.avatar_url, "normal"), alt: "", "data-standing": M.standing(u), style: { zIndex: String(10 - i) } })))
        : null,
      h(
        "span",
        { class: "who" },
        h("span", { class: "line", text: who }),
        users.length ? h("span", { class: "fine", text: followers ? `${M.full(followers)} of the first ${M.full(users.length)} follow you` : `None of the first ${M.full(users.length)} follow you` }) : null
      ),
      h("span", { class: "chev", text: "›" })
    );
  }

  /// Draws a post's first hours as bars: the peak picked out, hours along
  /// the bottom, and the hour under the pointer read out below.
  function chart(c) {
    const n = c.hourly.length;
    const W = 340;
    const H = 76;
    const step = W / n;
    const gap = Math.min(3, step * 0.22);
    const max = c.peak || 1;
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", `0 0 ${W} ${H + 16}`);
    svg.setAttribute("class", "chart");
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", `Impressions by hour. Peak of ${M.full(c.peak)} in hour ${c.peakIndex + 1}. ${c.insight}`);
    const ns = (tag, attrs) => {
      const el = document.createElementNS("http://www.w3.org/2000/svg", tag);
      for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
      return el;
    };
    const defs = ns("defs", {});
    const grad = ns("linearGradient", { id: "rise", x1: "0", y1: "0", x2: "0", y2: "1" });
    grad.append(ns("stop", { offset: "0", "stop-color": "rgb(29, 155, 240)" }), ns("stop", { offset: "1", "stop-color": "rgb(29, 155, 240)", "stop-opacity": "0.35" }));
    defs.append(grad);
    svg.append(defs);
    c.hourly.forEach((v, i) => {
      const height = v > 0 ? Math.max(2, (v / max) * (H - 4)) : 1;
      const rect = ns("rect", {
        x: (i * step + gap / 2).toFixed(2),
        y: (H - height).toFixed(2),
        width: Math.max(1, step - gap).toFixed(2),
        height: height.toFixed(2),
        rx: Math.min(2, (step - gap) / 2).toFixed(2),
        class: i === c.peakIndex ? "bar peak" : "bar",
        "data-i": String(i),
        style: `--i:${i}`,
      });
      svg.append(rect);
    });
    for (const t of M.axisTicks(n)) {
      const x = Math.min(W - 6, Math.max(6, t * step));
      svg.append(ns("text", { x: x.toFixed(1), y: String(H + 13), "text-anchor": t === 0 ? "start" : t >= n ? "end" : "middle", class: "tick" }));
      svg.lastChild.textContent = `${t}h`;
    }
    const caption = h("figcaption", { text: c.insight });
    const readout = (i) => {
      for (const rect of svg.querySelectorAll(".bar")) rect.classList.toggle("on", Number(rect.dataset.i) === i);
      caption.textContent =
        i < 0
          ? c.insight
          : `${M.hourRange(i)} · ${M.full(c.hourly[i])} impression${c.hourly[i] === 1 ? "" : "s"} · ${Math.round((c.hourly[i] / c.total) * 100)}% of the first ${n} hours`;
    };
    svg.addEventListener("pointermove", (e) => {
      const box = svg.getBoundingClientRect();
      const i = Math.min(n - 1, Math.max(0, Math.floor(((e.clientX - box.left) / box.width) * n)));
      readout(i);
    });
    svg.addEventListener("pointerleave", () => readout(-1));
    return h("figure", { class: "curve" }, svg, caption);
  }

  /// Climbs each new figure up to its value as the card opens.
  function countUp(scope) {
    const els = [...scope.querySelectorAll(".count[data-to]")].filter((el) => el.dataset.to !== "");
    if (!els.length) return;
    const start = performance.now();
    const duration = 650;
    const step = (now) => {
      const t = Math.min(1, (now - start) / duration);
      const ease = 1 - Math.pow(1 - t, 3);
      for (const el of els) {
        if (!el.isConnected) continue;
        el.textContent = M.full(Math.round(Number(el.dataset.to) * ease));
      }
      if (t < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  function peopleTab(p, kind) {
    const total = (p.counts || {})[kind] || 0;
    const list = p.lists[kind];
    if (!list && serverReady()) loadPeople(p, kind);
    if (!serverReady() && !list) return [serverNote() || note("Nobody yet.")];
    const users = list ? list.items : [];
    const out = [];
    const t = M.tally(users);
    if (users.length) out.push(standingBar(t, total, kind));
    const lenses = LENSES.filter(([key]) => key === "all" || key === card.lens || M.lens(users, key).length);
    if (users.length >= 6 && lenses.length > 2) {
      out.push(
        h(
          "div",
          { class: "lenses", role: "group", "aria-label": "Show" },
          lenses.map(([key, label]) =>
            h(
              "button",
              {
                type: "button",
                class: "lens",
                "aria-pressed": card.lens === key ? "true" : "false",
                "data-key": `lens:${key}`,
                onclick: () => {
                  card.lens = key;
                  renderCard();
                },
              },
              label,
              key === "all" ? null : h("span", { class: "n", text: String(M.lens(users, key).length) })
            )
          )
        )
      );
    }
    const shown = M.lens(users, card.lens);
    const ul = h("ul", { class: "people" });
    for (const user of shown) ul.append(personRow(p, user));
    if (list && list.loading && !users.length) for (let i = 0; i < 5; i++) ul.append(h("li", { class: "skeleton" }, h("span"), h("span")));
    out.push(ul);
    const empty = !users.length
      ? list && list.done
        ? total
          ? "X didn't list anyone."
          : "Nobody yet."
        : null
      : !shown.length && list && (list.done || list.pages >= 10)
        ? "Nobody here among those listed."
        : null;
    out.push(listFoot(p, kind, list, empty));
    if (list && !list.loading && !list.done && !list.error && card.lens !== "all" && shown.length < 8 && list.pages < 10) {
      loadPeople(p, kind);
    }
    return out;
  }

  /// One stacked bar of how the people listed stand with the user, with a
  /// legend of the standings present.
  function standingBar(t, total, kind) {
    const parts = [
      ["mutual", t.mutual, "mutual"],
      ["follower", t.follower, "follow you"],
      ["following", t.following, "you follow"],
      ["none", t.none, "neither"],
    ].filter(([, n]) => n > 0);
    const listed = t.total < total ? `${M.full(t.total)} of ${M.full(total)} listed` : `${M.full(t.total)} ${kind === "likes" ? "liked" : "reposted"}`;
    return h(
      "div",
      { class: "standing" },
      h(
        "div",
        { class: "stack" },
        parts.map(([key, n]) => h("span", { class: "seg", "data-standing": key, style: { flexGrow: String(n) }, title: `${n} ${key}` }))
      ),
      h(
        "div",
        { class: "legend" },
        parts.filter(([key]) => key !== "none").map(([key, n, label]) => h("span", { class: "key", "data-standing": key }, h("i"), `${M.full(n)} ${label}`)),
        h("span", { class: "fine", text: listed })
      )
    );
  }

  function personRow(p, user) {
    const standing = M.standing(user);
    const followBack = user.follows_me === true && user.followed_by_me !== true;
    const following = followState.get(user.rest_id);
    return h(
      "li",
      { class: "person" },
      link(
        `/${user.handle}`,
        { class: "who", "data-key": `person:${user.rest_id}` },
        h("img", { class: "avatar", src: M.avatarAt(user.avatar_url, "bigger"), alt: "", loading: "lazy", "data-standing": standing }),
        h(
          "span",
          { class: "names" },
          h(
            "span",
            { class: "name" },
            h("span", { class: "nm", text: user.name || user.handle }),
            user.verified ? h("span", { class: "badge", html: ICONS.verified }) : null
          ),
          h("span", { class: "handle", text: `@${user.handle}${user.followers ? ` · ${M.short(user.followers)} followers` : ""}` })
        )
      ),
      followBack
        ? h(
            "button",
            {
              type: "button",
              class: "follow",
              "data-key": `follow:${user.rest_id}`,
              disabled: following === "busy",
              onclick: (e) => followUser(e, user),
            },
            FOLLOW_LABEL[following] || "Follow back"
          )
        : STANDING_LABEL[standing]
          ? h("span", { class: "tag", "data-standing": standing, text: STANDING_LABEL[standing] })
          : null
    );
  }

  /// Follows someone back from the card. Only the user's own click does:
  /// a click a page script makes up is ignored. Where it stands lives
  /// outside the row, so the card can redraw while the follow is out.
  async function followUser(e, user) {
    if (!e.isTrusted || followState.get(user.rest_id) === "busy") return;
    followState.set(user.rest_id, "busy");
    renderCard();
    const answer = await send({ type: "follow", userId: user.rest_id });
    if (answer.ok) {
      followState.delete(user.rest_id);
      user.followed_by_me = true;
      renderCard();
      return;
    }
    followState.set(user.rest_id, answer.kind === "rate_limited" ? "later" : "failed");
    renderCard();
    setTimeout(() => {
      if (followState.get(user.rest_id) === "busy") return;
      followState.delete(user.rest_id);
      renderCard();
    }, 2200);
  }

  function listFoot(p, kind, list, empty) {
    if (empty) return h("p", { class: "empty", text: empty });
    if (!list) return null;
    if (list.error) {
      const wait = list.error.retryAfter ? ` X asks to wait ${M.span(list.error.retryAfter * 1000)}.` : "";
      return h(
        "p",
        { class: "empty" },
        `Couldn't load more.${wait} `,
        h(
          "button",
          { type: "button", class: "retry", "data-key": "retry", onclick: () => (kind === "quotes" ? loadQuotes(p) : loadPeople(p, kind)) },
          "Try again"
        )
      );
    }
    if (list.loading && list.items.length) return h("p", { class: "loading" }, h("span", { class: "spinner" }));
    return null;
  }

  function onBodyScroll(p) {
    const body = card.el && card.el.querySelector(".body");
    if (!body || body.scrollHeight - body.scrollTop - body.clientHeight > 160) return;
    if (card.tab === "likes" || card.tab === "reposts") loadPeople(p, card.tab);
    if (card.tab === "quotes") loadQuotes(p);
  }

  /// The next page of who liked or reposted the post (the first, when no
  /// glance brought one), asked for directly: the user is looking at it.
  async function loadPeople(p, kind) {
    const list = p.lists[kind] || (p.lists[kind] = { items: [], cursor: null, done: false, loading: false, error: null, pages: 0 });
    if (list.loading || list.done || !serverReady()) return;
    list.loading = true;
    list.error = null;
    if (card.id === p.id) queueMicrotask(renderCard);
    const answer = await send({ type: "people", kind: kind === "likes" ? "likers" : "reposters", id: p.id, cursor: list.cursor });
    list.loading = false;
    if (!answer.ok) {
      list.error = answer;
    } else {
      const page = answer.value || { users: [] };
      const known = new Set(list.items.map((u) => u.rest_id));
      const fresh = (page.users || []).filter((u) => !known.has(u.rest_id));
      list.items.push(...fresh);
      list.cursor = page.cursor;
      list.pages += 1;
      list.done = !page.cursor || !fresh.length;
    }
    if (card.id === p.id) renderCard();
  }

  function quotesTab(p) {
    const list = p.lists.quotes;
    if (!list && serverReady()) loadQuotes(p);
    if (!serverReady() && !list) return [serverNote()];
    const items = list ? list.items : [];
    const ul = h("ul", { class: "quotes" });
    for (const t of items) {
      const author = t.author || {};
      const path = `/${author.handle}/status/${t.rest_id}`;
      ul.append(
        h(
          "li",
          { class: "quote" },
          link(
            path,
            { class: "q", "data-key": `quote:${t.rest_id}` },
            h("img", { class: "avatar", src: M.avatarAt(author.avatar_url, "bigger"), alt: "", loading: "lazy", "data-standing": M.standing(author) }),
            h(
              "span",
              { class: "q-main" },
              h(
                "span",
                { class: "q-head" },
                h("span", { class: "nm", text: author.name || author.handle }),
                author.verified ? h("span", { class: "badge", html: ICONS.verified }) : null,
                h("span", { class: "handle", text: ` @${author.handle} · ${M.span(Date.now() - Date.parse(t.created_at))}` })
              ),
              h("span", { class: "q-text", text: t.text }),
              h("span", { class: "q-meta", text: [t.like_count ? `${M.short(t.like_count)} likes` : null, t.view_count ? `${M.short(t.view_count)} views` : null].filter(Boolean).join(" · ") })
            )
          )
        )
      );
    }
    if (list && list.loading && !items.length) for (let i = 0; i < 3; i++) ul.append(h("li", { class: "skeleton tall" }, h("span"), h("span")));
    return [ul, listFoot(p, "quotes", list, list && list.done && !items.length ? "Nobody has quoted this post." : null)];
  }

  /// The posts quoting this one, newest first. X finds them with a search,
  /// whose budget is small, so they're only asked for once the tab opens.
  async function loadQuotes(p) {
    const list = p.lists.quotes || (p.lists.quotes = { items: [], cursor: null, done: false, loading: false, error: null, pages: 0 });
    if (list.loading || list.done || !serverReady()) return;
    list.loading = true;
    list.error = null;
    if (card.id === p.id) queueMicrotask(renderCard);
    const answer = await send({ type: "quotes", id: p.id, cursor: list.cursor });
    list.loading = false;
    if (!answer.ok) {
      list.error = answer;
    } else {
      const page = answer.value || { tweets: [] };
      const known = new Set(list.items.map((t) => t.rest_id));
      const fresh = (page.tweets || []).filter((t) => !known.has(t.rest_id) && t.rest_id !== p.id);
      list.items.push(...fresh);
      list.cursor = page.cursor;
      list.pages += 1;
      list.done = !page.cursor || !(page.tweets || []).length;
    }
    if (card.id === p.id) renderCard();
  }

  /// Drops everything drawn, for when the user turns the stats off.
  function teardown() {
    closeCard();
    for (const bar of [...bars.keys()]) untrack(bar);
  }

  function onMutations(mutations) {
    for (const m of mutations) {
      const target = m.target;
      if (target instanceof Element && target.classList.contains("unrager-insights-slot")) continue;
      if (m.type === "childList") {
        const ours = [...m.addedNodes, ...m.removedNodes].every(
          (n) => n instanceof Element && (n.classList.contains("unrager-insights-slot") || n.id === "unrager-insights-card")
        );
        if (ours && (m.addedNodes.length || m.removedNodes.length)) continue;
      }
      schedulePass();
      return;
    }
  }

  const CLUSTER_CSS = `
    :host { all: initial; font-family: ${FONT}; cursor: pointer; -webkit-tap-highlight-color: transparent; }
    :host(:focus-visible) { outline: 2px solid rgb(29, 155, 240); outline-offset: 3px; border-radius: 10px; }
    .row { display: flex; align-items: center; gap: ${ITEM_GAP}px; height: 20px; white-space: nowrap; }
    .delta { display: inline-flex; align-items: center; height: 15px; padding: 0 3.5px; border-radius: 7.5px;
      font: 700 10.5px/15px ${FONT}; color: rgb(0, 186, 124); background: rgba(0, 186, 124, 0.14);
      font-variant-numeric: tabular-nums; animation: pop 420ms cubic-bezier(0.2, 1.5, 0.4, 1) both; }
    .faces { display: inline-flex; align-items: center; height: 20px; }
    .face { width: ${FACE}px; height: ${FACE}px; border-radius: 50%; object-fit: cover; background: var(--line);
      margin-left: ${FACE_STEP - FACE}px; box-shadow: 0 0 0 1.5px var(--bg); position: relative;
      transition: transform 180ms cubic-bezier(0.2, 0.9, 0.3, 1.2); animation: face-in 360ms cubic-bezier(0.2, 1.3, 0.4, 1) both; }
    .face:first-child { margin-left: 0; }
    .face:nth-child(2) { animation-delay: 50ms; }
    .face:nth-child(3) { animation-delay: 100ms; }
    .face[data-standing="mutual"] { box-shadow: 0 0 0 1.5px var(--bg), 0 0 0 3px rgb(20, 184, 166); }
    .face[data-standing="follower"] { box-shadow: 0 0 0 1.5px var(--bg), 0 0 0 3px rgb(245, 158, 11); }
    .row:hover .face:nth-child(2) { transform: translateX(2px); }
    .row:hover .face:nth-child(3) { transform: translateX(4px); }
    .row:hover .face:first-child { transform: scale(1.06); }
    .chip { display: inline-flex; align-items: center; gap: 3px; font: 400 13px/16px ${FONT}; color: var(--sub);
      font-variant-numeric: tabular-nums; transition: color 150ms; }
    .chip .icon { display: inline-flex; width: 14px; height: 14px; }
    .chip svg { width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }
    .chip[data-icon="follows"] { color: rgb(0, 186, 124); }
    .chip[data-rose]::after { content: ""; width: 5px; height: 5px; border-radius: 50%; background: rgb(0, 186, 124); margin-left: 1px; align-self: flex-start; margin-top: 2px; }
    .row:hover .chip { color: rgb(29, 155, 240); }
    @keyframes pop { from { transform: scale(0.4); opacity: 0; } to { transform: none; opacity: 1; } }
    @keyframes face-in { from { transform: translateX(-6px) scale(0.6); opacity: 0; } to { transform: none; opacity: 1; } }
    @media (prefers-reduced-motion: reduce) { .delta, .face { animation: none; } .face { transition: none; } }
  `;

  const CARD_CSS = `
    :host { all: initial; }
    :host([hidden]) { display: none; }
    * { box-sizing: border-box; }
    .card { font-family: ${FONT}; color: var(--fg); background: var(--bg); border-radius: 16px; box-shadow: var(--shadow);
      overflow: hidden; display: flex; flex-direction: column; font-size: 15px; line-height: 20px;
      -webkit-font-smoothing: antialiased; }
    .card.enter { animation: card-in 170ms cubic-bezier(0.2, 0.9, 0.3, 1) both; }
    :host([data-side="above"]) .card.enter { animation-name: card-in-up; }
    @keyframes card-in { from { opacity: 0; transform: translateY(-6px) scale(0.98); } to { opacity: 1; transform: none; } }
    @keyframes card-in-up { from { opacity: 0; transform: translateY(6px) scale(0.98); } to { opacity: 1; transform: none; } }
    .tabs { display: flex; align-items: stretch; border-bottom: 1px solid var(--line); flex: none; padding: 0 4px; }
    .tabs [role="tab"] { all: unset; flex: 1 1 auto; text-align: center; cursor: pointer; padding: 13px 6px 11px;
      font: 500 14px/18px ${FONT}; color: var(--sub); border-bottom: 3px solid transparent; white-space: nowrap; transition: color 120ms, background 120ms; }
    .tabs [role="tab"]:hover { background: var(--wash); color: var(--fg); }
    .tabs [role="tab"][aria-selected="true"] { color: var(--fg); font-weight: 700; border-bottom-color: rgb(29, 155, 240); }
    .tabs [role="tab"]:focus-visible { outline: 2px solid rgb(29, 155, 240); outline-offset: -2px; border-radius: 6px; }
    .tabs .n { font-weight: 400; color: var(--sub); margin-left: 4px; font-variant-numeric: tabular-nums; }
    .tabs .x { all: unset; cursor: pointer; width: 32px; display: grid; place-items: center; color: var(--sub); border-radius: 50%; margin: 6px 2px 6px 0; }
    .tabs .x:hover { background: var(--wash); color: var(--fg); }
    .tabs .x svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; }
    .body { overflow-y: auto; overscroll-behavior: contain; padding: 14px 16px 12px; flex: 1 1 auto; scrollbar-width: thin; }
    .hero { display: flex; align-items: flex-end; justify-content: space-between; gap: 12px; }
    .big { display: flex; flex-direction: column; }
    .big .num { font: 800 30px/34px ${FONT}; letter-spacing: -0.5px; font-variant-numeric: tabular-nums; }
    .big .cap { font-size: 13px; color: var(--sub); }
    .pill { font: 600 12px/16px ${FONT}; color: rgb(29, 155, 240); background: rgba(29, 155, 240, 0.12); padding: 4px 9px; border-radius: 999px; white-space: nowrap; margin-bottom: 4px; }
    .since { margin: 6px 0 0; font-size: 13px; color: var(--sub); }
    .since b { color: rgb(0, 186, 124); font-weight: 700; }
    .curve { margin: 12px 0 2px; }
    .chart { display: block; width: 100%; height: auto; cursor: crosshair; touch-action: none; }
    .chart .bar { fill: url(#rise); transform-box: fill-box; transform-origin: bottom; transition: opacity 120ms; }
    .chart .bar.peak { fill: rgb(29, 155, 240); }
    .chart:hover .bar { opacity: 0.45; }
    .chart .bar.on { opacity: 1; fill: rgb(29, 155, 240); }
    .card.enter .chart .bar { animation: bar-in 520ms cubic-bezier(0.2, 0.9, 0.3, 1) both; animation-delay: calc(var(--i) * 9ms); }
    @keyframes bar-in { from { transform: scaleY(0); } to { transform: scaleY(1); } }
    .chart .tick { font: 400 10px ${FONT}; fill: var(--sub); }
    figcaption { font-size: 13px; line-height: 17px; color: var(--sub); margin-top: 4px; min-height: 17px; font-variant-numeric: tabular-nums; }
    .chart-skeleton { height: 92px; margin: 12px 0 2px; border-radius: 8px; background: var(--wash); animation: pulse 1.2s ease-in-out infinite; }
    @keyframes pulse { 50% { opacity: 0.45; } }
    .tiles { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1px; background: var(--line); border: 1px solid var(--line);
      border-radius: 12px; overflow: hidden; margin: 14px 0 6px; }
    .tile { background: var(--bg); padding: 9px 10px 8px; display: flex; flex-direction: column; position: relative; min-width: 0; }
    .tile .num { font: 700 17px/22px ${FONT}; font-variant-numeric: tabular-nums; }
    .tile .label { font-size: 12px; line-height: 15px; color: var(--sub); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .tile .rise { position: absolute; top: 8px; right: 8px; font: 700 11px/14px ${FONT}; color: rgb(0, 186, 124); }
    .people-row { all: unset; box-sizing: border-box; cursor: pointer; display: flex; align-items: center; gap: 10px; width: 100%;
      padding: 9px 8px; margin: 2px -8px 0; width: calc(100% + 16px); border-radius: 12px; transition: background 120ms; }
    .people-row:hover { background: var(--wash); }
    .people-row:focus-visible { outline: 2px solid rgb(29, 155, 240); outline-offset: -2px; }
    .pile { display: inline-flex; flex: none; }
    .pile img { width: 26px; height: 26px; border-radius: 50%; object-fit: cover; margin-left: -9px; box-shadow: 0 0 0 2px var(--bg); background: var(--line); position: relative; }
    .pile img:first-child { margin-left: 0; }
    .who { display: flex; flex-direction: column; min-width: 0; flex: 1; }
    .who .line { font-size: 14px; line-height: 18px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .fine { font-size: 12px; line-height: 16px; color: var(--sub); }
    .chev { color: var(--sub); font-size: 20px; }
    [data-standing="mutual"] { --ring: rgb(20, 184, 166); }
    [data-standing="follower"] { --ring: rgb(245, 158, 11); }
    [data-standing="following"] { --ring: rgb(29, 155, 240); }
    [data-standing="none"] { --ring: var(--sub); }
    .pile img[data-standing="mutual"], .pile img[data-standing="follower"] { box-shadow: 0 0 0 2px var(--bg), 0 0 0 3.5px var(--ring); }
    .foot { display: flex; justify-content: space-between; align-items: center; gap: 10px; margin-top: 10px; padding-top: 10px; border-top: 1px solid var(--line); }
    .out { display: inline-flex; align-items: center; gap: 4px; color: rgb(29, 155, 240); text-decoration: none; font: 500 13px/16px ${FONT}; white-space: nowrap; }
    .out:hover { text-decoration: underline; }
    .out svg, .out .icon { width: 14px; height: 14px; display: inline-flex; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
    .note { margin: 12px 0 4px; font-size: 13px; line-height: 18px; color: var(--sub); }
    .note code { display: inline-block; margin-left: 4px; font: 12px/16px ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--fg); background: var(--wash); padding: 1px 6px; border-radius: 6px; }
    .standing { margin-bottom: 10px; }
    .stack { display: flex; height: 8px; border-radius: 4px; overflow: hidden; gap: 2px; background: var(--wash); }
    .seg { background: var(--ring); min-width: 4px; transition: flex-grow 400ms; }
    .card.enter .seg { animation: grow 600ms cubic-bezier(0.2, 0.9, 0.3, 1) both; transform-origin: left; }
    @keyframes grow { from { transform: scaleX(0); } to { transform: none; } }
    .legend { display: flex; flex-wrap: wrap; gap: 4px 12px; margin-top: 7px; font-size: 12px; line-height: 16px; color: var(--sub); align-items: center; }
    .legend .key { display: inline-flex; align-items: center; gap: 5px; color: var(--fg); }
    .legend .key i { width: 8px; height: 8px; border-radius: 50%; background: var(--ring); }
    .legend .fine { margin-left: auto; }
    .lenses { display: flex; gap: 6px; overflow-x: auto; padding-bottom: 8px; margin: 0 -16px 2px; padding-left: 16px; padding-right: 16px; scrollbar-width: none;
      mask-image: linear-gradient(to right, transparent 0, #000 14px, #000 calc(100% - 28px), transparent); }
    .lens { all: unset; cursor: pointer; flex: none; font: 500 13px/16px ${FONT}; padding: 6px 11px; border-radius: 999px;
      border: 1px solid var(--line); color: var(--fg); transition: background 120ms, border-color 120ms; }
    .lens:hover { background: var(--wash); }
    .lens[aria-pressed="true"] { background: var(--fg); color: var(--bg); border-color: var(--fg); }
    .lens .n { margin-left: 5px; opacity: 0.6; font-variant-numeric: tabular-nums; }
    .lens:focus-visible, .follow:focus-visible, .retry:focus-visible, .who:focus-visible, .q:focus-visible { outline: 2px solid rgb(29, 155, 240); outline-offset: 2px; }
    ul { list-style: none; margin: 0; padding: 0; }
    .person { display: flex; align-items: center; gap: 10px; padding: 7px 0; }
    .person .who { flex-direction: row; align-items: center; gap: 10px; text-decoration: none; color: inherit; min-width: 0; }
    .avatar { width: 40px; height: 40px; border-radius: 50%; object-fit: cover; flex: none; background: var(--line); }
    .avatar[data-standing="mutual"], .avatar[data-standing="follower"], .avatar[data-standing="following"] { box-shadow: 0 0 0 2px var(--bg), 0 0 0 4px var(--ring); }
    .names { display: flex; flex-direction: column; min-width: 0; }
    .name { display: flex; align-items: center; gap: 2px; min-width: 0; }
    .nm { font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .person .who:hover .nm, .q:hover .nm { text-decoration: underline; }
    .handle { color: var(--sub); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 14px; }
    .badge { display: inline-flex; flex: none; }
    .badge svg { width: 17px; height: 17px; fill: rgb(29, 155, 240); }
    .badge .check { fill: #fff; }
    .tag { margin-left: auto; flex: none; font: 600 12px/16px ${FONT}; padding: 3px 8px; border-radius: 6px; color: var(--ring);
      background: color-mix(in srgb, var(--ring) 14%, transparent); }
    .follow { all: unset; cursor: pointer; margin-left: auto; flex: none; font: 700 14px/18px ${FONT}; padding: 6px 14px; border-radius: 999px; background: var(--fg); color: var(--bg); transition: opacity 120ms; }
    .follow:hover { opacity: 0.85; }
    .follow:disabled { opacity: 0.6; cursor: default; }
    .skeleton { display: flex; gap: 10px; align-items: center; padding: 8px 0; }
    .skeleton span:first-child { width: 40px; height: 40px; border-radius: 50%; background: var(--wash); flex: none; }
    .skeleton span:last-child { height: 12px; flex: 1; border-radius: 6px; background: var(--wash); }
    .skeleton.tall span:last-child { height: 44px; }
    .skeleton span { animation: pulse 1.2s ease-in-out infinite; }
    .empty { color: var(--sub); font-size: 14px; margin: 10px 0; }
    .retry { all: unset; cursor: pointer; color: rgb(29, 155, 240); font-weight: 600; }
    .loading { display: flex; justify-content: center; margin: 8px 0; }
    .spinner { width: 20px; height: 20px; border-radius: 50%; border: 2.5px solid rgba(29, 155, 240, 0.2); border-top-color: rgb(29, 155, 240); animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .quote { padding: 8px 0; border-bottom: 1px solid var(--line); }
    .quote:last-child { border-bottom: 0; }
    .q { display: flex; gap: 10px; text-decoration: none; color: inherit; }
    .q-main { display: flex; flex-direction: column; min-width: 0; gap: 2px; }
    .q-head { display: flex; align-items: center; gap: 2px; min-width: 0; }
    .q-head .handle { font-size: 14px; }
    .q-text { white-space: pre-wrap; word-break: break-word; display: -webkit-box; -webkit-line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden; font-size: 14px; line-height: 19px; }
    .q-meta { font-size: 12px; color: var(--sub); }
    @media (prefers-reduced-motion: reduce) {
      .card.enter, .card.enter .chart .bar, .card.enter .seg { animation: none; }
      .chart-skeleton, .skeleton span, .spinner { animation: none; }
    }
  `;

  chrome.storage.local.get(["insightsOff", "insightsSeen", "insightsSelf"]).then(
    (stored) => {
      settings.off = !!stored.insightsOff;
      settings.loaded = true;
      seen = stored.insightsSeen || {};
      seenLoaded = true;
      self.id = cookieSelfId();
      if (stored.insightsSelf && stored.insightsSelf.id === self.id) {
        self.handle = stored.insightsSelf.handle;
        if (server.state === "unknown") server.state = "ok";
      }
      for (const p of posts.values()) takeBaseline(p);
      checkServer();
      schedulePass();
    },
    () => {
      settings.loaded = true;
      seenLoaded = true;
    }
  );

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    if (changes.insightsSeen && seenLoaded) seen = M.mergeSeen(changes.insightsSeen.newValue, seen, MAX_SEEN);
    if (!changes.insightsOff) return;
    settings.off = !!changes.insightsOff.newValue;
    if (settings.off) teardown();
    else {
      checkServer();
      schedulePass();
    }
  });

  new MutationObserver(onMutations).observe(root, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["aria-label"],
  });

  window.addEventListener("resize", () => {
    redrawAll();
    position();
  });
  window.addEventListener("scroll", () => position(), { passive: true, capture: true });
  document.addEventListener(
    "pointerdown",
    (e) => {
      if (!card.pinned || !card.host || card.host.hidden) return;
      const path = e.composedPath();
      if (path.includes(card.host) || (card.trigger && path.includes(card.trigger))) return;
      closeCard();
    },
    true
  );
  document.addEventListener(
    "keydown",
    (e) => {
      if (e.key === "Escape" && card.host && !card.host.hidden) closeCard();
    },
    true
  );
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
      hiddenSince = Date.now();
      for (const st of bars.values()) clearTimeout(st.seenTimer);
      return;
    }
    if (hiddenSince && Date.now() - hiddenSince > NEW_LOOK_AFTER_MS) {
      for (const p of posts.values()) p.baseline = undefined;
      for (const p of posts.values()) takeBaseline(p);
      redrawAll();
    }
    hiddenSince = 0;
    for (const st of bars.values()) {
      if (st.near) want(st.id);
    }
  });
  if (window.navigation) window.navigation.addEventListener("currententrychange", () => closeCard());
  window.addEventListener("popstate", () => closeCard());
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(redrawAll);
  setInterval(() => {
    if (document.visibilityState !== "visible") return;
    for (const st of bars.values()) {
      if (st.near) want(st.id);
    }
  }, CHECK_EVERY_MS);
})();
