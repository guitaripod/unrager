import UIKit
import UnragerKit

extension Tweet {
    /// The fixupx embed-friendly URL (`https://fixupx.com/<handle>/status/<id>`)
    /// — pastes into chats with a working preview where x.com's doesn't.
    var fixupxURL: String {
        "https://fixupx.com/\(author.handle)/status/\(restID)"
    }
}

/// A screen that lists tweets and can act on them. Conformers supply how their
/// rows like, repost, bookmark, quote and ask; the context menu, share sheet,
/// postcard and media saving are shared, so the feed and a thread offer the
/// same actions.
@MainActor
protocol TweetActionHandling: UIViewController {
    func tweetCell(for tweet: Tweet) -> TweetCell?
    func toggleLike(_ tweet: Tweet, cell: TweetCell?)
    func toggleRetweet(_ tweet: Tweet, cell: TweetCell?)
    func toggleBookmark(_ tweet: Tweet, cell: TweetCell?)
    func presentQuote(_ tweet: Tweet)
    func askMenu(for tweet: Tweet) -> UIMenu
}

extension TweetActionHandling {
    func tweetContextMenu(_ tweet: Tweet) -> UIMenu {
        let api = AppEnvironment.shared.api
        let translate = UIAction(title: "Translate", image: DesignSystem.icon("character.bubble")) { [weak self] _ in
            self?.presentStream(title: "Translation") { api.translateStream(tweetID: tweet.restID) }
        }
        let brief = UIAction(title: "Brief author", image: DesignSystem.icon("person.text.rectangle")) { [weak self] _ in
            self?.presentStream(title: "Brief · @\(tweet.author.handle)") {
                api.briefStream(handle: tweet.author.handle)
            }
        }
        let like = UIAction(title: tweet.favorited ? "Unlike" : "Like",
                            image: DesignSystem.icon(tweet.favorited ? "heart.slash" : "heart")) { [weak self] _ in
            self?.toggleLike(tweet, cell: self?.tweetCell(for: tweet))
        }
        let repost = UIAction(title: tweet.retweeted ? "Undo repost" : "Repost",
                              image: DesignSystem.icon("arrow.2.squarepath"),
                              attributes: tweet.retweeted ? [.destructive] : []) { [weak self] _ in
            self?.toggleRetweet(tweet, cell: self?.tweetCell(for: tweet))
        }
        let quote = UIAction(title: "Quote", image: DesignSystem.icon("quote.bubble")) { [weak self] _ in
            self?.presentQuote(tweet)
        }
        let bookmark = UIAction(title: tweet.bookmarked ? "Remove bookmark" : "Bookmark",
                                image: DesignSystem.icon(tweet.bookmarked ? "bookmark.slash" : "bookmark")) { [weak self] _ in
            self?.toggleBookmark(tweet, cell: self?.tweetCell(for: tweet))
        }
        let likers = UIAction(title: "Liked by", image: DesignSystem.icon("heart.text.square")) { [weak self] _ in
            self?.navigationController?.pushViewController(LikersViewController(tweetID: tweet.restID), animated: true)
        }
        let share = UIAction(title: "Share…", image: DesignSystem.icon("square.and.arrow.up")) { [weak self] _ in
            self?.shareTweet(tweet)
        }
        let screenshot = UIAction(title: "Postcard…", image: DesignSystem.icon("photo.badge.plus")) { [weak self] _ in
            self?.presentPostcard(tweet)
        }
        let open = UIAction(title: "Open in X", image: DesignSystem.icon("safari")) { _ in
            if let url = URL(string: tweet.url) { UIApplication.shared.open(url) }
        }
        let copy = UIAction(title: "Copy link", image: DesignSystem.icon("link")) { _ in
            UIPasteboard.general.string = tweet.url
        }
        let copyEmbed = UIAction(title: "Copy embed link", image: DesignSystem.icon("link.badge.plus")) { _ in
            UIPasteboard.general.string = tweet.fixupxURL
        }
        var topLevel: [UIMenuElement] = [askMenu(for: tweet), brief, translate]
        var engagement: [UIMenuElement] = [like, repost, quote, bookmark]
        if isOwnTweet(tweet) { engagement.append(likers) }
        topLevel.append(UIMenu(options: .displayInline, children: engagement))
        if let saveMedia = saveMediaMenu(tweet) { topLevel.append(saveMedia) }
        topLevel.append(UIMenu(options: .displayInline, children: [share, screenshot, open, copy, copyEmbed]))
        return UIMenu(children: topLevel)
    }

    /// "Liked by" only makes sense on your own tweets (X hides others' likers
    /// anyway). Read synchronously from the cached identity — a cold cache right
    /// after launch just hides it for a moment.
    func isOwnTweet(_ tweet: Tweet) -> Bool {
        guard let own = AppEnvironment.shared.currentHandle else { return false }
        return tweet.author.handle.caseInsensitiveCompare(own) == .orderedSame
    }

    /// Presents the postcard composer for `tweet`, wrapped in its own
    /// navigation controller so it carries Cancel / Share bar buttons.
    func presentPostcard(_ tweet: Tweet) {
        let postcard = PostcardViewController(tweet: tweet)
        present(UINavigationController(rootViewController: postcard), animated: true)
    }

    func shareTweet(_ tweet: Tweet) {
        let items: [Any] = [URL(string: tweet.url) ?? URL(string: tweet.fixupxURL) as Any]
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = tweetCell(for: tweet) ?? view
        present(activity, animated: true)
    }
}

extension TweetActionHandling {
    /// Opens the full-screen photo gallery for `tweet` on `start`, growing out
    /// of the tapped tile and retracting to whichever photo is showing when it
    /// closes.
    func presentPhotoViewer(for tweet: Tweet, photoIndices: [Int], startAt start: Int) {
        let sourceCell = tweetCell(for: tweet)
        let source = sourceCell?.mediaSourceView(at: start) ?? sourceCell?.mediaSourceView
        let viewer = MediaViewerViewController(
            tweetID: tweet.restID, photoMediaIndices: photoIndices,
            altTexts: photoIndices.map { tweet.media[$0].altText },
            startIndex: start, placeholder: source?.snapshotImage())
        viewer.enableZoom { [weak self] page in
            guard let cell = self?.tweetCell(for: tweet) else { return nil }
            return cell.mediaSourceView(at: page) ?? cell.mediaSourceView
        }
        present(viewer, animated: true)
    }
}

extension UIView {
    /// A bitmap of the view as it is on screen now, or nil while it has no size.
    func snapshotImage() -> UIImage? {
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }
}

extension UIViewController {
    /// A brief, self-dismissing message — a title-less alert that closes itself
    /// after a second.
    func showToast(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { alert.dismiss(animated: true) }
    }

    /// One Save action for a lone attachment, or a "Save media" submenu with
    /// "Save all (N)" plus a per-item list when a tweet carries several. Each
    /// item's `index` is its RAW `tweet.media` offset (the proxy addresses media
    /// by that flat index, across photos and videos alike).
    func saveMediaMenu(_ tweet: Tweet) -> UIMenuElement? {
        let saveable = tweet.media.enumerated().filter { _, media in
            switch media.kind {
            case .photo, .video, .animatedGif: return true
            default: return false
            }
        }
        guard !saveable.isEmpty else { return nil }
        if saveable.count == 1 {
            let (index, media) = saveable[0]
            return saveItemAction(tweetID: tweet.restID, index: index, isVideo: media.isVideo,
                                  title: media.isVideo ? "Save video" : "Save image")
        }
        let items = saveable.map { (index: $0.offset, isVideo: $0.element.isVideo) }
        let saveAll = UIAction(title: "Save all (\(items.count))",
                               image: DesignSystem.icon("square.and.arrow.down.on.square")) { [weak self] _ in
            self?.saveAllMedia(tweetID: tweet.restID, items: items)
        }
        let perItem = saveable.enumerated().map { position, entry in
            saveItemAction(tweetID: tweet.restID, index: entry.offset, isVideo: entry.element.isVideo,
                           title: "\(entry.element.isVideo ? "Video" : "Image") \(position + 1)")
        }
        return UIMenu(title: "Save media", image: DesignSystem.icon("square.and.arrow.down"),
                      children: [saveAll, UIMenu(options: .displayInline, children: perItem)])
    }

    private func saveItemAction(tweetID: String, index: Int, isVideo: Bool, title: String) -> UIAction {
        UIAction(title: title, image: DesignSystem.icon(isVideo ? "arrow.down.circle" : "square.and.arrow.down")) { [weak self] _ in
            self?.saveMedia(tweetID: tweetID, index: index, isVideo: isVideo)
        }
    }

    private func saveMedia(tweetID: String, index: Int, isVideo: Bool) {
        let url = AppEnvironment.shared.api.mediaURL(tweetID: tweetID, index: index)
        Task {
            do {
                try await MediaSaver.save(from: url, isVideo: isVideo)
                Haptics.success()
                showToast("Saved to Photos")
            } catch {
                AppLogger.shared.warn("save media failed: \(error)", category: .media)
                present(MediaSaver.alert(for: error), animated: true)
            }
        }
    }

    /// Saves every saveable attachment sequentially — one Photos auth prompt,
    /// no parallel proxy hammering — then reports how many landed.
    private func saveAllMedia(tweetID: String, items: [(index: Int, isVideo: Bool)]) {
        let api = AppEnvironment.shared.api
        Task {
            var saved = 0
            var lastError: Error?
            for item in items {
                do {
                    try await MediaSaver.save(from: api.mediaURL(tweetID: tweetID, index: item.index), isVideo: item.isVideo)
                    saved += 1
                } catch {
                    lastError = error
                    AppLogger.shared.warn("save-all item \(item.index) failed: \(error)", category: .media)
                }
            }
            if saved == items.count {
                Haptics.success()
                showToast("Saved \(saved) to Photos")
            } else if saved > 0 {
                Haptics.success()
                showToast("Saved \(saved) of \(items.count)")
            } else {
                Haptics.error()
                present(MediaSaver.alert(for: lastError ?? MediaSaver.Failure.download), animated: true)
            }
        }
    }
}
