import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const M = require("../extension/insights-model.js");

test("a label's leading number reads in any digit grouping", () => {
  assert.equal(M.leadingCount("48 Likes. Like"), 48);
  assert.equal(M.leadingCount("23720 views. View post analytics"), 23720);
  assert.equal(M.leadingCount("1,234 Likes. Like"), 1234);
  assert.equal(M.leadingCount("1.234 „Gefällt mir“-Angaben"), 1234);
  assert.equal(M.leadingCount("12 345 J’aime"), 12345);
  assert.equal(M.leadingCount("Bookmark"), null);
  assert.equal(M.leadingCount(""), null);
  assert.equal(M.leadingCount(null), null);
});

test("the action bar's summary gives exact counts, zero for what it leaves out", () => {
  assert.deepEqual(M.summaryCounts("3 reposts, 48 likes, 4 bookmarks, 23722 views"), {
    replies: 0,
    reposts: 3,
    likes: 48,
    bookmarks: 4,
    views: 23722,
  });
  assert.deepEqual(M.summaryCounts("1 reply, 1 repost, 1 like, 1 bookmark, 1,204 views"), {
    replies: 1,
    reposts: 1,
    likes: 1,
    bookmarks: 1,
    views: 1204,
  });
  assert.equal(M.summaryCounts("3 Reposts, 48 „Gefällt mir“-Angaben"), null);
  assert.equal(M.summaryCounts("48 J’aime, 3 republications"), null);
  assert.equal(M.summaryCounts(""), null);
});

test("without a summary that reads, each control's label counts and a bare one is unknown", () => {
  const counts = M.readCounts("48 J’aime", {
    replies: "0 réponse. Répondre",
    reposts: "3 republications. Republier",
    likes: "48 J’aime. J’aime",
    bookmarks: "Signet",
    views: null,
  });
  assert.deepEqual(counts, { replies: 0, reposts: 3, likes: 48, bookmarks: null, views: null });
});

test("counts shorten the way X's buttons show them", () => {
  assert.deepEqual(
    [0, 999, 1000, 1299, 9999, 10000, 23722, 999999, 1250000, 23700000].map(M.short),
    ["0", "999", "1K", "1.2K", "9.9K", "10K", "23K", "999K", "1.2M", "23M"]
  );
  assert.equal(M.full(23722, "en-US"), "23,722");
});

test("spans are said briefly", () => {
  assert.equal(M.span(20 * 1000), "now");
  assert.equal(M.span(4 * 60000), "4m");
  assert.equal(M.span(3 * 3600000 + 10), "3h");
  assert.equal(M.span(50 * 3600000), "2d");
  assert.equal(M.span(40 * 86400000), "5w");
});

test("a curve needs six hours and some impressions, then finds its peak and half-life", () => {
  assert.equal(M.curve([1, 2, 3, 4, 5]), null);
  assert.equal(M.curve([0, 0, 0, 0, 0, 0, 0]), null);
  assert.notEqual(M.curve([0, 0, 0, 0, 0, 1]), null);
  const c = M.curve([10, 40, 100, 30, 10, 5, 3, 2]);
  assert.equal(c.peakIndex, 2);
  assert.equal(c.peak, 100);
  assert.equal(c.total, 200);
  assert.equal(c.cumulative.at(-1), 1);
  assert.equal(c.cumulative[2], 0.75);
  assert.equal(c.halfLife, 3);
  assert.equal(M.curve([-5, 10, 10, 10, 10, 10]).total, 50);
});

test("the insight names how fast the reach came, as the iPhone app says it", () => {
  assert.equal(M.curve([900, 50, 20, 10, 10, 10]).insight, "Half of the impressions arrived in the first hour.");
  assert.equal(
    M.curve([10, 10, 10, 10, 10, 10, 10, 10]).insight,
    "Half of the impressions arrived in the first 4 hours."
  );
  assert.equal(
    M.curve([...Array(30).fill(0), 5, 5]).insight,
    "Half of the impressions took 31 hours to arrive."
  );
  assert.deepEqual(M.axisTicks(48), [0, 12, 24, 36, 48]);
  assert.deepEqual(M.axisTicks(28), [0, 6, 12, 18, 24]);
  assert.deepEqual(M.axisTicks(9), [0, 3, 6, 9]);
  assert.equal(M.hourRange(5), "5–6h");
});

test("the engaged share needs someone to have engaged", () => {
  assert.equal(M.engaged({ impressions: 155, engagements: 8 }), "5.2% engaged");
  assert.equal(M.engaged({ impressions: 23736, engagements: 147 }), "0.6% engaged");
  assert.equal(M.engaged({ impressions: 100000, engagements: 3 }), "<0.1% engaged");
  assert.equal(M.engaged({ impressions: 40, engagements: 0 }), null);
  assert.equal(M.engaged(null), null);
});

test("standing, tallies and lenses", () => {
  const users = [
    { follows_me: true, followed_by_me: true, verified: true },
    { follows_me: true, followed_by_me: false },
    { follows_me: false, followed_by_me: true },
    { follows_me: false, followed_by_me: false, verified: true },
    { followed_by_me: true },
  ];
  assert.deepEqual(users.map(M.standing), ["mutual", "follower", "following", "none", "following"]);
  assert.deepEqual(M.tally(users), { total: 5, mutual: 1, follower: 1, following: 2, none: 1, verified: 2 });
  assert.equal(M.lens(users, "followers").length, 2);
  assert.equal(M.lens(users, "followBack").length, 1);
  assert.equal(M.lens(users, "following").length, 3);
  assert.equal(M.lens(users, "verified").length, 2);
  assert.equal(M.lens(users, "all").length, 5);
});

test("rises are only counts that went up and were known both times", () => {
  assert.deepEqual(M.rises({ likes: 40, views: 100, replies: 2, bookmarks: null }, { likes: 48, views: 90, replies: 2, bookmarks: 4 }), {
    likes: 8,
  });
  assert.deepEqual(M.rises(null, { likes: 1 }), {});
});

test("views need a real jump to be marked; other counts rise at one", () => {
  assert.equal(M.notable("likes", 1, 48), true);
  assert.equal(M.notable("views", 2, 30), false);
  assert.equal(M.notable("views", 14, 104), true);
  assert.equal(M.notable("views", 224, 23500), false);
  assert.equal(M.notable("views", 1200, 23500), true);
  assert.equal(M.notable("replies", 0, 3), false);
});

test("what fits beside a count: everything at its smallest first, then the most important grow", () => {
  const items = [
    { key: "faces", priority: 2, widths: [42, 30, 18] },
    { key: "delta", priority: 1, widths: [20] },
    { key: "link", priority: 3, widths: [28] },
  ];
  assert.deepEqual(M.fit(items, 200, 5), { delta: 0, faces: 0, link: 0 });
  assert.deepEqual(M.fit(items, 60, 5), { delta: 0, faces: 1 });
  assert.deepEqual(M.fit(items, 43, 5), { delta: 0, faces: 2 });
  assert.deepEqual(M.fit(items, 19, 5), { faces: 2 });
  assert.deepEqual(M.fit(items, 10, 5), {});
  const facesFirst = [
    { key: "faces", priority: 1, widths: [42, 30, 18] },
    { key: "delta", priority: 2, widths: [22] },
  ];
  assert.deepEqual(M.fit(facesFirst, 50, 5), { faces: 2, delta: 0 }, "a smaller pile leaves room for the rise");
  assert.deepEqual(M.fit(facesFirst, 58, 5), { faces: 1, delta: 0 });
});

test("the seen store keeps the most recently seen posts", () => {
  let store = {};
  for (let i = 0; i < 5; i++) store = M.remember(store, `p${i}`, { t: i }, 3);
  assert.deepEqual(Object.keys(store).sort(), ["p2", "p3", "p4"]);
  store = M.remember(store, "p2", { t: 10 }, 3);
  assert.equal(store.p2.t, 10);
});

test("two tabs' looks merge, the later look at a post winning", () => {
  const a = { p1: { t: 10 }, p2: { t: 50 } };
  const b = { p2: { t: 40 }, p3: { t: 30 } };
  assert.deepEqual(M.mergeSeen(a, b, 10), { p1: { t: 10 }, p2: { t: 50 }, p3: { t: 30 } });
  assert.deepEqual(Object.keys(M.mergeSeen(a, b, 2)).sort(), ["p2", "p3"]);
  assert.deepEqual(M.mergeSeen(undefined, b, 10), b);
});

test("post addresses and avatar sizes", () => {
  assert.deepEqual(M.postPath("/guitaripod/status/2049909631019880753/analytics"), {
    handle: "guitaripod",
    id: "2049909631019880753",
  });
  assert.equal(M.postPath("/home"), null);
  assert.equal(
    M.avatarAt("https://pbs.twimg.com/profile_images/1/ab_400x400.jpg", "normal"),
    "https://pbs.twimg.com/profile_images/1/ab_normal.jpg"
  );
  assert.equal(
    M.avatarAt("https://pbs.twimg.com/profile_images/1/ab_normal.png", "bigger"),
    "https://pbs.twimg.com/profile_images/1/ab_bigger.png"
  );
  assert.equal(M.avatarAt("", "normal"), "");
});
