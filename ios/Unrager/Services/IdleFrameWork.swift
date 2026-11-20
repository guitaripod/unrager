import QuartzCore
import UIKit

/// Work done in what is left of each frame once the app has drawn it, so it
/// never makes a frame late. A display link keeps the deadline of the frame in
/// flight; after the run loop has committed that frame and is about to sleep,
/// `work` is handed the deadline (less a margin) and does what fits before it,
/// answering whether anything is left. While the screen scrolls a frame has
/// little or nothing left over, so the work waits; at rest it gets most of each
/// frame. A slice of eight milliseconds handed out on the next turn of the main
/// queue, as the board's guessed heights used to be, was a whole 120 Hz frame
/// and made every frame it landed in late.
@MainActor
final class IdleFrameWork: NSObject {
    private let work: @MainActor (CFTimeInterval) -> Bool
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var deadline: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0

    /// The time kept back before each frame's deadline, for the frame's own
    /// start and the system's share of it.
    static let margin: CFTimeInterval = 0.0015

    init(work: @escaping @MainActor (_ deadline: CFTimeInterval) -> Bool) {
        self.work = work
    }

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.idle() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        fallBackUnlessFramesCome()
    }

    /// A main thread that is not turning its run loop draws no frames, so no
    /// deadline comes: a test's, or the app's between its scenes. Whenever a
    /// frame has not come for a while, the work goes on in slices on the main
    /// queue instead, as it did before frames paced it, until frames return.
    private func fallBackUnlessFramesCome() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fallbackDelay) { [weak self] in
            guard let self, self.isRunning else { return }
            guard CACurrentMediaTime() - self.lastFrame > Self.fallbackDelay * 2 else {
                return self.fallBackUnlessFramesCome()
            }
            if self.work(CACurrentMediaTime() + Self.fallbackSlice) {
                self.fallBackUnlessFramesCome()
            } else {
                self.stop()
            }
        }
    }

    static let fallbackDelay: TimeInterval = 0.05
    static let fallbackSlice: CFTimeInterval = 0.008

    func stop() {
        link?.invalidate()
        link = nil
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observer = nil
        deadline = 0
        lastFrame = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        deadline = link.targetTimestamp
        lastFrame = CACurrentMediaTime()
    }

    private func idle() {
        guard deadline > 0 else { return }
        let until = deadline - Self.margin
        guard CACurrentMediaTime() < until else { return }
        if !work(until) { stop() }
    }
}
