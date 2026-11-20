#if DEBUG
import QuartzCore
import UIKit
import UnragerKit

/// Times how long a window keeps the reader waiting after a resize: from the
/// moment the size is asked for to the first frame the main thread is free to
/// draw at it. iPadOS shows the app's last frame stretched into the new tile
/// until then, so this is the length of time a split looks crushed. Logged as
/// `resize WxH first frame N ms`; `UNRAGER_RESIZE_BENCH=WxH,WxH,…` steps a
/// `UNRAGER_WINDOW_SIZE` window through those sizes four seconds apart.
@MainActor
final class ResizeTimer: NSObject {
    static let shared = ResizeTimer()

    private var started: CFTimeInterval = 0
    private var size: CGSize = .zero
    private var link: CADisplayLink?
    private var measured = 0
    private var measuring: CFTimeInterval = 0

    /// Adds one post measured for the board, and how long it took.
    func noteMeasure(_ seconds: CFTimeInterval, configuring: CFTimeInterval = 0) {
        measured += 1
        measuring += seconds
        configuringTime += configuring
    }
    private var configuringTime: CFTimeInterval = 0

    func begin(_ size: CGSize) {
        started = CACurrentMediaTime()
        self.size = size
        measured = 0
        measuring = 0
        configuringTime = 0
        committed = nil
        link?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_001
        ) { _, _ in
            MainActor.assumeIsolated {
                ResizeTimer.shared.committed = (CACurrentMediaTime() - ResizeTimer.shared.started) * 1000
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// When the run loop finished the turn that laid the new size out and
    /// committed it to the screen.
    private var committed: Double?

    @objc private func tick(_ link: CADisplayLink) {
        link.invalidate()
        self.link = nil
        let elapsed = (CACurrentMediaTime() - started) * 1000
        AppLogger.shared.info(
            "resize \(Int(size.width))x\(Int(size.height)) committed \(Int((committed ?? -1).rounded())) ms, "
            + "first frame \(Int(elapsed.rounded())) ms, "
            + "\(measured) posts measured in \(Int((measuring * 1000).rounded())) ms "
            + "(configuring \(Int((configuringTime * 1000).rounded())) ms)", category: .app)
    }

    static var benchSizes: [CGSize] {
        (ProcessInfo.processInfo.environment["UNRAGER_RESIZE_BENCH"] ?? "")
            .split(separator: ",")
            .compactMap { step -> CGSize? in
                let sides = step.split(separator: "x").compactMap { Double($0) }
                return sides.count == 2 ? CGSize(width: sides[0], height: sides[1]) : nil
            }
    }
}
#endif
