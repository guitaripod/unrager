import AVFoundation
import UIKit

/// Inline, autoplaying video surface backed by a streamed `AVPlayer`. Streams
/// from the server media proxy (which forwards real `video/mp4` bytes), shows
/// the poster image until the first frame is ready, loops forever, and stays
/// muted. The clip is letterboxed (`videoGravity = .resizeAspect`) so it scales
/// to fit without cropping, matching X's inline player. Reuse-safe:
/// `tearDown()` releases the player and its observers so a recycled cell never
/// plays the previous tweet's clip.
final class MediaPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private let poster = AsyncImageView(frame: .zero)
    private let playBadge = UIImageView()
    private let gifBadge = UILabel()
    private var player: AVPlayer?
    private var pendingVideoURL: URL?
    private var isGIF = false
    private var statusObservation: NSKeyValueObservation?
    private nonisolated(unsafe) var loopObserver: (any NSObjectProtocol)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        let aspect = heightAnchor.constraint(equalTo: widthAnchor, multiplier: 9.0 / 16.0)
        aspect.priority = .defaultHigh
        aspect.isActive = true

        poster.translatesAutoresizingMaskIntoConstraints = false
        addManaged(poster)
        poster.pinEdges(to: self)

        playBadge.image = DesignSystem.icon("play.circle.fill", pointSize: 44)
        playBadge.tintColor = .white
        playBadge.translatesAutoresizingMaskIntoConstraints = false
        addManaged(playBadge)

        gifBadge.text = "GIF"
        gifBadge.font = .systemFont(ofSize: 11, weight: .bold)
        gifBadge.textColor = .white
        gifBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        gifBadge.textAlignment = .center
        gifBadge.layer.cornerRadius = 4
        gifBadge.layer.masksToBounds = true
        gifBadge.isHidden = true
        addManaged(gifBadge)

        NSLayoutConstraint.activate([
            playBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            gifBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            gifBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            gifBadge.widthAnchor.constraint(equalToConstant: 34),
            gifBadge.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setRounded(_ radius: CGFloat) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
    }

    /// Shows the poster and remembers the clip, but creates NO `AVPlayer` and
    /// starts NO decode — so scrolling a video cell into view costs nothing.
    /// Playback begins only when `play()` is called (by the feed once it's at
    /// rest and this is the focused clip).
    func configure(posterURL: URL?, videoURL: URL, isGIF: Bool, posterSize: CGSize, imagesEnabled: Bool) {
        tearDown()
        pendingVideoURL = videoURL
        self.isGIF = isGIF
        gifBadge.isHidden = !isGIF
        playBadge.isHidden = false
        if imagesEnabled {
            poster.load(url: posterURL, targetSize: posterSize)
        } else {
            poster.cancel()
        }
    }

    /// Lazily creates the player on first call (off the scroll path), loops
    /// forever, plays muted. Cheap to call repeatedly — resumes an existing player.
    func play() {
        guard let url = pendingVideoURL else { return }
        if player == nil {
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.actionAtItemEnd = .none
            self.player = player
            playerLayer.player = player
            statusObservation = player.observe(\.status, options: [.new]) { [weak self] player, _ in
                guard player.status == .readyToPlay else { return }
                Task { @MainActor in self?.firstFrameReady() }
            }
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem, queue: .main) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }
        player?.play()
    }

    func pause() { player?.pause() }

    private func firstFrameReady() {
        UIView.animate(withDuration: 0.2) { self.poster.alpha = 0 }
        playBadge.isHidden = true
    }

    func tearDown() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        player?.pause()
        player = nil
        playerLayer.player = nil
        poster.cancel()
        poster.alpha = 1
        playBadge.isHidden = false
    }

    deinit {
        statusObservation?.invalidate()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }
}
