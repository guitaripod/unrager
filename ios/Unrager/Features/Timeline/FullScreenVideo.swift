import AVKit
import UIKit

/// The system player for a video opened full screen. Its soundtrack ducks the
/// user's other audio while it is up, and closing it gives that audio back.
final class FullScreenVideoController: AVPlayerViewController {
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed else { return }
        player?.pause()
        MediaAudioSession.deactivate()
    }
}

extension UIViewController {
    /// Plays `url` full screen with the system controls.
    func presentFullScreenVideo(_ url: URL) {
        MediaAudioSession.activateFullScreen()
        let player = AVPlayer(url: url)
        let controller = FullScreenVideoController()
        controller.player = player
        present(controller, animated: true) { player.play() }
    }
}
