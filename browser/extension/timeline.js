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
    return { handle: core.screen_name || legacy.screen_name || "", name: core.name || legacy.name || "" };
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

  /// A retweet's own id never appears in the DOM: X renders the original
  /// tweet, whose permalink is what a cell can be matched on.
  function domIdOf(node) {
    const original = unwrap(
      node.legacy.retweeted_status_result && node.legacy.retweeted_status_result.result
    );
    return original && original.rest_id ? original.rest_id : node.rest_id;
  }

  function collectTweet(itemContent, out) {
    if (!itemContent || itemContent.itemType !== "TimelineTweet") return;
    if (itemContent.promotedMetadata != null) return;
    const node = unwrap(itemContent.tweet_results && itemContent.tweet_results.result);
    if (!node || node.__typename !== "Tweet" || !node.legacy) return;
    out.push({ id: node.rest_id, domId: domIdOf(node), text: classificationText(node) });
  }

  function collectFromEntry(entry, out) {
    const content = entry && entry.content;
    if (!content) return;
    const entryType = content.entryType || content.__typename;
    if (entryType === "TimelineTimelineItem") {
      collectTweet(content.itemContent, out);
    } else if (entryType === "TimelineTimelineModule") {
      for (const item of content.items || []) collectTweet(item.item && item.item.itemContent, out);
    }
  }

  /// Returns the tweets found plus a `problem` string when the shape looks
  /// wrong, so drift surfaces as a warning instead of a silently idle filter.
  function extractTweets(json) {
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
        for (const entry of block.entries || []) collectFromEntry(entry, tweets);
      } else if (block.type === "TimelineAddToModule") {
        for (const item of block.moduleItems || []) collectTweet(item.item && item.item.itemContent, tweets);
      } else if (block.type === "TimelineReplaceEntry" || block.type === "TimelinePinEntry") {
        collectFromEntry(block.entry, tweets);
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
