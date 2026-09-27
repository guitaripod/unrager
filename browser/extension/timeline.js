/// Pure walk over X's HomeTimeline GraphQL JSON — a port of
/// src/parse/timeline.rs + src/parse/tweet.rs with the same field names, so the
/// two stay easy to fix together when X changes its response shape.
const unragerTimeline = (() => {
  const MAX_TEXT_CHARS = 500;

  function decodeEntities(s) {
    return s
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"')
      .replace(/&#39;|&apos;/g, "'");
  }

  function unwrap(result) {
    return result && result.__typename === "TweetWithVisibilityResults" ? result.tweet : result;
  }

  function tweetText(node) {
    const legacy = node.legacy || {};
    const note =
      node.note_tweet &&
      node.note_tweet.note_tweet_results &&
      node.note_tweet.note_tweet_results.result &&
      node.note_tweet.note_tweet_results.result.text;
    return decodeEntities(note || legacy.full_text || "");
  }

  function author(node) {
    const u = (node.core && node.core.user_results && node.core.user_results.result) || {};
    const core = u.core || {};
    const legacy = u.legacy || {};
    return {
      id: u.rest_id || null,
      handle: core.screen_name || legacy.screen_name || "",
      name: core.name || legacy.name || "",
    };
  }

  /// Mirrors `filter::build_classification_text`, so a verdict computed here
  /// and one computed by the TUI for the same tweet id see the same input.
  function classificationText(node) {
    const { handle, name } = author(node);
    let s = `@${handle} (${name}): ${tweetText(node)}`;
    const quoted = unwrap(node.quoted_status_result && node.quoted_status_result.result);
    if (quoted && quoted.__typename === "Tweet") {
      s += "\n";
      for (const line of tweetText(quoted).split("\n")) s += `> ${line}\n`;
    }
    return Array.from(s).slice(0, MAX_TEXT_CHARS).join("");
  }

  function collectTweet(itemContent, out) {
    if (!itemContent || itemContent.itemType !== "TimelineTweet") return;
    if (itemContent.promotedMetadata != null) return;
    const node = unwrap(itemContent.tweet_results && itemContent.tweet_results.result);
    if (!node || node.__typename !== "Tweet" || !node.legacy) return;
    const original = unwrap(
      node.legacy.retweeted_status_result && node.legacy.retweeted_status_result.result
    );
    const authors = [author(node).id];
    if (original && original.__typename === "Tweet") authors.push(author(original).id);
    out.push({
      id: node.rest_id,
      domId: original && original.rest_id ? original.rest_id : node.rest_id,
      text: classificationText(node),
      authors: authors.filter(Boolean),
      own: false,
    });
  }

  /// The user's own posts, retweets of them, and every post in a
  /// conversation the user took part in are never hidden: hiding the post a
  /// reply of theirs answers would leave the reply hanging.
  function markOwn(group, selfId) {
    if (!selfId || !group.some((t) => t.authors.includes(selfId))) return;
    for (const t of group) t.own = true;
  }

  /// Collects an entry's posts. A retweet's own id never appears in the DOM:
  /// X renders the original, whose permalink is what `domId` matches cells on.
  function collectFromEntry(entry, out, selfId) {
    const content = entry && entry.content;
    if (!content) return;
    const entryType = content.entryType || content.__typename;
    const group = [];
    if (entryType === "TimelineTimelineItem") {
      collectTweet(content.itemContent, group);
    } else if (entryType === "TimelineTimelineModule") {
      for (const item of content.items || []) collectTweet(item.item && item.item.itemContent, group);
    }
    markOwn(group, selfId);
    out.push(...group);
  }

  /// Returns the tweets found plus a `problem` string when the shape looks
  /// wrong, so drift surfaces as a warning instead of a silently idle filter.
  /// `selfId` is the signed-in account's id, for marking the user's own posts.
  function extractTweets(json, selfId) {
    const instructions =
      json && json.data && json.data.home && json.data.home.home_timeline_urt
        ? json.data.home.home_timeline_urt.instructions
        : null;
    if (!Array.isArray(instructions)) {
      return { tweets: [], problem: "no instructions[] at data.home.home_timeline_urt" };
    }
    const tweets = [];
    for (const block of instructions) {
      if (block.type === "TimelineAddEntries") {
        for (const entry of block.entries || []) collectFromEntry(entry, tweets, selfId);
      } else if (block.type === "TimelineAddToModule") {
        const group = [];
        for (const item of block.moduleItems || []) collectTweet(item.item && item.item.itemContent, group);
        markOwn(group, selfId);
        tweets.push(...group);
      } else if (block.type === "TimelineReplaceEntry" || block.type === "TimelinePinEntry") {
        collectFromEntry(block.entry, tweets, selfId);
      }
    }
    const hadEntries = instructions.some(
      (b) => b.type === "TimelineAddEntries" && (b.entries || []).some((e) => /^tweet-/.test(e.entryId || ""))
    );
    const problem = hadEntries && tweets.length === 0 ? "tweet entries present but none extracted" : null;
    return { tweets, problem };
  }

  return { extractTweets };
})();

if (typeof module !== "undefined" && module.exports) module.exports = unragerTimeline;
