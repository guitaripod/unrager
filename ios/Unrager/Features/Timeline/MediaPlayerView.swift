import AVFoundation
import UIKit
import UnragerKit

/// Inline, autoplaying video surface backed by a streamed `AVPlayer`. Streams
/// from the server media proxy (which forwards real `video/mp4` bytes), shows
/// the poster image until the first frame is ready, loops forever, and stays
/// muted. The box takes the clip's own shape up to `MediaShape`'s limit, so
/// the picture fills it with no bars. A clip taller than the box is shown whole
/// (`.resizeAspect`) over a blurred copy of its poster rather than over black,
/// unless it only needs a slight crop to fill. Reuse-safe: `tearDown()`
/// releases the player and its observers so a recycled cell never plays the
/// previous tweet's clip.
final class MediaPlayerView: UIView {

    /// Session-wide inline-audio preference. Inline clips autoplay muted (like
    /// X); tapping any clip's speaker unmutes them all for the session and
    /// switches the audio session to `.playback`. Resets to muted on relaunch.
    static var audioEnabled = false

    private let host = PlayerHostView()
    private var playerLayer: AVPlayerLayer { host.playerLayer }
    private let ambient = UIImageView()
    private var ambientTask: Task<Void, Never>?
    private let poster = AsyncImageView(frame: .zero)
    private let playBadge = UIImageView()
    private let gifBadge = UILabel()
    private let muteButton = HitSlopButton(type: .system)
    private var player: AVPlayer?
    private var pendingVideoURL: URL?
    private var isGIF = false
    private var statusObservation: NSKeyValueObservation?
    private var displayObservation: NSKeyValueObservation?
    private nonisolated(unsafe) var loopObserver: (any NSObjectProtocol)?
    private var aspectConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIgnoresInvertColors = true
        clipsToBounds = true
        backgroundColor = .black
        setAspectRatio(16.0 / 9.0)

        ambient.contentMode = .scaleAspectFill
        ambient.clipsToBounds = true
        ambient.isHidden = true
        ambient.translatesAutoresizingMaskIntoConstraints = false
        addManaged(ambient)
        ambient.pinEdges(to: self)
        host.translatesAutoresizingMaskIntoConstraints = false
        addManaged(host)
        host.pinEdges(to: self)
        poster.translatesAutoresizingMaskIntoConstraints = false
        addManaged(poster)
        poster.pinEdges(to: self)

        playBadge.image = DesignSystem.icon("play.circle.fill", pointSize: 44)
        playBadge.tintColor = .white
        playBadge.translatesAutoresizingMaskIntoConstraints = false
        addManaged(playBadge)

        gifBadge.text = "GIF"
        gifBadge.font = DesignSystem.Typography.system(11, weight: .bold)
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
    /// even with the ring switch on — or, muting again, back to the passive one.
    private func toggleMute() {
        Self.audioEnabled.toggle()
        if Self.audioEnabled { MediaAudioSession.activatePlayback() } else { MediaAudioSession.deactivate() }
        player?.isMuted = !Self.audioEnabled
        updateMuteIcon()
    }

    private func updateMuteIcon() {
        let symbol = Self.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
        muteButton.configuration?.image = DesignSystem.icon(symbol, pointSize: 13, weight: .semibold)
        muteButton.accessibilityLabel = Self.audioEnabled ? "Mute" : "Unmute"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setRounded(_ radius: CGFloat) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
    }

    /// Sizes the player box from a width ÷ height aspect by replacing the
    /// height-to-width constraint (cheaper than mutating a multiplier and avoids
    /// stale priorities on reuse). The clip fills the box, which already has its
    /// shape, so no black shows around it.
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
    /// rest and this is the focused clip). Configuring the same clip again
    /// while its player is live (a like, an expanded body or newly loaded emoji
    /// re-rendering the row) only reshapes the box, so playback and sound
    /// carry on where they were.
    func configure(posterURL: URL?, videoURL: URL, isGIF: Bool, aspectRatio: CGFloat, fills: Bool,
                   posterSize: CGSize, imagesEnabled: Bool) {
        if videoURL == pendingVideoURL, player != nil, isGIF == self.isGIF {
            applyShape(aspectRatio: aspectRatio, fills: fills)
            updateMuteIcon()
            return
        }
        tearDown()
        applyShape(aspectRatio: aspectRatio, fills: fills)
        poster.onLoad = fills ? nil : { [weak self] image in self?.softenBackdrop(from: image, key: posterURL) }
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

    private func applyShape(aspectRatio: CGFloat, fills: Bool) {
        setAspectRatio(aspectRatio)
        playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
        poster.contentMode = fills ? .scaleAspectFill : .scaleAspectFit
        ambient.isHidden = fills
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
            observeReadiness(of: player)
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

    /// Fades the poster only once the layer has a decoded frame to show (a
    /// player that is merely `readyToPlay` may still be buffering on a slow
    /// link, which would leave a black box), and brings the poster back if the
    /// clip fails to load.
    private func observeReadiness(of player: AVPlayer) {
        displayObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in self?.firstFrameReady() }
        }
        statusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.playbackFailed() }
        }
    }

    private func firstFrameReady() {
        guard player != nil, playerLayer.isReadyForDisplay else { return }
        UIView.animate(withDuration: 0.2) { self.poster.alpha = 0 }
        playBadge.isHidden = true
    }

    private func playbackFailed() {
        guard player != nil else { return }
        AppLogger.shared.warn("inline video failed to load", category: .timeline)
        poster.layer.removeAllAnimations()
        poster.alpha = 1
        playBadge.isHidden = false
    }

    private func softenBackdrop(from image: UIImage, key: URL?) {
        ambientTask?.cancel()
        ambientTask = Task { [weak self] in
            let soft = await SoftImage.blurred(image, key: key?.absoluteString ?? "poster-\(image.hash)")
            guard !Task.isCancelled else { return }
            self?.ambient.image = soft
        }
    }

    /// Drops the player, its buffered item and observers while keeping the
    /// poster and the clip's address, so an off-screen row holds no decoder
    /// and starts again from its poster when it next comes to rest on screen.
    func releasePlayer() {
        displayObservation?.invalidate()
        displayObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        player?.pause()
        player = nil
        playerLayer.player = nil
        poster.layer.removeAllAnimations()
        poster.alpha = 1
        playBadge.isHidden = false
    }

    func tearDown() {
        ambientTask?.cancel()
        releasePlayer()
        pendingVideoURL = nil
        poster.cancel()
        muteButton.isHidden = true
    }

    deinit {
        statusObservation?.invalidate()
        displayObservation?.invalidate()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }
}

/// A view whose layer is the `AVPlayerLayer`, so the video can sit between the
/// soft backdrop behind it and the poster in front.
private final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// A button whose touch target reaches past its visible bounds, so a small
/// control drawn over video still meets the 44 pt minimum without growing.
private final class HitSlopButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (44 - bounds.width) / 2)
        let dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}
