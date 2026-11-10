/// Pure walk over the Home timeline JSON of both clients: the `x-web` app
/// (snake_case Relay fields, tweet text under `details`) and rweb (camelCase
/// fields, text under `legacy`), which X still serves to most signed-in users
/// while the new app rolls out country by country. Text, links and reposts
/// are read the way src/parse/tweet.rs reads the older GraphQL shape, and the
/// classification text is `filter::build_classification_text`'s, so the model
/// sees a post the same whichever client asks first.
const unragerTimeline = (() => {
  const MAX_TEXT_CHARS = 500;

  /// Undoes one level of X's HTML escaping, `&amp;` last, like
  /// `decode_html_entities`.
  function decodeEntities(s) {
    return s
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"')
      .replace(/&#39;|&apos;/g, "'")
      .replace(/&amp;/g, "&");
  }

  function unwrap(result) {
    return result && result.__typename === "TweetWithVisibilityResults" ? result.tweet : result;
  }

  /// The t.co links standing for a post's pictures and videos, which X
  /// places by code point in `full_text`.
  function mediaLinks(node, fullText) {
    const chars = Array.from(fullText);
    const links = [];
    for (const media of node.media_entities2 || []) {
      const [start, end] = media.indices || [];
      const link = Number.isInteger(start) && Number.isInteger(end) ? chars.slice(start, end).join("") : "";
      if (/^https:\/\/t\.co\/\w+$/.test(link) && !links.includes(link)) links.push(link);
    }
    return links;
  }

  /// Cuts `url` out of `text` with the spaces around it, keeping one space
  /// between words it separated, like `strip_url`.
  function stripUrl(text, url) {
    let out = "";
    let rest = text;
    for (let at = rest.indexOf(url); at >= 0; at = rest.indexOf(url)) {
      const before = rest.slice(0, at);
      const after = rest.slice(at + url.length).replace(/^\s+/, "");
      out += before.replace(/\s+$/, "");
      if (out && after && /\s$/.test(before)) out += " ";
      rest = after;
    }
    return out + rest;
  }

  /// A post's text as `parse_tweet_node` reads it (`scrub_urls_in_text`):
  /// the whole text of a long post, its pictures' t.co links dropped, other
  /// t.co links shown as the address they stand for, trimmed. rweb's text is
  /// under `legacy` and was already read the same way.
  function tweetText(node) {
    const details = node.details || {};
    const legacy = node.legacy || {};
    const fullText = details.full_text || legacy.full_text || "";
    const note =
      node.note_tweet &&
      node.note_tweet.note_tweet_results &&
      node.note_tweet.note_tweet_results.result &&
      node.note_tweet.note_tweet_results.result.text;
    let text = decodeEntities(note || fullText);
    if (!details.full_text) return text.trim();
    for (const link of mediaLinks(node, fullText)) text = stripUrl(text, link);
    for (const u of node.url_entities || []) {
      if (u && u.url && u.display_url) text = text.split(u.url).join(u.display_url);
    }
    return text.trim();
  }

  /// Rust's `str::lines`: no line after a final newline, none at all for
  /// empty text, and a `\r` before a newline dropped.
  function lines(text) {
    if (!text) return [];
    const parts = text.split("\n");
    if (parts[parts.length - 1] === "") parts.pop();
    return parts.map((line) => line.replace(/\r$/, ""));
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
    const quote = node.quoted_tweet_results || node.quoted_status_result;
    const quoted = unwrap(quote && quote.result);
    if (quoted && quoted.__typename === "Tweet") {
      s += "\n";
      for (const line of lines(tweetText(quoted))) s += `> ${line}\n`;
    }
    return Array.from(s).slice(0, MAX_TEXT_CHARS).join("");
  }

  /// X's own label for "Not interested in this post", in the user's language,
  /// by the feedback key entries point at. Only For you responses carry these.
  function notInterestedPrompts(urt) {
    const prompts = new Map();
    const actions =
      (urt.response_objects && urt.response_objects.feedback_actions) ||
      (urt.responseObjects && urt.responseObjects.feedbackActions) ||
      [];
    for (const action of actions) {
      const value = action && action.value;
      const type = value && (value.feedback_type || value.feedbackType);
      if (value && type === "DontLike" && value.prompt) prompts.set(action.key, value.prompt);
    }
    return prompts;
  }

  function notInterested(feedbackInfo, prompts) {
    const keys =
      (feedbackInfo && (feedbackInfo.feedback_keys || feedbackInfo.feedbackKeys)) || [];
    for (const key of keys) {
      if (prompts.has(key)) return prompts.get(key);
    }
    return null;
  }

  function collectTweet(content, out, offer) {
    if (!content) return;
    const type = content.__typename || content.itemType;
    if (type !== "TimelineTweet") return;
    if (content.promoted_metadata != null || content.promotedMetadata != null) return;
    const node = unwrap(content.tweet_results && content.tweet_results.result);
    if (!node || node.__typename !== "Tweet") return;
    const wrapped =
      node.retweeted_status_results ||
      (node.legacy &&
        (node.legacy.retweeted_status_results || node.legacy.retweeted_status_result)) ||
      node.retweeted_status_result;
    const original = unwrap(wrapped && wrapped.result);
    const subject = original && original.__typename === "Tweet" ? original : node;
    const authors = [author(node).id];
    if (subject !== node) authors.push(author(subject).id);
    out.push({
      id: subject.rest_id,
      domId: subject.rest_id,
      text: classificationText(subject),
      authors: authors.filter(Boolean),
      own: false,
      notInterested: offer || null,
    });
  }

  /// The user's own posts and reposts, reposts of their posts, and every post
  /// in a conversation the user took part in are never hidden: hiding the
  /// post a reply of theirs answers would leave the reply hanging.
  function markOwn(group, selfId) {
    if (!selfId || !group.some((t) => t.authors.includes(selfId))) return;
    for (const t of group) t.own = true;
  }

  /// Tags the posts of a conversation X shows as one block with the block and
  /// their place in it. rweb orders the block by position; the new app orders
  /// it by post id.
  function markThread(group, thread, first) {
    group.forEach((t, i) => {
      t.thread = thread;
      t.position = first + i;
    });
  }

  function collectItems(items, group, prompts) {
    for (const entry of items || []) {
      const item = entry && entry.item;
      if (item) collectTweet(item.content || item.itemContent, group, notInterested(item.feedback_info || item.feedbackInfo, prompts));
    }
  }

  /// Collects an entry's posts. A repost is judged as its original (its id,
  /// author and full text, as `parse_tweet_node` reads it), so the verdict is
  /// the one every other client caches; X renders the original too, whose
  /// permalink is what `domId` matches cells on. A repost of a post that's
  /// gone is judged, and matched, as the repost.
  function collectFromEntry(entry, out, selfId, prompts) {
    const content = entry && entry.content;
    if (!content) return;
    const type = content.__typename || content.entryType;
    const group = [];
    if (type === "TimelineTimelineItem") {
      collectTweet(content.content || content.itemContent, group, notInterested(content.feedback_info || content.feedbackInfo, prompts));
    } else if (type === "TimelineTimelineModule") {
      collectItems(content.items, group, prompts);
      const thread = content.entry_id || content.entryId || entry.entry_id || entry.entryId;
      if (thread) markThread(group, thread, 0);
    }
    markOwn(group, selfId);
    out.push(...group);
  }

  /// The `home_timeline_urt` under whichever field the operation answers in:
  /// `home_timeline` for For you, `home` for Following.
  function timelineOf(json) {
    const data = json && json.data;
    if (!data || typeof data !== "object") return null;
    for (const value of Object.values(data)) {
      if (value && value.home_timeline_urt) return value.home_timeline_urt;
    }
    return null;
  }

  /// Which client sent this body: `xweb` for the new app, `rweb` for the old
  /// one still served to most signed-in users, or null for a response with no
  /// post in it. The two shapes are told apart by where an entry keeps the
  /// post (`content` on the new app, `itemContent` on rweb).
  function clientOf(json) {
    const urt = timelineOf(json);
    const instructions = urt && urt.instructions;
    if (!Array.isArray(instructions)) return null;
    for (const block of instructions) {
      for (const entry of block.entries || []) {
        const content = entry && entry.content;
        if (!content) continue;
        const type = content.__typename || content.entryType;
        if (type === "TimelineTimelineItem") {
          if (content.itemContent) return "rweb";
          if (content.content) return "xweb";
        }
        if (type === "TimelineTimelineModule") {
          const first = (content.items || [])[0];
          const item = first && first.item;
          if (item) {
            if (item.itemContent) return "rweb";
            if (item.content) return "xweb";
          }
        }
      }
      const module = block.module_items || block.moduleItems;
      const first = module && module[0];
      if (first) {
        if (first.itemContent) return "rweb";
        if (first.content) return "xweb";
      }
    }
    return null;
  }

  /// Returns the tweets found plus a `problem` string when the shape looks
  /// wrong, so drift surfaces as a warning instead of a silently idle filter.
  /// `selfId` is the signed-in account's id, for marking the user's own posts.
  function extractTweets(json, selfId) {
    const urt = timelineOf(json);
    const instructions = urt ? urt.instructions : null;
    if (!Array.isArray(instructions)) {
      return { tweets: [], problem: "no instructions[] at data.*.home_timeline_urt" };
    }
    const prompts = notInterestedPrompts(urt);
    const tweets = [];
    for (const block of instructions) {
      const type = block && (block.__typename || block.type);
      if (type === "TimelineAddEntries") {
        for (const entry of block.entries || []) collectFromEntry(entry, tweets, selfId, prompts);
      } else if (type === "TimelineAddToModule") {
        const group = [];
        collectItems(block.module_items || block.moduleItems, group, prompts);
        const thread = block.module_entry_id || block.moduleEntryId;
        if (thread) markThread(group, thread, block.prepend ? -1000 : 1000);
        markOwn(group, selfId);
        tweets.push(...group);
      } else if (type === "TimelineReplaceEntry" || type === "TimelinePinEntry") {
        collectFromEntry(block.entry, tweets, selfId, prompts);
      }
    }
    const hadEntries = instructions.some((b) => {
      if (!b) return false;
      const entries = b.entries || [];
      if ((b.__typename || b.type) !== "TimelineAddEntries") return false;
      return entries.some((e) => /^(?:tweet|home-conversation)-/.test((e && (e.entry_id || e.entryId)) || ""));
    });
    const problem = hadEntries && tweets.length === 0 ? "tweet entries present but none extracted" : null;
    return { tweets, problem };
  }

  return { extractTweets, clientOf };
})();

if (typeof module !== "undefined" && module.exports) module.exports = unragerTimeline;
