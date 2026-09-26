const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const POSTS = [
  { name: "Mira Okafor", handle: "mira_bakes", hue: 28, text: "Day 3 of the new sourdough starter. It smells like green apples, which I'm told is good news." },
  { name: "Outrage Daily", handle: "outrage_daily", hue: 355, rage: true, text: "THIS IS WHY NOBODY TRUSTS THEM ANYMORE 😡😡 share before they delete it!!!" },
  { name: "Kestrel", handle: "kestrel_dev", hue: 200, text: "Shipped v2 of my tiny CLI. Startup went from 180 ms to 9 ms by deleting one dependency." },
  { name: "Harbor Light", handle: "harborlight", hue: 190, text: "Morning ferry. The fog was sitting right on the water and nobody said a word." },
  { name: "Doomcast", handle: "doomcast", hue: 10, rage: true, text: "The economy has THREE WEEKS left. Pull your savings NOW. Nobody is talking about this." },
  { name: "Juno Reads", handle: "juno_reads", hue: 280, text: "Halfway through a 900-page novel and I've started rationing chapters so it doesn't end." },
  { name: "Hot Take Harold", handle: "hottake_harold", hue: 40, rage: true, text: "Unpopular opinion: anyone who uses tabs instead of spaces shouldn't be allowed near a keyboard. RT if you agree." },
  { name: "Ada Lindqvist", handle: "ada_plots", hue: 160, text: "The new paper on sparse attention is unusually readable. My notes are in the thread." },
  { name: "Tomás", handle: "tomas_climbs", hue: 95, text: "Finally sent the route I've been falling off since April. Hands shredded, heart full." },
  { name: "Rick", handle: "ratio_rick", hue: 330, rage: true, text: "Imagine being this wrong in public. Quote this with your worst take, cowards." },
  { name: "Fern & Fog", handle: "fernandfog", hue: 130, text: "Repotted every plant in the apartment. The cat supervised." },
  { name: "Priya", handle: "priya_maps", hue: 250, text: "Made a map of every bench in my neighborhood. There are 212. I have sat on 40." },
  { name: "Payout Pete", handle: "payout_pete", hue: 50, rage: true, text: "X paid me $4 for 90 million impressions. This platform is DEAD. Screenshot below 👇" },
  { name: "Lin", handle: "lin_synth", hue: 300, text: "Recorded a four-minute track using only the sound of my radiator." },
  { name: "The Real Truth", handle: "realtruth_now", hue: 0, rage: true, text: "They don't want you to see this. Everyone who disagrees is part of the problem. Simple as." },
  { name: "Owen", handle: "owen_repairs", hue: 170, text: "Fixed a 1974 radio with one capacitor and a lot of patience. It found a jazz station first try." },
];

const FIRST_SCREEN = 6;
const ARRIVAL_MS = 3200;
const CHECK_MS = 900;
const FOLD_MS = 1000;
const MAX_ROWS = 10;

function initials(name) {
  return name
    .split(/\s+/)
    .filter((w) => /\p{L}/u.test(w[0]))
    .slice(0, 2)
    .map((w) => w[0])
    .join("")
    .toUpperCase();
}

function postElement(post, ago) {
  const li = document.createElement("li");
  li.className = "post";
  li.innerHTML = `<div class="clip"><div class="post-inner">
      <span class="pill">Hidden by unrager</span>
      <span class="avatar"></span>
      <div class="post-main"><p class="post-head"><b></b> <span></span></p><p class="post-text"></p></div>
    </div></div>`;
  const avatar = li.querySelector(".avatar");
  avatar.style.setProperty("--hue", post.hue);
  avatar.textContent = initials(post.name);
  li.querySelector(".post-head b").textContent = post.name;
  li.querySelector(".post-head span").textContent = `@${post.handle} · ${ago}`;
  li.querySelector(".post-text").textContent = post.text;
  return li;
}

/// The hero timeline: posts arrive at the top every few seconds and the
/// rage-bait among them is flagged, then folds away while the badge counts
/// it. It only runs while it's on screen, and holds still for reduced motion.
function startDemo() {
  const feed = document.getElementById("demo-feed");
  const badge = document.getElementById("demo-badge");
  const reveal = document.getElementById("demo-reveal");
  if (!feed || !badge || !reveal) return;

  let next = 0;
  let hidden = 0;
  let visible = true;
  let timer = null;

  const take = () => POSTS[next++ % POSTS.length];

  const count = () => {
    hidden += 1;
    badge.textContent = String(hidden);
    badge.hidden = false;
    badge.classList.remove("is-bumped");
    void badge.offsetWidth;
    badge.classList.add("is-bumped");
  };

  const judge = (li, post, delay) => {
    if (!post.rage) return;
    setTimeout(() => li.classList.add("is-flagged"), delay);
    setTimeout(() => {
      li.classList.add("is-hidden");
      count();
    }, delay + FOLD_MS);
  };

  const trim = () => {
    while (feed.children.length > MAX_ROWS) feed.lastElementChild.remove();
  };

  for (let i = 0; i < FIRST_SCREEN; i++) {
    const post = take();
    const li = postElement(post, `${2 + i * 7}m`);
    feed.append(li);
    if (reducedMotion) {
      if (post.rage) {
        li.classList.add("is-hidden");
        count();
      }
    } else {
      judge(li, post, 1200 + i * 450);
    }
  }

  reveal.addEventListener("change", () => feed.classList.toggle("is-revealing", reveal.checked));
  if (reducedMotion) return;

  const arrive = () => {
    if (!visible || document.hidden) return;
    const post = take();
    const li = postElement(post, "now");
    li.classList.add("is-entering");
    feed.prepend(li);
    requestAnimationFrame(() => requestAnimationFrame(() => li.classList.remove("is-entering")));
    judge(li, post, CHECK_MS);
    trim();
  };

  const run = () => {
    if (timer === null) timer = setInterval(arrive, ARRIVAL_MS);
  };
  const halt = () => {
    clearInterval(timer);
    timer = null;
  };

  new IntersectionObserver((entries) => {
    visible = entries.some((e) => e.isIntersecting);
    if (visible) run();
    else halt();
  }).observe(feed);
  document.addEventListener("visibilitychange", () => (document.hidden ? halt() : visible && run()));
}

function wireCopyButtons() {
  for (const button of document.querySelectorAll(".copy")) {
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
        button.textContent = "Copied";
      } catch (_) {
        button.textContent = "Select and copy";
      }
      setTimeout(() => (button.textContent = "Copy"), 1600);
    });
  }
}

function wireTabs() {
  const tabs = [...document.querySelectorAll('[role="tab"]')];
  const select = (tab) => {
    for (const t of tabs) {
      const on = t === tab;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
    }
  };
  for (const tab of tabs) {
    tab.addEventListener("click", () => select(tab));
    tab.addEventListener("keydown", (e) => {
      const step = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
      if (!step) return;
      const target = tabs[(tabs.indexOf(tab) + step + tabs.length) % tabs.length];
      select(target);
      target.focus();
      e.preventDefault();
    });
  }
}

function relativeTime(iso) {
  const seconds = (Date.now() - new Date(iso).getTime()) / 1000;
  if (!Number.isFinite(seconds) || seconds < 3600) return "within the hour";
  if (seconds < 86400) return `${Math.round(seconds / 3600)} h ago`;
  const days = Math.round(seconds / 86400);
  return `${days} day${days === 1 ? "" : "s"} ago`;
}

async function showDownloads() {
  try {
    const res = await fetch("/api/downloads", { headers: { Accept: "application/json" } });
    if (!res.ok) return;
    const data = await res.json();
    if (typeof data.total !== "number" || data.total <= 0) return;
    const fmt = (n) => (typeof n === "number" ? n.toLocaleString("en-US") : "0");
    document.getElementById("download-count").textContent = fmt(data.total);
    document.getElementById("dl-crates").textContent = fmt(data.sources?.crates_io?.count);
    document.getElementById("dl-gh").textContent = fmt(data.sources?.github_releases?.count);
    if (data.updated_at) document.getElementById("dl-updated").textContent = relativeTime(data.updated_at);
    document.getElementById("downloads").hidden = false;
  } catch (_) {}
}

startDemo();
wireCopyButtons();
wireTabs();
showDownloads();
