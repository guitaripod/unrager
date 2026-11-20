#if DEBUG && targetEnvironment(simulator)
import UIKit

/// A stand-in for a window of another size, because a simulator can't resize
/// or rotate an iPad window from a script. `UNRAGER_WINDOW_SIZE=WxH` hosts the
/// app at exactly that size, scaled down to fit the screen when it is bigger,
/// with the horizontal size class an iPad window that wide gets. A suffix of
/// `@left` or `@right` puts the window against that edge of the screen, the way
/// a window sharing the screen sits, so the outer-edge placement can be seen.
final class DebugWindowFrame: UIViewController {
    private let content: UIViewController
    private var size: CGSize
    private let edge: String?

    static func wrapIfRequested(_ content: UIViewController) -> UIViewController {
        guard let request = requested else { return content }
        return DebugWindowFrame(content: content, size: request.size, edge: request.edge)
    }

    private static var requested: (size: CGSize, edge: String?)? {
        let raw = ProcessInfo.processInfo.environment["UNRAGER_WINDOW_SIZE"] ?? ""
        let pieces = raw.split(separator: "@", maxSplits: 1).map(String.init)
        let numbers = (pieces.first ?? "").split(separator: "x").compactMap { Double($0) }
        guard numbers.count == 2, numbers[0] > 0, numbers[1] > 0 else { return nil }
        return (CGSize(width: numbers[0], height: numbers[1]), pieces.count > 1 ? pieces[1] : nil)
    }

    private init(content: UIViewController, size: CGSize, edge: String?) {
        self.content = content
        self.size = size
        self.edge = edge
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var childForStatusBarStyle: UIViewController? { content }
    override var childForStatusBarHidden: UIViewController? { content }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .darkGray
        content.traitOverrides.horizontalSizeClass = size.width >= 640 ? .regular : .compact
        addChild(content)
        view.addSubview(content.view)
        content.didMove(toParent: self)
        stepBench(ResizeTimer.benchSizes)
    }

    /// Walks the window through `sizes`, four seconds apart, timing each.
    private func stepBench(_ sizes: [CGSize]) {
        guard let next = sizes.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            ResizeTimer.shared.begin(next)
            self.size = next
            self.content.traitOverrides.horizontalSizeClass = next.width >= 640 ? .regular : .compact
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            self.stepBench(Array(sizes.dropFirst()))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let room = view.bounds.inset(by: UIEdgeInsets(top: view.safeAreaInsets.top, left: 0, bottom: 0, right: 0))
        let scale = min(1, room.width / size.width, room.height / size.height)
        let shown = CGSize(width: size.width * scale, height: size.height * scale)
        let x: CGFloat = switch edge {
        case "left": room.minX + shown.width / 2
        case "right": room.maxX - shown.width / 2
        default: room.midX
        }
        content.view.transform = .identity
        content.view.bounds = CGRect(origin: .zero, size: size)
        content.view.center = CGPoint(x: x, y: room.midY)
        content.view.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}
#endif
