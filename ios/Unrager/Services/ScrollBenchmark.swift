import QuartzCore
import UIKit
import UnragerKit

/// Named stopwatches for the hot paths of the feed, collected only while a
/// scroll benchmark runs so they cost one boolean check the rest of the time.
@MainActor
enum PerfProbe {
    private(set) static var isRecording = false
    private static var samples: [String: [Double]] = [:]

    static func begin() {
        samples.removeAll()
        isRecording = true
    }

    static func end() -> [String: [Double]] {
        isRecording = false
        defer { samples.removeAll() }
        return samples
    }

    @inline(__always)
    static func time<T>(_ name: String, _ body: () -> T) -> T {
        guard isRecording else { return body() }
        let start = CACurrentMediaTime()
        let result = body()
        samples[name, default: []].append((CACurrentMediaTime() - start) * 1000)
        return result
    }
}

/// A scripted scroll through a feed that measures how smoothly it goes: the
/// time between frames, how much of it was lost to hitches, and what the
/// feed's own work cost. It only runs when the app is launched with
/// `UNRAGER_BENCH_SCROLL` set, and writes its result to the app log, so a
/// build on the phone can be measured without a debugger attached.
@MainActor
final class ScrollBenchmark: NSObject {
    static let shared = ScrollBenchmark()

    /// Points per second for each phase: a reading pace, then a fast flick.
    private static let phases: [(name: String, speed: CGFloat, seconds: Double)] = [
        ("reading", 450, 6), ("flick", 1500, 8),
    ]

    static var isRequested: Bool { ProcessInfo.processInfo.environment["UNRAGER_BENCH_SCROLL"] != nil }

    private weak var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private var phaseIndex = 0
    private var phaseStart: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var running = false

    /// Waits for the feed to fill, then plays the phases once.
    func start(on scrollView: UIScrollView, itemCount: @escaping () -> Int) {
        guard !running else { return }
        running = true
        self.scrollView = scrollView
        waitForContent(itemCount: itemCount, attempts: 60)
    }

    private func waitForContent(itemCount: @escaping () -> Int, attempts: Int) {
        guard itemCount() >= 12 || attempts == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.waitForContent(itemCount: itemCount, attempts: attempts - 1)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.beginPhase(0) }
    }

    private func beginPhase(_ index: Int) {
        guard let scrollView, index < Self.phases.count else { running = false; return }
        phaseIndex = index
        intervals.removeAll()
        lastTimestamp = 0
        phaseStart = CACurrentMediaTime()
        scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
        PerfProbe.begin()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scrollView else { finishPhase(link); return }
        let phase = Self.phases[phaseIndex]
        if lastTimestamp > 0 {
            let dt = link.timestamp - lastTimestamp
            intervals.append(dt * 1000)
            let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            let next = scrollView.contentOffset.y + phase.speed * CGFloat(dt)
            scrollView.contentOffset.y = min(next, max(bottom, -scrollView.adjustedContentInset.top))
        }
        lastTimestamp = link.timestamp
        if CACurrentMediaTime() - phaseStart >= phase.seconds { finishPhase(link) }
    }

    private func finishPhase(_ link: CADisplayLink) {
        link.invalidate()
        self.link = nil
        let phase = Self.phases[phaseIndex]
        if let scrollView { scrollView.delegate?.scrollViewDidEndDecelerating?(scrollView) }
        let probes = PerfProbe.end()
        let refresh = intervals.sorted()[intervals.count / 2]
        AppLogger.shared.info(Self.report(phase: phase.name, intervals: intervals, refreshMs: refresh,
                                          seconds: phase.seconds, probes: probes), category: .ui)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.beginPhase(self.phaseIndex + 1)
        }
    }

    /// One line per phase: frames, how many ran long, the lost time per second
    /// (Apple's "hitch time ratio"), the worst frames, and each probe's count,
    /// average, 95th percentile and worst.
    nonisolated static func report(
        phase: String, intervals: [Double], refreshMs: Double, seconds: Double, probes: [String: [Double]]
    ) -> String {
        let sorted = intervals.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let hitchMs = intervals.reduce(0) { $0 + max(0, $1 - refreshMs * 1.5) }
        let long = intervals.filter { $0 > refreshMs * 1.5 }.count
        let veryLong = intervals.filter { $0 > refreshMs * 3 }.count
        var line = String(
            format: "scroll-bench %@: frames=%d fps=%.0f long=%d veryLong=%d hitch=%.1fms/s p50=%.1f p95=%.1f p99=%.1f worst=%.1fms",
            phase, intervals.count, Double(intervals.count) / seconds, long, veryLong, hitchMs / seconds,
            percentile(0.5), percentile(0.95), percentile(0.99), sorted.last ?? 0)
        for (name, values) in probes.sorted(by: { $0.key < $1.key }) where !values.isEmpty {
            let ordered = values.sorted()
            line += String(format: " | %@ n=%d avg=%.2f p95=%.2f max=%.2f", name, values.count,
                           values.reduce(0, +) / Double(values.count),
                           ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))], ordered.last ?? 0)
        }
        return line
    }
}
