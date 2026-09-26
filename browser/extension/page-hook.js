// Runs in the page's own JS world (manifest `"world": "MAIN"`), so its
// patches are the XMLHttpRequest/fetch X's bundle actually calls. It only
// observes: the response X consumes is never delayed or rewritten. Timeline
// bodies are handed to the isolated-world content script via postMessage,
// which structured-clones across worlds (a plain string, so nothing is lost).
(() => {
  const OPS = new Set(["HomeTimeline", "HomeLatestTimeline"]);
  const origin = window.location.origin;

  const opFor = (url) => {
    const m = /\/graphql\/[^/?]+\/([A-Za-z]+)/.exec(String(url || ""));
    return m && OPS.has(m[1]) ? m[1] : null;
  };

  const post = (op, body) =>
    window.postMessage({ source: "unrager-page", type: "timeline", op, body }, origin);

  // X's web client issues its GraphQL calls through XMLHttpRequest.
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

  // Kept alongside the XHR hook so a transport switch on X's side doesn't
  // silently turn the filter off.
  const origFetch = window.fetch;
  window.fetch = function (input) {
    const url =
      typeof input === "string" ? input : input instanceof URL ? input.href : input && input.url;
    const op = opFor(url);
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

  let status = { loaded: false };
  window.addEventListener("message", (e) => {
    const d = e.data;
    if (e.source === window && d && d.source === "unrager-content" && d.type === "status") {
      status = d.status;
    }
  });
  window.__unrager_status = () => status;
})();
