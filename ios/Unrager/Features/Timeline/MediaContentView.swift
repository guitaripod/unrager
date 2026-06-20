import UIKit
import UnragerKit

/// The single attachment surface for a tweet. Inspects the tweet's `media` and
/// renders exactly one of: a photo grid, an inline video/GIF player, a poll, or
/// a preview card (link / article / broadcast / YouTube). Subviews are created
/// lazily and toggled on reuse so a recycled cell never shows the wrong kind.
/// `compact` shrinks everything for quoted-tweet contexts.
final class MediaContentView: UIView {
    /// Open the photo viewer at a given attachment index.
    var onTapPhoto: ((Int) -> Void)?
    /// Open a card's external target (link, article, broadcast, YouTube).
    var onTapCard: ((URL) -> Void)?

    private let compact: Bool
    private var grid: PhotoGridView?
    private var player: MediaPlayerView?
    private var poll: PollView?
    private var card: MediaCardView?
    private var activeView: UIView?

    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func prepareForReuse() {
        player?.tearDown()
        grid?.prepareForReuse()
        card?.prepareForReuse()
        onTapPhoto = nil
        onTapCard = nil
    }

    /// Whether the currently-shown surface is an inline video/GIF player, so the
    /// feed can decide which one to autoplay at rest.
    var hasVideo: Bool { player != nil && activeView === player }

    func playVideo() { if hasVideo { player?.play() } }
    func pauseVideo() { player?.pause() }

    /// The view to zoom from for the photo at `index` — the exact grid tile, so a
    /// multi-photo tweet grows from the tapped image rather than the whole grid.
    func photoSourceView(at index: Int) -> UIView? {
        grid.flatMap { $0.tileView(at: index) } ?? activeView
    }

    /// Configures (and shows) whichever surface the tweet's media calls for, or
    /// hides itself entirely when there is nothing to render. Returns whether
    /// any media was shown so the cell can collapse the slot.
    @discardableResult
    func configure(with tweet: Tweet, imagesEnabled: Bool, contentWidth: CGFloat) -> Bool {
        guard let rich = pickRich(tweet.media) else {
            hideAll()
            isHidden = true
            return false
        }
        isHidden = false
        switch rich.kind {
        case .poll(let options, let endsAt, let countsFinal):
            showPoll(options: options, endsAt: endsAt, countsFinal: countsFinal)
        case .linkCard(let title, let description, let domain, let target):
            showCard(.init(domain: domain, title: title, detail: description,
                           coverURL: imagesEnabled ? URL(string: rich.url) : nil,
                           isLive: false, isPlayable: false),
                     target: URL(string: target), contentWidth: contentWidth, imagesEnabled: imagesEnabled)
        case .article(_, let title, let preview):
            showCard(.init(domain: "x.com", title: title, detail: preview,
                           coverURL: imagesEnabled ? URL(string: rich.url) : nil,
                           isLive: false, isPlayable: false),
                     target: URL(string: tweet.url), contentWidth: contentWidth, imagesEnabled: imagesEnabled)
        case .broadcast(let broadcastID, let title, let broadcaster, let isLive):
            showCard(.init(domain: broadcaster, title: title, detail: isLive ? nil : "Broadcast",
                           coverURL: imagesEnabled ? URL(string: rich.url) : nil,
                           isLive: isLive, isPlayable: !isLive),
                     target: URL(string: "https://x.com/i/broadcasts/\(broadcastID)"),
                     contentWidth: contentWidth, imagesEnabled: imagesEnabled)
        case .youTube(let videoID):
            showCard(.init(domain: "YouTube", title: tweet.text.isEmpty ? "Watch on YouTube" : tweet.text,
                           detail: nil, coverURL: imagesEnabled ? URL(string: rich.url) : nil,
                           isLive: false, isPlayable: true),
                     target: URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
                     contentWidth: contentWidth, imagesEnabled: imagesEnabled)
        case .video, .animatedGif:
            showPlayer(tweet: tweet, media: rich, index: indexOf(rich, in: tweet.media),
                       contentWidth: contentWidth, imagesEnabled: imagesEnabled)
        case .photo:
            showGrid(tweet.media, contentWidth: contentWidth, imagesEnabled: imagesEnabled)
        }
        return true
    }

    /// Prefers the "interesting" attachment: a poll/card/broadcast/youTube
    /// trumps a bare thumbnail, and a video/gif trumps a still photo. Falls
    /// back to the first photo otherwise.
    private func pickRich(_ media: [Media]) -> Media? {
        media.first(where: { $0.isNonImageCard })
            ?? media.first(where: { $0.isVideo })
            ?? media.first
    }

    private func indexOf(_ target: Media, in media: [Media]) -> Int {
        media.firstIndex(of: target) ?? 0
    }

    /// Clamps a media aspect (width ÷ height) so the inline player is neither a
    /// thin panoramic strip nor a screen-eating portrait column. Defaults to
    /// 16:9 when the server didn't report dimensions.
    private func clampedMediaRatio(_ ratio: CGFloat?) -> CGFloat {
        guard let ratio, ratio > 0 else { return 16.0 / 9.0 }
        return min(max(ratio, 1.0 / 1.3), 2.0)
    }

    // MARK: - Surfaces

    private func showGrid(_ media: [Media], contentWidth: CGFloat, imagesEnabled: Bool) {
        let photos = media.filter { if case .photo = $0.kind { return true } else { return false } }
        let urls = photos.compactMap { URL(string: $0.url) }
        guard !urls.isEmpty else { hideAll(); isHidden = true; return }
        let view = grid ?? {
            let made = PhotoGridView(frame: .zero)
            made.setRounded(compact ? DesignSystem.Radius.control : DesignSystem.Radius.media)
            grid = made
            return made
        }()
        view.onTapPhoto = { [weak self] index in self?.onTapPhoto?(index) }
        let aspect = urls.count == 1 ? photos.first?.aspectRatio : nil
        view.configure(urls: urls, contentWidth: contentWidth, imagesEnabled: imagesEnabled, aspectRatio: aspect)
        swap(to: view)
    }

    private func showPlayer(tweet: Tweet, media: Media, index: Int, contentWidth: CGFloat, imagesEnabled: Bool) {
        guard let videoURL = media.videoURL.flatMap(URL.init)
            ?? Optional(AppEnvironment.shared.api.mediaURL(tweetID: tweet.restID, index: index)) else {
            showGrid([media], contentWidth: contentWidth, imagesEnabled: imagesEnabled)
            return
        }
        let view = player ?? {
            let made = MediaPlayerView(frame: .zero)
            made.setRounded(compact ? DesignSystem.Radius.control : DesignSystem.Radius.media)
            made.translatesAutoresizingMaskIntoConstraints = false
            made.isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(playerTapped))
            tap.delegate = self
            made.addGestureRecognizer(tap)
            player = made
            return made
        }()
        let isGIF: Bool = { if case .animatedGif = media.kind { return true } else { return false } }()
        let ratio = clampedMediaRatio(media.aspectRatio)
        let height = (contentWidth / ratio).rounded()
        view.configure(posterURL: imagesEnabled ? URL(string: media.url) : nil,
                       videoURL: videoURL, isGIF: isGIF, aspectRatio: ratio,
                       posterSize: CGSize(width: contentWidth, height: height), imagesEnabled: imagesEnabled)
        swap(to: view)
    }

    private func showPoll(options: [PollOption], endsAt: Date?, countsFinal: Bool) {
        let view = poll ?? { let made = PollView(frame: .zero); poll = made; return made }()
        view.configure(options: options, endsAt: endsAt, countsFinal: countsFinal)
        swap(to: view)
    }

    private func showCard(_ model: MediaCardView.Model, target: URL?, contentWidth: CGFloat, imagesEnabled: Bool) {
        let view = card ?? { let made = MediaCardView(frame: .zero); card = made; return made }()
        view.onTap = { [weak self] in if let target { self?.onTapCard?(target) } }
        view.configure(model, contentWidth: contentWidth, imagesEnabled: imagesEnabled)
        swap(to: view)
    }

    // MARK: - View swapping

    private func swap(to view: UIView) {
        if activeView === view {
            view.isHidden = false
            return
        }
        activeView?.isHidden = true
        if view.superview !== self {
            view.translatesAutoresizingMaskIntoConstraints = false
            addManaged(view)
            view.pinEdges(to: self)
        }
        view.isHidden = false
        activeView = view
    }

    private func hideAll() {
        player?.tearDown()
        [grid, player, poll, card].compactMap { $0 }.forEach { $0.isHidden = true }
        activeView = nil
    }

    @objc private func playerTapped() { onTapPhoto?(0) }
}

extension MediaContentView: UIGestureRecognizerDelegate {
    /// Lets the inline player's own controls (the mute button) handle their taps
    /// instead of the open-the-viewer tap gesture swallowing them.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
}

private extension Media {
    /// True for the rich preview kinds that get a card surface (poll, link,
    /// article, broadcast, YouTube) rather than an image or inline player.
    var isNonImageCard: Bool {
        switch kind {
        case .photo, .video, .animatedGif: return false
        default: return true
        }
    }
}
