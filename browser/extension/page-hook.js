/// Runs in the page's own JS world (manifest `"world": "MAIN"`), so its
/// patches are the fetch/XMLHttpRequest X's bundle actually calls. It only
/// observes: the response X consumes is never rewritten.
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

  hookXhr();
  hookFetch();
  exposeStatus();
})();
