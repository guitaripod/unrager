import UIKit
import UnragerKit

/// The single attachment surface for a tweet. Inspects the tweet's `media` and
/// renders exactly one of: a photo grid, an inline video/GIF player, a poll, or
/// a preview card (link / article / broadcast / YouTube). Subviews are created
/// lazily and toggled on reuse so a recycled cell never shows the wrong kind.
/// `compact` shrinks everything for quoted-tweet contexts. Photos and video run
/// edge to edge when `bleedsEdgeToEdge` is set; cards and polls always keep the
/// side margin.
final class MediaContentView: UIView {
    /// Open the photo viewer at a given attachment index.
    var onTapPhoto: ((Int) -> Void)?
    /// Open a card's external target (link, article, broadcast, YouTube).
    var onTapCard: ((URL) -> Void)?

    /// Whether photos and video use the whole width of the row, square-cornered,
    /// instead of sitting inside the side margin with rounded corners.
    var bleedsEdgeToEdge = false

    private let compact: Bool
    private var grid: PhotoGridView?
    private var player: MediaPlayerView?
    private var poll: PollView?
    private var card: MediaCardView?
    private var activeView: UIView?

    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        insetsLayoutMarginsFromSafeArea = false
        directionalLayoutMargins = .zero
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
    /// Frees the inline player's decoder and buffer once the row leaves the
    /// screen; the poster stays, and playback starts afresh at the next rest.
    func releaseVideo() { player?.releasePlayer() }

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
        guard let rich = Self.pickRich(tweet.media) else {
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
                     target: URL(string: target).flatMap { $0.host == nil ? nil : $0 },
                     contentWidth: contentWidth, imagesEnabled: imagesEnabled)
        case .article(_, let title, let preview):
            showCard(.init(domain: "x.com", title: title, detail: preview,
                           coverURL: imagesEnabled ? URL(string: rich.url) : nil,
                           isLive: false, isPlayable: false),
                     target: URL(string: tweet.url), contentWidth: contentWidth, imagesEnabled: imagesEnabled)
        case .broadcast(let broadcastID, let title, let broadcaster, let isLive):
            showCard(.init(domain: broadcaster, title: title, detail: isLive ? nil : "Broadcast",
                           coverURL: imagesEnabled ? URL(string: rich.url) : nil,
                           isLive: isLive, isPlayable: !isLive, coverRatio: MediaShape.videoCover),
                     target: URL(string: "https://x.com/i/broadcasts/\(broadcastID)"),
                     contentWidth: contentWidth, imagesEnabled: imagesEnabled)
        case .youTube(let videoID):
            showCard(.init(domain: "YouTube", title: "Watch on YouTube",
                           detail: nil, coverURL: imagesEnabled ? URL(string: rich.url) : nil,
                           isLive: false, isPlayable: true, coverRatio: MediaShape.videoCover),
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

    /// The images a full-size (not compact) surface asks for when configured
    /// with `tweet`, at the very sizes it asks for them: a prefetch at any
    /// other size is a separate decode the row can't use or join.
    static func imageRequests(for tweet: Tweet, contentWidth: CGFloat, bleedsEdgeToEdge: Bool) -> [(url: URL, size: CGSize)] {
        guard let rich = pickRich(tweet.media) else { return [] }
        let pictureWidth = contentWidth - (bleedsEdgeToEdge ? 0 : 2 * DesignSystem.Spacing.l)
        switch rich.kind {
        case .poll:
            return []
        case .linkCard, .article, .broadcast, .youTube:
            let width = contentWidth - 2 * DesignSystem.Spacing.l
            guard let url = URL(string: rich.url) else { return [] }
            let ratio: CGFloat
            switch rich.kind {
            case .broadcast, .youTube: ratio = MediaShape.videoCover
            default: ratio = MediaShape.largeCover
            }
            return [(url, MediaCardView.coverSize(contentWidth: width, ratio: ratio))]
        case .video, .animatedGif:
            guard let url = URL(string: rich.url) else { return [] }
            return [(url, posterSize(for: rich, width: pictureWidth))]
        case .photo:
            let photos = tweet.media.filter { if case .photo = $0.kind { return true } else { return false } }
            let urls = photos.compactMap { URL(string: $0.url) }
            let ratios = Array(photos.map(\.aspectRatio).prefix(min(urls.count, PhotoMosaic.maxPhotos)))
            let mosaic = PhotoMosaic.make(ratios: ratios, width: pictureWidth)
            return zip(urls, mosaic.tiles).map { ($0, $1.size) }
        }
    }

    /// The frame an inline clip is drawn in, from its own shape.
    private static func playerFrame(for media: Media) -> MediaShape.Frame {
        MediaShape.frame(source: media.aspectRatio, fallback: 16.0 / 9.0)
    }

    private static func posterSize(for media: Media, width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width / playerFrame(for: media).ratio).rounded())
    }

    /// Prefers the "interesting" attachment: a poll/card/broadcast/youTube
    /// trumps a bare thumbnail, and a video/gif trumps a still photo. Falls
    /// back to the first photo otherwise.
    private static func pickRich(_ media: [Media]) -> Media? {
        media.first(where: { $0.isNonImageCard })
            ?? media.first(where: { $0.isVideo })
            ?? media.first
    }

    private func indexOf(_ target: Media, in media: [Media]) -> Int {
        media.firstIndex(of: target) ?? 0
    }

    /// The side margin around a surface: none for compact (quoted) media or for
    /// photos and video that bleed, the row's margin for everything else.
    private func sideInset(isPicture: Bool) -> CGFloat {
        if compact || (bleedsEdgeToEdge && isPicture) { return 0 }
        return DesignSystem.Spacing.l
    }

    /// Corner radius for a picture surface: square when it runs edge to edge.
    private func pictureRadius(inset: CGFloat) -> CGFloat {
        if compact { return DesignSystem.Radius.control }
        return inset == 0 ? 0 : DesignSystem.Radius.media
    }

    // MARK: - Surfaces

    private func showGrid(_ media: [Media], contentWidth: CGFloat, imagesEnabled: Bool) {
        let photos = media.filter { if case .photo = $0.kind { return true } else { return false } }
        let urls = photos.compactMap { URL(string: $0.url) }
        guard !urls.isEmpty else { hideAll(); isHidden = true; return }
        let view = grid ?? {
            let made = PhotoGridView(frame: .zero)
            grid = made
            return made
        }()
        let inset = sideInset(isPicture: true)
        view.setRounded(pictureRadius(inset: inset))
        view.onTapPhoto = { [weak self] index in self?.onTapPhoto?(index) }
        view.configure(urls: urls, ratios: photos.map(\.aspectRatio), width: contentWidth - 2 * inset,
                       imagesEnabled: imagesEnabled, altTexts: photos.map(\.altText))
        swap(to: view, inset: inset)
    }

    private func showPlayer(tweet: Tweet, media: Media, index: Int, contentWidth: CGFloat, imagesEnabled: Bool) {
        guard let videoURL = media.videoURL.flatMap(URL.init)
            ?? Optional(AppEnvironment.shared.api.mediaURL(tweetID: tweet.restID, index: index)) else {
            showGrid([media], contentWidth: contentWidth, imagesEnabled: imagesEnabled)
            return
        }
        let view = player ?? {
            let made = MediaPlayerView(frame: .zero)
            made.translatesAutoresizingMaskIntoConstraints = false
            made.isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(playerTapped))
            tap.delegate = self
            made.addGestureRecognizer(tap)
            player = made
            return made
        }()
        let isGIF: Bool = { if case .animatedGif = media.kind { return true } else { return false } }()
        let inset = sideInset(isPicture: true)
        let width = contentWidth - 2 * inset
        let frame = Self.playerFrame(for: media)
        view.setRounded(pictureRadius(inset: inset))
        view.configure(posterURL: imagesEnabled ? URL(string: media.url) : nil,
                       videoURL: videoURL, isGIF: isGIF, aspectRatio: frame.ratio, fills: frame.fills,
                       posterSize: Self.posterSize(for: media, width: width),
                       imagesEnabled: imagesEnabled)
        swap(to: view, inset: inset)
    }

    private func showPoll(options: [PollOption], endsAt: Date?, countsFinal: Bool) {
        let view = poll ?? { let made = PollView(frame: .zero); poll = made; return made }()
        view.configure(options: options, endsAt: endsAt, countsFinal: countsFinal)
        swap(to: view, inset: sideInset(isPicture: false))
    }

    private func showCard(_ model: MediaCardView.Model, target: URL?, contentWidth: CGFloat, imagesEnabled: Bool) {
        let view = card ?? { let made = MediaCardView(frame: .zero); card = made; return made }()
        view.onTap = { [weak self] in if let target { self?.onTapCard?(target) } }
        let inset = sideInset(isPicture: false)
        view.configure(model, contentWidth: contentWidth - 2 * inset, imagesEnabled: imagesEnabled)
        view.setOpensLink(target != nil)
        swap(to: view, inset: inset)
    }

    // MARK: - View swapping

    private func swap(to view: UIView, inset: CGFloat) {
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset)
        if activeView === view {
            view.isHidden = false
            return
        }
        activeView?.isHidden = true
        if view.superview !== self {
            view.translatesAutoresizingMaskIntoConstraints = false
            addManaged(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
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
