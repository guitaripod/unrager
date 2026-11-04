import UIKit
import UnragerKit

/// The people who liked a post, under the post itself and a ring that splits
/// them by how they stand with the viewer. Followers the viewer hasn't followed
/// back are ringed in amber and offered "Follow back"; chips pinned over the
/// list narrow it to the people who follow you, to those you could follow back,
/// those you follow, or the verified. Tapping a row opens that user's profile.
final class LikersViewController: PagedUserListViewController {
    private let tweetID: String
    private var post: LikedPost
    private var likeCount: Int?
    private var summary: LikersSummary
    private var ringRevealed = false

    private lazy var headerRegistration = UICollectionView.CellRegistration<LikersHeaderCell, String> {
        [weak self] cell, _, _ in
        guard let self else { return }
        cell.onOpenPost = { [weak self] in self?.openPost() }
        cell.onShowFollowBack = { [weak self] in self?.selectLens(LikerLens.followBack.rawValue) }
        let reveal = !self.ringRevealed && self.summary.tally.hasStandings
        if reveal { self.ringRevealed = true }
        cell.configure(post: self.post, summary: self.summary, width: self.view.bounds.width,
                       offersLenses: self.summary.offersLenses, reveal: reveal)
    }

    init(tweetID: String, tweet: Tweet? = nil) {
        self.tweetID = tweetID
        self.post = LikedPost(tweet: tweet)
        self.likeCount = tweet?.likeCount
        self.summary = LikersSummary(likeCount: tweet?.likeCount, rows: [], loading: true)
        super.init(nibName: nil, bundle: nil)
        title = "Liked by"
    }

    /// The likes of a post known only by what a notification says about it.
    init(tweetID: String, likeCount: Int?, snippet: String?) {
        self.tweetID = tweetID
        self.post = LikedPost(snippet: snippet.flatMap(Self.post(from:)))
        self.likeCount = likeCount
        self.summary = LikersSummary(likeCount: likeCount, rows: [], loading: true)
        super.init(nibName: nil, bundle: nil)
        title = "Liked by"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var hasHeader: Bool { true }
    override var showsDetail: Bool { true }
    override var supportsLens: Bool { true }

    override var emptyCopy: EmptyCopy {
        EmptyCopy(symbol: "heart", title: "No likes yet",
                  subtitle: "Nobody has liked this post, or X isn't sharing the list.")
    }

    override var logCategory: LogCategory { .timeline }

    override func viewDidLoad() {
        _ = headerRegistration
        super.viewDidLoad()
        fetchPostIfNeeded()
    }

    override func headerCell(in collectionView: UICollectionView, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: headerRegistration, for: indexPath, item: "likers-header")
    }

    override func fetchPage(cursor: String?) async throws -> Page {
        let page = try await AppEnvironment.shared.api.likers(tweetID: tweetID, cursor: cursor)
        let shown = (cursor == nil ? 0 : order.count) + page.users.count
        return Page(users: page.users, cursor: page.cursor, endNote: Self.endNote(shown: shown, of: likeCount))
    }

    override func peopleDidChange() {
        updateSummary(force: false)
    }

    /// Redraws the header from the loaded people, or from `force` when the post
    /// or its like count changed under the same people.
    private func updateSummary(force: Bool) {
        let next = LikersSummary(likeCount: likeCount, rows: loadedRows, loading: isLoadingFirstPage)
        guard force || next != summary else { return }
        summary = next
        reloadHeader()
    }

    /// All, then the ways to narrow the loaded people that leave anyone: the
    /// standings only once the list says them. Shown once there are people
    /// enough to narrow, or while a lens is chosen.
    override var lensChips: [LensChip] {
        if summary.isPlaceholder, (likeCount ?? 0) >= LikersSummary.minimumForLenses { return LensChip.placeholders }
        guard summary.offersLenses || lens != nil else { return [] }
        let tally = summary.tally
        let candidates = tally.hasStandings ? LikerLens.allCases : [.everyone, .verified]
        return candidates.compactMap { candidate in
            let count = candidate.count(in: tally)
            guard candidate == .everyone || count > 0 || candidate.rawValue == lens else { return nil }
            return LensChip(id: candidate.rawValue, title: candidate.title, count: count, tint: candidate.tint)
        }
    }

    override func includes(_ row: UserRow, lens: String) -> Bool {
        LikerLens(rawValue: lens)?.includes(row) ?? true
    }

    override func emptyLensNote(_ lens: String) -> String {
        LikerLens(rawValue: lens)?.emptyNote(listed: summary.tally.listed) ?? "Nobody to show."
    }

    // MARK: - Post

    /// A list opened from a notification knows only a snippet: fetch the whole
    /// post so the header can show who wrote it and what it carries.
    private func fetchPostIfNeeded() {
        guard post.tweet == nil else { return }
        Task { [weak self, tweetID] in
            let tweet: Tweet
            do {
                tweet = try await AppEnvironment.shared.api.tweet(id: tweetID)
            } catch {
                AppLogger.shared.warn("liked post \(tweetID) unavailable for the header: \(error)", category: .profile)
                return
            }
            guard let self else { return }
            self.post = LikedPost(tweet: tweet)
            self.likeCount = tweet.likeCount
            self.updateSummary(force: true)
        }
    }

    /// Opens the post, or goes back to it when the list was opened from it.
    private func openPost() {
        guard let navigationController else { return }
        let stack = navigationController.viewControllers
        if stack.count >= 2, let thread = stack[stack.count - 2] as? ThreadViewController, thread.tweetID == tweetID {
            navigationController.popViewController(animated: true)
            return
        }
        let thread = post.tweet.map(ThreadViewController.init(tweet:)) ?? ThreadViewController(tweetID: tweetID)
        navigationController.pushViewController(thread, animated: true)
    }

    // MARK: - Pure pieces

    /// `text` on one line, or nil when there is none.
    static func post(from text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    /// Said under the last row when X lists fewer people than the post has
    /// likes, so a short list isn't taken for everyone.
    static func endNote(shown: Int, of total: Int?) -> String? {
        guard let total, total > shown, shown > 0 else { return nil }
        return "X lists \(shown.formatted()) of the \(total.formatted()) people who liked this."
    }
}

#if DEBUG
extension LikersViewController {
    /// Screenshot hook: chooses a lens as a tap on its chip would.
    func debugSelectLens(_ lens: LikerLens) { selectLens(lens.rawValue) }
}
#endif
