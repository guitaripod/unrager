import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { extractTweets } = require("../extension/timeline.js");

const SELF = "900000000000000001";
const fixture = (name) => JSON.parse(readFileSync(new URL(`fixtures/${name}`, import.meta.url), "utf8"));
const byId = (tweets) => new Map(tweets.map((t) => [t.id, t]));

test("For you: posts in order, ads and tombstones left out", () => {
  const { tweets, problem } = extractTweets(fixture("home-for-you.json"), SELF);
  assert.equal(problem, null);
  assert.deepEqual(
    tweets.map((t) => t.id),
    [
      "2000000000000000001",
      "2000000000000000003",
      "2000000000000000005",
      "2000000000000000006",
      "2000000000000000007",
      "2000000000000000008",
      "2000000000000000009",
      "2000000000000000016",
      "2000000000000000017",
      "2000000000000000019",
    ]
  );
});

test("classification text decodes entities and quotes the quoted post", () => {
  const tweets = byId(extractTweets(fixture("home-for-you.json"), SELF).tweets);
  assert.equal(tweets.get("2000000000000000001").text, '@plain_author (Plain & Simple): Fish & chips > salad, "obviously"');
  assert.equal(
    tweets.get("2000000000000000003").text,
    "@quoter (Quoter): look at this\n> first line\n> second line\n"
  );
  assert.equal(
    tweets.get("2000000000000000005").text,
    "@long_author (Long Author): The whole long post, past 280 characters."
  );
});

test("pictures' t.co links are dropped, other links shown as their address, text trimmed", () => {
  const tweets = byId(extractTweets(fixture("home-for-you.json"), SELF).tweets);
  assert.equal(tweets.get("2000000000000000016").text, "@limited (Limited): photo day");
  assert.equal(tweets.get("2000000000000000017").text, "@linker (Linker): read example.com/a now 🔥\n");
});

test("quoted lines follow Rust's lines(): none for empty text, no trailing empty line, no \\r", () => {
  const tweets = byId(extractTweets(fixture("home-for-you.json"), SELF).tweets);
  assert.equal(tweets.get("2000000000000000019").text, "@quoter2 (Quoter Two): this\n> one\n> two\n");
});

test("Not interested labels come from DontLike actions only", () => {
  const tweets = byId(extractTweets(fixture("home-for-you.json"), SELF).tweets);
  assert.equal(tweets.get("2000000000000000001").notInterested, "Not interested in this post");
  assert.equal(tweets.get("2000000000000000003").notInterested, "Not interested in this post");
  assert.equal(tweets.get("2000000000000000005").notInterested, null);
  assert.equal(tweets.get("2000000000000000006").notInterested, null);
  assert.equal(tweets.get("2000000000000000007").notInterested, "Not interested in this post");
});

test("conversation blocks carry their thread; the user's own blocks are own", () => {
  const tweets = byId(extractTweets(fixture("home-for-you.json"), SELF).tweets);
  for (const id of ["2000000000000000006", "2000000000000000007"]) {
    assert.equal(tweets.get(id).thread, "home-conversation-2000000000000000007");
    assert.equal(tweets.get(id).own, false);
  }
  assert.equal(tweets.get("2000000000000000008").own, true);
  assert.equal(tweets.get("2000000000000000009").own, true);
  assert.equal(tweets.get("2000000000000000001").thread, undefined);
});

test("Following: a repost is judged and matched as its original", () => {
  const { tweets, problem } = extractTweets(fixture("home-following.json"), SELF);
  assert.equal(problem, null);
  const repost = byId(tweets).get("2000000000000000012");
  assert.equal(repost.id, "2000000000000000012");
  assert.equal(repost.domId, "2000000000000000012");
  assert.equal(repost.text, "@original_author (Original Author): the post being reposted");
  assert.deepEqual(repost.authors, ["100000000000000011", "100000000000000012"]);
  assert.equal(repost.own, false);
});

test("reposts of the user's posts, and the user's own reposts, are own", () => {
  const tweets = byId(extractTweets(fixture("home-following.json"), SELF).tweets);
  assert.equal(tweets.get("2000000000000000014").own, true);
  assert.equal(tweets.get("2000000000000000026").own, true);
});

test("a repost of a post that's gone is judged and matched as the repost", () => {
  const gone = byId(extractTweets(fixture("home-following.json"), SELF).tweets).get("2000000000000000023");
  assert.equal(gone.domId, "2000000000000000023");
  assert.equal(gone.text, "@reposter (Reposter): RT @gone: …");
});

test("replaced and pinned entries are read like added ones", () => {
  const tweets = byId(extractTweets(fixture("home-following.json"), SELF).tweets);
  assert.equal(tweets.get("2000000000000000021").text, "@edited (Edited): edited text");
  assert.equal(tweets.get("2000000000000000022").text, "@pinned (Pinned): pinned post");
});

test("replies added to a conversation block join its thread, and the user's reply makes them own", () => {
  const tweets = byId(extractTweets(fixture("home-following.json"), SELF).tweets);
  for (const id of ["2000000000000000015", "2000000000000000027"]) {
    assert.equal(tweets.get(id).thread, "home-conversation-2000000000000000007");
    assert.equal(tweets.get(id).own, true);
  }
});

test("a changed response shape is reported, not silently empty", () => {
  assert.match(extractTweets({ data: { home: {} } }, SELF).problem, /no instructions/);
  assert.match(extractTweets({ errors: [{ message: "x" }] }, SELF).problem, /no instructions/);
  const renamed = fixture("home-for-you.json");
  for (const entry of renamed.data.home_timeline.home_timeline_urt.instructions[1].entries) {
    if (entry.content.content) entry.content.content.__typename = "TimelinePost";
    for (const { item } of entry.content.items || []) item.content.__typename = "TimelinePost";
  }
  const { tweets, problem } = extractTweets(renamed, SELF);
  assert.equal(tweets.length, 0);
  assert.equal(problem, "tweet entries present but none extracted");
});

test("long text is cut at 500 characters, counting emoji once", () => {
  const json = fixture("home-for-you.json");
  const entry = json.data.home_timeline.home_timeline_urt.instructions[1].entries[1];
  entry.content.content.tweet_results.result.details.full_text = "😡".repeat(600);
  const text = extractTweets(json, SELF).tweets[0].text;
  assert.equal(Array.from(text).length, 500);
});
