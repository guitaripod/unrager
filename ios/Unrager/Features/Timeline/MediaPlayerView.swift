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

    /// Session-wide inline-audio preference. Inline clips autoplay muted (like
    /// X); tapping any clip's speaker unmutes them all for the session and
    /// switches the audio session to `.playback`. Resets to muted on relaunch.
    static var audioEnabled = false

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private let poster = AsyncImageView(frame: .zero)
    private let playBadge = UIImageView()
    private let gifBadge = UILabel()
    private let muteButton = UIButton(type: .system)
    private var player: AVPlayer?
    private var pendingVideoURL: URL?
    private var isGIF = false
    private var statusObservation: NSKeyValueObservation?
    private nonisolated(unsafe) var loopObserver: (any NSObjectProtocol)?
    private var aspectConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        setAspectRatio(16.0 / 9.0)

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

        var config = UIButton.Configuration.plain()
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        config.background.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        config.baseForegroundColor = .white
        muteButton.configuration = config
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.isHidden = true
        muteButton.addAction(UIAction { [weak self] _ in self?.toggleMute() }, for: .touchUpInside)
        addManaged(muteButton)

        NSLayoutConstraint.activate([
            playBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            gifBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            gifBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            gifBadge.widthAnchor.constraint(equalToConstant: 34),
            gifBadge.heightAnchor.constraint(equalToConstant: 18),
            muteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            muteButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            muteButton.widthAnchor.constraint(equalToConstant: 32),
            muteButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    /// Flips the session-wide inline-audio preference, applies it to the live
    /// player, and switches the audio session to `.playback` so sound is audible
    /// even with the ring switch on.
    private func toggleMute() {
        Self.audioEnabled.toggle()
        if Self.audioEnabled { MediaAudioSession.activatePlayback() }
        player?.isMuted = !Self.audioEnabled
        updateMuteIcon()
    }

    private func updateMuteIcon() {
        let symbol = Self.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
        muteButton.configuration?.image = DesignSystem.icon(symbol, pointSize: 13, weight: .semibold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setRounded(_ radius: CGFloat) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
    }

    /// Sizes the player box from a width ÷ height aspect by replacing the
    /// height-to-width constraint (cheaper than mutating a multiplier and avoids
    /// stale priorities on reuse). The clip itself stays `.resizeAspect`, so it
    /// fits the box without cropping.
    func setAspectRatio(_ ratio: CGFloat) {
        aspectConstraint?.isActive = false
        let safe = ratio > 0 ? ratio : 16.0 / 9.0
        let constraint = heightAnchor.constraint(equalTo: widthAnchor, multiplier: 1.0 / safe)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        aspectConstraint = constraint
    }

    /// Shows the poster and remembers the clip, but creates NO `AVPlayer` and
    /// starts NO decode — so scrolling a video cell into view costs nothing.
    /// Playback begins only when `play()` is called (by the feed once it's at
    /// rest and this is the focused clip).
    func configure(posterURL: URL?, videoURL: URL, isGIF: Bool, aspectRatio: CGFloat,
                   posterSize: CGSize, imagesEnabled: Bool) {
        tearDown()
        setAspectRatio(aspectRatio)
        pendingVideoURL = videoURL
        self.isGIF = isGIF
        gifBadge.isHidden = !isGIF
        playBadge.isHidden = false
        muteButton.isHidden = isGIF
        updateMuteIcon()
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
        if Self.audioEnabled, !isGIF { MediaAudioSession.activatePlayback() }
        if player == nil {
            let player = AVPlayer(url: url)
            player.isMuted = isGIF || !Self.audioEnabled
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
        muteButton.isHidden = true
    }

    deinit {
        statusObservation?.invalidate()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }
}
