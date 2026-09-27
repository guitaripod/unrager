const DEFAULT_SERVER = "http://localhost:7777";
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1"]);
const BACKEND_NAMES = { ollama: "Ollama", openai: "an OpenAI-compatible server" };
const EXTENSION_VERSION = chrome.runtime.getManifest().version;
const STRICTNESS_HINTS = {
  relaxed: "Only posts clearly about one of your topics.",
  balanced: "Your topics, plus rage bait and dunking. A post the model isn't sure about stays.",
  strict: "Also posts by people known for a topic, and anything the model isn't sure about.",
};

const $ = (id) => document.getElementById(id);

async function serverUrl() {
  const { server } = await chrome.storage.local.get("server");
  return (server || DEFAULT_SERVER).replace(/\/+$/, "");
}

async function request(url, { method = "GET", body, timeoutMs = 4000 } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      method,
      headers: body ? { "Content-Type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
    const text = await res.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch (_) {}
    if (!res.ok) throw new Error((json && json.error) || `HTTP ${res.status}`);
    return json;
  } finally {
    clearTimeout(timer);
  }
}

function hostLabel(url) {
  try {
    return new URL(url).host;
  } catch (_) {
    return url;
  }
}

/// -1, 0 or 1 comparing dotted versions, ignoring any pre-release suffix.
function compareVersions(a, b) {
  const parts = (v) => String(v).split(/[-+]/)[0].split(".").map((n) => parseInt(n, 10) || 0);
  const pa = parts(a);
  const pb = parts(b);
  for (let i = 0; i < 3; i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return Math.sign(d);
  }
  return 0;
}

/// The active tab's filter stats. `activeTab` lets the popup see the URL, so
/// an x.com tab opened before the extension loaded can be told apart from
/// every other site.
async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return { where: "elsewhere" };
  try {
    const stats = await chrome.tabs.sendMessage(tab.id, { type: "stats" });
    if (stats) return { where: "x", tab, stats };
  } catch (_) {}
  const onX = /^https:\/\/(x|twitter)\.com\//.test(tab.url || "");
  return { where: onX ? "x-stale" : "elsewhere", tab };
}

function render({ tone, headline, detail = "", fine = "", command = null, action = null }) {
  $("status").dataset.tone = tone;
  $("headline").textContent = headline;
  $("detail").textContent = detail;
  $("fine").textContent = fine;
  $("fine").hidden = !fine;
  $("command").hidden = !command;
  if (command) $("command-text").textContent = command;
  const button = $("action");
  button.hidden = !action;
  if (action) {
    button.textContent = action.label;
    button.onclick = action.run;
  }
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

function modelView(filter) {
  const backend = BACKEND_NAMES[filter.backend] || filter.backend;
  const where = hostLabel(filter.host);
  if (filter.state === "unreachable") {
    return {
      tone: "problem",
      headline: "Can't reach your model",
      detail: `unrager is running, but ${backend} at ${where} isn't answering. Start it, then check the setup with:`,
      command: "unrager doctor",
    };
  }
  if (filter.state === "model_missing") {
    return {
      tone: "problem",
      headline: "Model not found",
      detail: `${backend} at ${where} doesn't have ${filter.model}. See what to fix with:`,
      command: "unrager doctor",
    };
  }
  return null;
}

function versionView(serverVersion) {
  const order = compareVersions(serverVersion, EXTENSION_VERSION);
  if (order === 0) return null;
  if (order > 0) {
    return {
      tone: "problem",
      headline: "Finish updating",
      detail: `unrager is ${serverVersion} but this extension is still ${EXTENSION_VERSION}. Reload it; if it stays on ${EXTENSION_VERSION}, run this first:`,
      command: "unrager setup",
      action: { label: "Reload extension", run: () => chrome.runtime.reload() },
    };
  }
  return {
    tone: "problem",
    headline: "Update unrager",
    detail: `This extension is ${EXTENSION_VERSION} but unrager is still ${serverVersion}. Update it with:`,
    command: "unrager update && unrager setup",
  };
}

function tabView(tab, paused) {
  if (paused) {
    return {
      tone: "off",
      headline: "Paused",
      detail: "X shows everything until you turn filtering back on.",
    };
  }
  if (tab.where === "x-stale") {
    return {
      tone: "problem",
      headline: "Reload this tab",
      detail: "It was open before unrager was added or updated, so nothing is being filtered here yet.",
      action: { label: "Reload tab", run: () => chrome.tabs.reload(tab.tab.id).then(() => window.close()) },
    };
  }
  if (tab.where !== "x") {
    return {
      tone: "ok",
      headline: "Ready",
      detail: "Open your Home timeline on x.com. Posts that match your rules disappear as they load.",
    };
  }
  const { hidden, checked, state, lastError, shapeProblem } = tab.stats;
  if (state === "error") {
    return {
      tone: "problem",
      headline: "Posts aren't being checked",
      detail: "They stay visible while unrager can't check them. It keeps trying.",
      fine: lastError || "",
    };
  }
  if (shapeProblem && checked === 0) {
    return {
      tone: "problem",
      headline: "X changed its timeline",
      detail: "unrager can't read the posts on this page. Updating it usually fixes this:",
      fine: shapeProblem,
      command: "unrager update && unrager setup",
    };
  }
  if (checked === 0) {
    return {
      tone: "ok",
      headline: "Filtering this tab",
      detail: "Nothing checked yet. Open For you or Following on your Home timeline.",
    };
  }
  return {
    tone: "ok",
    headline: hidden === 0 ? "Nothing to hide so far" : `${plural(hidden, "post")} hidden`,
    detail: `${plural(checked, "post")} checked on this tab.`,
  };
}

let rulesLoaded = false;
/// Hidden posts per rule under the current rules, once loaded.
let hiddenByRule = null;

async function refresh() {
  const server = await serverUrl();
  const [health, tab, stored] = await Promise.all([
    request(`${server}/api/health`, { timeoutMs: 2500 }).catch(() => null),
    activeTab(),
    chrome.storage.local.get(["paused", "reveal"]),
  ]);
  $("paused").checked = !!stored.paused;
  $("reveal").checked = !!stored.reveal;

  if (!health) {
    $("model").textContent = "";
    setRulesAvailable(false);
    const custom = server !== DEFAULT_SERVER;
    render({
      tone: "problem",
      headline: "unrager isn't running",
      detail: custom
        ? `Nothing answered at ${server}. On that computer, run:`
        : "The extension needs unrager running on this computer. In a terminal, run:",
      command: "unrager setup",
    });
    return;
  }

  const filter = await request(`${server}/api/filter/status`, { timeoutMs: 5000 }).catch(() => null);
  $("model").textContent = filter
    ? `Checking posts with ${filter.model} on ${BACKEND_NAMES[filter.backend] || filter.backend} (${hostLabel(filter.host)}).`
    : "";
  if (!rulesLoaded) loadRules(server);
  render(
    versionView(health.version) || (filter && modelView(filter)) || tabView(tab, !!stored.paused)
  );
}

function setRulesAvailable(available) {
  for (const el of $("rules").querySelectorAll("input, textarea, button")) el.disabled = !available;
  $("rules-hint").textContent = available
    ? "Posts mainly about one of these topics disappear. A post that only mentions one in passing stays."
    : "Start unrager to see and edit your rules.";
}

function autosize(textarea) {
  textarea.style.height = "auto";
  textarea.style.height = `${textarea.scrollHeight}px`;
}

/// "12 hidden" for a rule, once the counts are in; nothing before then or
/// for a topic that was edited since.
function countLabel(rule) {
  if (!hiddenByRule) return "";
  const n = hiddenByRule.get(rule) || 0;
  return n ? `${n.toLocaleString()} hidden` : "none hidden";
}

function renderCounts() {
  for (const li of $("topics").children) {
    const field = li.querySelector("textarea");
    li.querySelector(".count").textContent = field.dataset.saved === field.value ? countLabel(field.value.trim()) : "";
  }
  for (const li of $("builtin-list").children) {
    li.querySelector(".count").textContent = countLabel(li.dataset.rule);
  }
}

function addTopicRow(text, saved) {
  const li = document.createElement("li");
  const field = document.createElement("textarea");
  field.rows = 1;
  field.value = text;
  if (saved) field.dataset.saved = text;
  field.spellcheck = false;
  field.setAttribute("aria-label", "Topic");
  field.addEventListener("input", () => {
    autosize(field);
    renderCounts();
  });
  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "remove";
  remove.textContent = "Remove";
  remove.addEventListener("click", () => li.remove());
  const count = document.createElement("span");
  count.className = "count";
  li.append(field, remove, count);
  $("topics").append(li);
  requestAnimationFrame(() => autosize(field));
}

function selectedStrictness() {
  const checked = document.querySelector('input[name="strictness"]:checked');
  return checked ? checked.value : "balanced";
}

function showStrictness(value) {
  for (const radio of document.querySelectorAll('input[name="strictness"]')) radio.checked = radio.value === value;
  $("strictness-hint").textContent = STRICTNESS_HINTS[value] || "";
  $("builtins").hidden = value === "relaxed" || !$("builtin-list").children.length;
}

function renderBuiltins(labels) {
  $("builtin-list").replaceChildren(
    ...labels.map((label) => {
      const li = document.createElement("li");
      li.dataset.rule = label;
      const name = document.createElement("span");
      name.textContent = label;
      const count = document.createElement("span");
      count.className = "count";
      li.append(name, count);
      return li;
    })
  );
}

function renderTally(stats) {
  const tally = $("tally");
  if (!stats.checked) {
    tally.textContent = "Nothing checked since the rules last changed.";
  } else {
    const share = Math.round((100 * stats.hidden) / stats.checked);
    tally.textContent = `These rules hid ${stats.hidden.toLocaleString()} of the ${stats.checked.toLocaleString()} posts checked since they last changed (${share}%).`;
  }
  const { hidden, shown } = stats.you || {};
  if (hidden || shown) tally.textContent += ` You hid ${hidden || 0} and showed ${shown || 0} yourself.`;
  tally.hidden = false;
}

/// Counts are a guide for tuning the rules, so failing to load them only
/// leaves them out.
async function loadStats(server) {
  try {
    const stats = await request(`${server}/api/filter/stats`);
    hiddenByRule = new Map(stats.rules.filter((r) => r.rule).map((r) => [r.rule, r.hidden]));
    renderTally(stats);
    renderCounts();
  } catch (_) {}
}

async function loadRules(server) {
  try {
    const rules = await request(`${server}/api/config/filter`);
    $("topics").replaceChildren();
    for (const topic of rules.drop_topics || []) addTopicRow(topic, true);
    $("guidance").value = rules.extra_guidance || "";
    renderBuiltins(rules.built_in_rules || []);
    showStrictness(rules.strictness || "balanced");
    rulesLoaded = true;
    setRulesAvailable(true);
    loadStats(server);
  } catch (e) {
    setRulesAvailable(false);
    $("rules-note").textContent = `Couldn't load your rules: ${e.message}`;
  }
}

async function saveRules() {
  const topics = [...$("topics").querySelectorAll("textarea")]
    .map((t) => t.value.trim())
    .filter(Boolean);
  const note = $("rules-note");
  const button = $("save-rules");
  button.disabled = true;
  note.textContent = "Saving…";
  try {
    const server = await serverUrl();
    await request(`${server}/api/config/filter`, {
      method: "PATCH",
      body: {
        drop_topics: topics,
        extra_guidance: $("guidance").value.trim(),
        strictness: selectedStrictness(),
      },
    });
    await chrome.storage.local.set({ rulesChangedAt: Date.now() });
    note.textContent = "Saved. Open x.com tabs are being checked again.";
    await loadRules(server);
  } catch (e) {
    note.textContent = `Couldn't save: ${e.message}`;
  } finally {
    button.disabled = false;
  }
}

/// Anything but this computer needs a host permission, which Chrome only
/// grants from a click, so it's asked for here rather than in the manifest.
async function saveServer(event) {
  event.preventDefault();
  const note = $("server-note");
  const raw = $("server").value.trim();
  if (!raw) {
    await chrome.storage.local.remove("server");
    note.textContent = `Using ${DEFAULT_SERVER}.`;
    rulesLoaded = false;
    return refresh();
  }
  let url;
  try {
    url = new URL(raw);
    if (!/^https?:$/.test(url.protocol)) throw new Error();
  } catch (_) {
    note.textContent = "Enter an address like http://localhost:7777.";
    return;
  }
  if (!LOCAL_HOSTS.has(url.hostname)) {
    const granted = await chrome.permissions.request({ origins: [`${url.origin}/*`] }).catch(() => false);
    if (!granted) {
      note.textContent = `The browser needs your permission to reach ${url.host}.`;
      return;
    }
  }
  await chrome.storage.local.set({ server: url.origin });
  note.textContent = `Using ${url.origin}.`;
  rulesLoaded = false;
  refresh();
}

$("version").textContent = EXTENSION_VERSION;
$("paused").addEventListener("change", async (e) => {
  await chrome.storage.local.set({ paused: e.target.checked });
  refresh();
});
$("reveal").addEventListener("change", (e) => chrome.storage.local.set({ reveal: e.target.checked }));
$("command-copy").addEventListener("click", async () => {
  await navigator.clipboard.writeText($("command-text").textContent);
  $("command-copy").textContent = "Copied";
  setTimeout(() => ($("command-copy").textContent = "Copy"), 1500);
});
$("add-topic").addEventListener("submit", (e) => {
  e.preventDefault();
  const input = $("new-topic");
  const text = input.value.trim();
  if (!text) return;
  addTopicRow(text, false);
  input.value = "";
});
for (const radio of document.querySelectorAll('input[name="strictness"]')) {
  radio.addEventListener("change", () => showStrictness(radio.value));
}
$("save-rules").addEventListener("click", saveRules);
$("server-form").addEventListener("submit", saveServer);
$("rules").addEventListener("toggle", () => {
  for (const t of $("topics").querySelectorAll("textarea")) autosize(t);
});

setRulesAvailable(false);
serverUrl().then((server) => {
  $("server").value = server === DEFAULT_SERVER ? "" : server;
});
refresh();
