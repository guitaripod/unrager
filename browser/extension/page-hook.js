/// Runs in the page's own JS world (manifest `"world": "MAIN"`), so its
/// patches are the fetch/XMLHttpRequest X's bundle actually calls. It reads
/// the response X consumes without rewriting it, and puts back the height of
/// a row the content script hides after X measured it.
(() => {
  /// X's Home timelines by the names this hook reports them under. The web
  /// app has called them `HomeTimeline`, `HomeTimelineQuery` and
  /// `HomeLatestTimelineQuery`, on x.com/i/api and on api.x.com.
  const OP = /\/graphql\/[^/?]+\/(Home(?:Latest)?Timeline)(?:Query)?(?:[/?#]|$)/;

  const opFor = (url) => {
    const m = OP.exec(String(url || ""));
    return m ? m[1] : null;
  };

  /// Hands a timeline body to the isolated-world content script. A DOM
  /// event runs every world's listeners before `dispatchEvent` returns, so
  /// the content script knows the posts before React paints them; a posted
  /// message could arrive a frame after they're already on screen. A string
  /// `detail` crosses worlds as is.
  const post = (op, body) =>
    document.dispatchEvent(new CustomEvent(`unrager:${op}`, { detail: body }));

  /// Tells the content script a timeline is on its way, so the model can
  /// load while X waits for it.
  const loading = (op) => document.dispatchEvent(new CustomEvent("unrager:loading", { detail: op }));

  /// Kept alongside the fetch hook so a transport switch on X's side doesn't
  /// silently turn the filter off.
  function hookXhr() {
    const xhrOps = new WeakMap();
    const { open, send } = XMLHttpRequest.prototype;
    XMLHttpRequest.prototype.open = function (_method, url) {
      const op = opFor(url);
      if (op) xhrOps.set(this, op);
      else xhrOps.delete(this);
      return open.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      const op = xhrOps.get(this);
      if (op) {
        loading(op);
        this.addEventListener(
          "load",
          () => {
            if (this.status < 200 || this.status >= 300) return;
            let body = null;
            try {
              if (this.responseType === "" || this.responseType === "text") body = this.responseText;
              else if (this.responseType === "json") body = JSON.stringify(this.response);
            } catch (_) {
              body = null;
            }
            if (body) post(op, body);
          },
          { once: true }
        );
      }
      return send.apply(this, arguments);
    };
  }

  /// X's web app fetches its timelines. A JSON timeline reaches X only once
  /// its body has been read here and handed on, so its posts are known
  /// before X can render them; X reads the whole body before parsing it
  /// anyway. Anything streamed is only watched, never held back.
  function hookFetch() {
    const origFetch = window.fetch;
    window.fetch = function (input) {
      const url =
        typeof input === "string" ? input : input instanceof URL ? input.href : input && input.url;
      const op = opFor(url);
      if (op) loading(op);
      const pending = origFetch.apply(this, arguments);
      if (!op) return pending;
      return pending.then((res) => {
        let read = null;
        try {
          if (res.ok) {
            read = res
              .clone()
              .text()
              .then((body) => {
                if (body) post(op, body);
              })
              .catch(() => {});
          }
        } catch (_) {
          read = null;
        }
        const json = /json/i.test(res.headers.get("content-type") || "");
        return read && json ? read.then(() => res) : res;
      });
    };
  }

  /// `window.__unrager_status()` in the page console shows what the filter
  /// did on this tab.
  function exposeStatus() {
    let status = { loaded: false };
    window.addEventListener("message", (e) => {
      const d = e.data;
      if (e.source === window && d && d.source === "unrager-content" && d.type === "status") {
        status = d.status;
      }
    });
    window.__unrager_status = () => status;
  }

  /// The rows of X's virtualized timeline list. X measures a row in the
  /// commit that adds it and keeps that height, so a post the content script
  /// hides after that measurement, and whose row leaves view before X looks
  /// again, leaves a blank stretch. The content script asks for the row to be
  /// measured again once it hides or shows a post, and X's own measurement is
  /// corrected when the row is already marked.
  const ROW = "main li[data-index]";
  const ROW_ITEM = "li[data-index]";
  const POST = '[role="link"][data-href*="/status/"]';
  const MAX_KEYS = 4000;
  const bound = { list: null, virt: null };
  const keys = new Map();

  function postsOf(row) {
    return [...row.querySelectorAll(POST)].filter((post) => !post.parentElement.closest(POST));
  }

  function postId(post) {
    const m = /\/status\/(\d+)/.exec(post.dataset.href || "");
    return m ? m[1] : null;
  }

  function rowAt(index) {
    if (!bound.list) return null;
    return bound.list.querySelector(`:scope > li[data-index="${index}"]`);
  }

  function itemKey(virt, index) {
    try {
      return String(virt.options.getItemKey(index));
    } catch (_) {
      return null;
    }
  }

  /// Remembers which list item a post's row is, so a verdict that arrives
  /// after the row has been unmounted can still correct its height.
  function learn(row, virt) {
    const key = itemKey(virt, Number(row.dataset.index));
    if (!key) return;
    for (const post of postsOf(row)) {
      const id = postId(post);
      if (!id) continue;
      keys.delete(id);
      keys.set(id, key);
    }
    while (keys.size > MAX_KEYS) keys.delete(keys.keys().next().value);
  }

  function learnAll() {
    if (!bound.list || !bound.virt) return;
    for (const row of bound.list.children) {
      if (row instanceof Element && row.matches(ROW_ITEM)) learn(row, bound.virt);
    }
  }

  /// Finds X's virtualizer through the list's React fiber. X's list is a
  /// fork of TanStack Virtual, whose `resizeItem(index, height)` is what a
  /// measurement ends in; wrapping it keeps a marked row from being cached
  /// at its unmarked height even when X measured it first.
  function virtualizerOf(list) {
    const fiberKey = Object.keys(list).find((k) => k.startsWith("__reactFiber$"));
    let fiber = fiberKey && list[fiberKey];
    while (fiber && !(fiber.memoizedProps && fiber.memoizedProps.virtualizer)) fiber = fiber.return;
    return fiber ? fiber.memoizedProps.virtualizer : null;
  }

  function wrap(virt, list) {
    if (!virt || virt.__unragerList === list) return;
    virt.__unragerList = list;
    const resize = virt.resizeItem;
    if (typeof resize !== "function") return;
    virt.resizeItem = function (index, size) {
      const row = rowAt(index);
      if (row && !row.hasAttribute("data-unrager-folding")) {
        const marked =
          row.matches('[data-unrager="hidden"], [data-unrager="held"]') ||
          !!row.querySelector('[data-unrager="hidden"], [data-unrager="held"]');
        if (marked) size = row.offsetHeight;
      }
      return resize.apply(this, arguments);
    };
  }

  function bind(refresh = false) {
    if (bound.list && bound.virt && bound.list.isConnected) {
      if (!refresh) return bound.virt;
      const virt = virtualizerOf(bound.list);
      if (virt && virt !== bound.virt) {
        bound.virt = virt;
        wrap(virt, bound.list);
        learnAll();
      }
      return bound.virt;
    }
    const first = document.querySelector(ROW);
    const list = first && first.parentElement;
    if (!list) return null;
    const virt = virtualizerOf(list);
    if (!virt) return null;
    bound.list = list;
    bound.virt = virt;
    wrap(virt, list);
    learnAll();
    return virt;
  }

  /// Puts one row's real height back into X's list. `index` is the row the
  /// content script saw; without one, the post's last row is looked up by its
  /// item key, which survives rows unmounting and the list reordering.
  function resizeRow(request) {
    const virt = bind(true);
    if (!virt) return;
    let index = Number.isInteger(request.index) ? request.index : -1;
    if (index < 0) {
      const id = request.id === null || request.id === undefined ? null : String(request.id);
      if (!id) return;
      learnAll();
      const key = keys.get(id);
      const measurements = virt.getMeasurements();
      const match = key === undefined
        ? measurements.find((m) => m && String(m.key).includes(id))
        : measurements.find((m) => m && String(m.key) === key);
      if (!match) return;
      index = match.index;
    }
    const row = rowAt(index);
    const height = row
      ? row.offsetHeight
      : Number.isFinite(request.height)
        ? request.height
        : request.hidden
          ? 1
          : null;
    if (height === null) return;
    try {
      virt.resizeItem(index, height);
    } catch (_) {}
  }

  function onRowSize(e) {
    if (typeof e.detail !== "string") return;
    let request;
    try {
      request = JSON.parse(e.detail);
    } catch (_) {
      return;
    }
    if (request && typeof request === "object") resizeRow(request);
  }

  /// Learns each row as X adds or fills it, then answers the content script's
  /// `unrager:rowsize` events.
  function hookRows() {
    new MutationObserver((mutations) => {
      for (const m of mutations) {
        for (const node of m.addedNodes) {
          if (!(node instanceof Element)) continue;
          const row = node.matches(ROW_ITEM) ? node : node.closest(ROW_ITEM);
          const rows = row ? [row] : [...node.querySelectorAll(ROW_ITEM)];
          if (!rows.length) continue;
          const virt = bind();
          if (!virt || !bound.list) continue;
          for (const added of rows) if (bound.list.contains(added)) learn(added, virt);
        }
      }
    }).observe(document, { childList: true, subtree: true });
    document.addEventListener("unrager:rowsize", onRowSize);
  }

  hookXhr();
  hookFetch();
  exposeStatus();
  hookRows();
})();
