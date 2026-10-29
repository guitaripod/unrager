import AVKit
import UIKit

/// The system player for a video opened full screen. Its soundtrack ducks the
/// user's other audio while it is up, and closing it gives that audio back.
/// A GIF has no soundtrack, so it leaves the user's audio alone and repeats
/// like it does inline.
final class FullScreenVideoController: AVPlayerViewController {
    private var loopObserver: NSObjectProtocol?
    private var duckedAudio = false

    /// Starts `player` full screen; `isGIF` makes it loop and keeps the user's
    /// audio playing.
    func attach(_ player: AVPlayer, isGIF: Bool) {
        self.player = player
        duckedAudio = !isGIF
        guard isGIF else { return }
        player.isMuted = true
        player.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed else { return }
        player?.pause()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        if duckedAudio { MediaAudioSession.deactivate() }
    }
}

extension UIViewController {
    /// Plays `url` full screen with the system controls.
    func presentFullScreenVideo(_ url: URL, isGIF: Bool = false) {
        if !isGIF { MediaAudioSession.activateFullScreen() }
        let player = AVPlayer(url: url)
        let controller = FullScreenVideoController()
        controller.attach(player, isGIF: isGIF)
        present(controller, animated: true) { player.play() }
    }
}
