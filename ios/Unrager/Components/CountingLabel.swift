import UIKit

/// A label showing a whole number that counts to a new value instead of
/// jumping: an ease-out over a few tenths of a second from whatever it shows
/// now, so a count that changes again part-way carries on from where it is.
/// Off screen, or under Reduce Motion, it simply shows the value. Its timer
/// holds the label only until the count lands, a second at most.
final class CountingLabel: UILabel {
    var format: (Int) -> String = { $0.formatted() }

    private(set) var value = 0
    private var shown = 0.0
    private var origin = 0.0
    private var started: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.6
    private var timer: Timer?

    /// The number on screen `progress` (0...1) of the way from `from` to `to`:
    /// fast at first and settling, so the figure lands rather than stops.
    static func eased(from: Double, to: Double, progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        return from + (to - from) * (1 - pow(1 - t, 3))
    }

    /// Counts to `newValue`, from `start` when given or from what is showing,
    /// beginning after `delay`.
    func setValue(_ newValue: Int, animated: Bool = true, from start: Int? = nil,
                  delay: CFTimeInterval = 0, duration: CFTimeInterval = 0.6) {
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            finish(at: newValue)
            return
        }
        if timer != nil, newValue == value, start == nil { return }
        if timer == nil, newValue == value, start == nil, text != nil { return }
        value = newValue
        origin = start.map(Double.init) ?? shown
        self.duration = duration
        started = CACurrentMediaTime() + delay
        shown = origin
        text = format(Int(origin.rounded()))
        guard timer == nil else { return }
        let ticking = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil,
                            repeats: true)
        RunLoop.main.add(ticking, forMode: .common)
        timer = ticking
    }

    @objc private func tick() {
        let progress = duration > 0 ? (CACurrentMediaTime() - started) / duration : 1
        guard progress < 1 else {
            finish(at: value)
            return
        }
        shown = Self.eased(from: origin, to: Double(value), progress: progress)
        text = format(Int(shown.rounded()))
    }

    private func finish(at newValue: Int) {
        timer?.invalidate()
        timer = nil
        value = newValue
        shown = Double(newValue)
        text = format(newValue)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil, timer != nil { finish(at: value) }
    }
}
