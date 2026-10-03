import UIKit
import UnragerKit

/// Which inline clip plays in a list of posts: the one with the most of itself
/// on screen, once the list is at rest, never while it is being scrolled. A
/// post's quoted clip competes on the same terms as its own, so a quoted video
/// plays wherever a posted one would. Every list of `TweetCell`s settles
/// through here, whether a feed, a profile or a thread opened from a
/// notification.
@MainActor
enum InlineVideoPlayback {
    /// How much of a clip must be in view for it to start: a sliver peeking
    /// under the bar stays a poster.
    static let minimumShare: CGFloat = 0.4

    /// Whether clips may start on their own: not with the system's video
    /// autoplay switched off, Reduce Motion on, or images switched off in the
    /// app, where a clip would pull its poster and stream regardless.
    static var isAllowed: Bool {
        UIAccessibility.isVideoAutoplayEnabled && !UIAccessibility.isReduceMotionEnabled && AppSettings.imagesEnabled
    }

    static func pauseAll(in collectionView: UICollectionView) {
        for case let cell as TweetCell in collectionView.visibleCells { cell.pauseVideo() }
    }

    /// Plays the most visible clip and pauses the rest; with `isShowing` false
    /// (the list is covered or the app is in the background), or autoplay off,
    /// pauses them all.
    static func settle(in collectionView: UICollectionView, isShowing: Bool) {
        guard isAllowed, isShowing else {
            pauseAll(in: collectionView)
            return
        }
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        var clips: [(surface: MediaContentView, visible: CGFloat)] = []
        for case let cell as TweetCell in collectionView.visibleCells {
            for surface in cell.videoSurfaces {
                let frame = surface.convert(surface.bounds, to: collectionView)
                let shown = frame.intersection(viewport)
                let share = shown.isNull || frame.height <= 0 ? 0 : shown.height / frame.height
                clips.append((surface, share >= minimumShare ? shown.height : 0))
            }
        }
        let best = clips.max { $0.visible < $1.visible }
        for clip in clips {
            if clip.surface === best?.surface, clip.visible > 0 {
                clip.surface.playVideo()
            } else {
                clip.surface.pauseVideo()
            }
        }
    }
}
