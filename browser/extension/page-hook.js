/// Runs in the page's own JS world (manifest `"world": "MAIN"`), so its
/// patches are the XMLHttpRequest/fetch X's bundle actually calls. It only
/// observes: the response X consumes is never rewritten.
(() => {
  const OPS = new Set(["HomeTimeline", "HomeLatestTimeline"]);

  const opFor = (url) => {
    const m = /\/graphql\/[^/?]+\/([A-Za-z]+)/.exec(String(url || ""));
    return m && OPS.has(m[1]) ? m[1] : null;
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

  /// X's web client issues its GraphQL calls through XMLHttpRequest.
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

  /// Kept alongside the XHR hook so a transport switch on X's side doesn't
  /// silently turn the filter off.
  function hookFetch() {
    const origFetch = window.fetch;
    window.fetch = function (input) {
      const url =
        typeof input === "string" ? input : input instanceof URL ? input.href : input && input.url;
      const op = opFor(url);
      if (op) loading(op);
      const pending = origFetch.apply(this, arguments);
      if (op) {
        pending
          .then((res) => (res.ok ? res.clone().text() : null))
          .then((body) => {
            if (body) post(op, body);
          })
          .catch(() => {});
      }
      return pending;
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

  hookXhr();
  hookFetch();
  exposeStatus();
})();
