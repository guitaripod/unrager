/// The pure half of the stats on the user's own posts (insights.js): reading
/// X's counts off its labels, the shape of a post's first hours, what rose
/// since the user last looked, where people stand with the user, and what
/// fits beside a count. No DOM, so `node --test` checks all of it.
const unragerInsightsModel = (() => {
  const KINDS = ["replies", "reposts", "likes", "bookmarks", "views"];
  const SUMMARY_WORDS = [
    [/^repl/i, "replies"],
    [/^(?:repost|retweet)/i, "reposts"],
    [/^like/i, "likes"],
    [/^bookmark/i, "bookmarks"],
    [/^view/i, "views"],
  ];
  /// The fewest hours worth drawing a curve for, as the iPhone app has it.
  const MIN_CURVE_HOURS = 6;

  /// The whole number an accessibility label of X's starts with ("48 Likes.
  /// Like", "23720 views. View post analytics", "1.234 Likes"), whatever the
  /// language groups its digits with; null when it starts with none ("Like").
  function leadingCount(label) {
    const m = /^\s*(\d[\d.,'\s  ]*)/.exec(label || "");
    if (!m) return null;
    const digits = m[1].replace(/\D/g, "");
    return digits ? Number(digits) : null;
  }

  /// X's English summary of a post's action bar, "3 reposts, 48 likes, 4
  /// bookmarks, 23722 views", as counts: exact, and a count it leaves out is
  /// zero. Null unless every count in it reads, so another language that
  /// shares a word or two ("3 Reposts, 48 „Gefällt mir“-Angaben") is never
  /// half read.
  function summaryCounts(label) {
    const counts = Object.fromEntries(KINDS.map((k) => [k, 0]));
    const parts = String(label || "")
      .split(/,\s+/)
      .map((p) => p.trim())
      .filter(Boolean);
    if (!parts.length) return null;
    for (const part of parts) {
      const m = /^(\d[\d,.  ]*)\s+([a-z]+)$/i.exec(part);
      const word = m && SUMMARY_WORDS.find(([pattern]) => pattern.test(m[2]));
      if (!word) return null;
      counts[word[1]] = Number(m[1].replace(/\D/g, ""));
    }
    return counts;
  }

  /// A post's counts from what X's page says: the summary label where it
  /// reads, otherwise each control's own label (`labels`, by kind; a label
  /// without a number leaves that count unknown, null).
  function readCounts(summary, labels) {
    const fromSummary = summaryCounts(summary);
    if (fromSummary) return fromSummary;
    const counts = {};
    for (const kind of KINDS) counts[kind] = labels && labels[kind] != null ? leadingCount(labels[kind]) : null;
    return counts;
  }

  /// A count as X's buttons show it: 999, 1.2K, 23K, 1.2M, 23M.
  function short(n) {
    if (!Number.isFinite(n)) return "";
    const trim = (x) => String(x).replace(/\.0$/, "");
    if (n < 1e3) return String(n);
    if (n < 1e4) return `${trim(Math.floor(n / 100) / 10)}K`;
    if (n < 1e6) return `${Math.floor(n / 1e3)}K`;
    if (n < 1e7) return `${trim(Math.floor(n / 1e5) / 10)}M`;
    return `${Math.floor(n / 1e6)}M`;
  }

  /// A count in full, grouped the way the reader's language groups digits.
  function full(n, locale) {
    return Number.isFinite(n) ? new Intl.NumberFormat(locale).format(n) : "";
  }

  /// How long `ms` is, said briefly: "now", "4m", "3h", "2d", "5w".
  function span(ms) {
    const minutes = Math.floor(Math.max(0, ms) / 60000);
    if (minutes < 1) return "now";
    if (minutes < 60) return `${minutes}m`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h`;
    const days = Math.floor(hours / 24);
    return days < 14 ? `${days}d` : `${Math.floor(days / 7)}w`;
  }

  /// The shape of a post's first hours from X's impressions per hour: its
  /// peak, how its reach built up and how long half of it took. Null with
  /// fewer than six hours or nothing in them.
  function curve(hourly) {
    const values = (hourly || []).map((v) => Math.max(0, Number(v) || 0));
    const total = values.reduce((a, b) => a + b, 0);
    if (values.length < MIN_CURVE_HOURS || total <= 0) return null;
    let peakIndex = 0;
    values.forEach((v, i) => {
      if (v > values[peakIndex]) peakIndex = i;
    });
    let running = 0;
    const cumulative = values.map((v) => (running += v) / total);
    const half = cumulative.findIndex((c) => c >= 0.5);
    const halfLife = (half === -1 ? values.length - 1 : half) + 1;
    return { hourly: values, total, peakIndex, peak: values[peakIndex], cumulative, halfLife, insight: insight(halfLife) };
  }

  /// One sentence on how fast a post's reach came.
  function insight(halfLife) {
    if (halfLife === 1) return "Half of the impressions arrived in the first hour.";
    if (halfLife < 24) return `Half of the impressions arrived in the first ${halfLife} hours.`;
    return `Half of the impressions took ${halfLife} hours to arrive.`;
  }

  /// The hours to label under a chart of `hours`: every 3, 6 or 12.
  function axisTicks(hours) {
    const step = hours <= 12 ? 3 : hours <= 30 ? 6 : 12;
    const ticks = [];
    for (let h = 0; h <= hours; h += step) ticks.push(h);
    return ticks;
  }

  /// "5–6h" for the sixth hour.
  function hourRange(index) {
    return `${index}–${index + 1}h`;
  }

  /// The share of impressions that engaged, "5.2% engaged"; null when
  /// nobody engaged or nobody saw it.
  function engaged(analytics) {
    if (!analytics || !(analytics.impressions > 0) || !(analytics.engagements > 0)) return null;
    const pct = (analytics.engagements / analytics.impressions) * 100;
    return `${pct < 0.1 ? "<0.1" : pct.toFixed(1)}% engaged`;
  }

  /// Where someone stands with the user: "mutual", "follower" (follows the
  /// user, not followed back), "following" (followed, not following back) or
  /// "none". A server that didn't say whether they follow the user only
  /// tells "following" from "none".
  function standing(user) {
    const followsMe = user && user.follows_me === true;
    const followedByMe = user && user.followed_by_me === true;
    if (followsMe && followedByMe) return "mutual";
    if (followsMe) return "follower";
    return followedByMe ? "following" : "none";
  }

  /// How the people in a list stand with the user, and how many are verified.
  function tally(users) {
    const counts = { total: 0, mutual: 0, follower: 0, following: 0, none: 0, verified: 0 };
    for (const user of users || []) {
      counts.total += 1;
      counts[standing(user)] += 1;
      if (user.verified) counts.verified += 1;
    }
    return counts;
  }

  /// The people a lens lets through: everyone, those who follow the user,
  /// those to follow back, those the user follows, or the verified.
  function lens(users, name) {
    const test = {
      all: () => true,
      followers: (u) => u.follows_me === true,
      followBack: (u) => u.follows_me === true && u.followed_by_me !== true,
      following: (u) => u.followed_by_me === true,
      verified: (u) => !!u.verified,
    }[name];
    return test ? (users || []).filter(test) : users || [];
  }

  /// What rose since `before`: each count now above what it was, by how
  /// much. Counts that fell, or weren't known on either side, aren't rises.
  function rises(before, now) {
    const out = {};
    if (!before || !now) return out;
    for (const key of Object.keys(now)) {
      const a = before[key];
      const b = now[key];
      if (Number.isFinite(a) && Number.isFinite(b) && b > a) out[key] = b - a;
    }
    return out;
  }

  /// Whether a rise is worth a mark beside its count. Views climb all the
  /// time, so a few more since the last look is noise: they need at least
  /// ten, and a twentieth of what there were. Anything else counts at one.
  function notable(kind, rise, before) {
    if (!(rise > 0)) return false;
    if (kind !== "views" && kind !== "impressions") return true;
    return rise >= 10 && rise >= (Number(before) || 0) * 0.05;
  }

  /// Which of `items` fit in `width` pixels beside a count, `gap` apart.
  /// Each item offers widths from its fullest form down (a face pile of 3,
  /// 2, then 1 faces); the most important items are placed first, each in
  /// the fullest form that still fits. Returns, by key, the index of the
  /// form chosen; an item that fits in no form is left out.
  function fit(items, width, gap) {
    const chosen = {};
    let left = width;
    const order = [...items].sort((a, b) => a.priority - b.priority);
    for (const item of order) {
      const needs = (w) => w + (Object.keys(chosen).length ? gap : 0);
      const index = item.widths.findIndex((w) => needs(w) <= left);
      if (index === -1) continue;
      left -= needs(item.widths[index]);
      chosen[item.key] = index;
    }
    return chosen;
  }

  /// The store of what the user last saw of each post with `snapshot` set
  /// for `id`, keeping the `cap` most recently seen.
  function remember(store, id, snapshot, cap) {
    const next = { ...(store || {}), [id]: snapshot };
    const ids = Object.keys(next);
    if (ids.length <= cap) return next;
    ids.sort((a, b) => (next[b].t || 0) - (next[a].t || 0));
    return Object.fromEntries(ids.slice(0, cap).map((k) => [k, next[k]]));
  }

  /// Two stores of looks combined, the later look at each post winning,
  /// trimmed to the `cap` most recent.
  function mergeSeen(a, b, cap) {
    const merged = { ...(a || {}) };
    for (const [id, look] of Object.entries(b || {})) {
      if (!merged[id] || (look && (look.t || 0) >= (merged[id].t || 0))) merged[id] = look;
    }
    const ids = Object.keys(merged);
    if (ids.length <= cap) return merged;
    ids.sort((x, y) => (merged[y].t || 0) - (merged[x].t || 0));
    return Object.fromEntries(ids.slice(0, cap).map((k) => [k, merged[k]]));
  }

  /// The handle and id in a post's address, "/handle/status/123…".
  function postPath(path) {
    const m = /^\/([A-Za-z0-9_]{1,15})\/status\/(\d+)/.exec(path || "");
    return m ? { handle: m[1], id: m[2] } : null;
  }

  /// A profile picture's address at another of X's sizes: "normal" (48 px),
  /// "bigger" (73 px), "200x200" or "400x400".
  function avatarAt(url, size) {
    if (!url) return "";
    return url.replace(/_(?:normal|bigger|mini|reasonably_small|\d+x\d+)(\.[a-z]+)$/i, `_${size}$1`);
  }

  return {
    KINDS,
    leadingCount,
    summaryCounts,
    readCounts,
    short,
    full,
    span,
    curve,
    axisTicks,
    hourRange,
    engaged,
    standing,
    tally,
    lens,
    rises,
    notable,
    fit,
    remember,
    mergeSeen,
    postPath,
    avatarAt,
  };
})();

if (typeof module !== "undefined" && module.exports) module.exports = unragerInsightsModel;
