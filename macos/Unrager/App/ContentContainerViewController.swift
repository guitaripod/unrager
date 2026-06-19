import AppKit
import UnragerKit

/// A content root that wants to react when it becomes visible again — e.g. after
/// a pushed thread is popped off the navigation stack — so it can refresh.
@MainActor
protocol ContentReappearing: AnyObject {
    func viewBecameVisible()
}

/// A view controller whose on-screen text must re-render in place when the
/// user's text-size choice changes (the window broadcasts `fontScaleDidChange`).
@MainActor
protocol Restylable: AnyObject {
    func restyle()
}

/// Hosts the main content area as a simple navigation stack: the selected
/// source's root view controller sits at the bottom, and threads / profiles
/// push on top. The window controller drives `setRoot` on source switches and
/// uses `canGoBack` / `pop` to wire the toolbar back button.
@MainActor
final class ContentContainerViewController: NSViewController {
    /// Reports stack changes so the toolbar can update its back button + title.
    var onStackChange: (() -> Void)?

    private(set) var stack: [NSViewController] = []

    override func loadView() {
        view = BackgroundView(color: DesignSystem.Color.background)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        enforceMinimumHeight()
    }

    /// The window's size tracks this split-item's fitting size. A scroll-backed
    /// root (Settings) has a ~0 intrinsic height, so without a floor swapping it
    /// in collapses the whole window to a zero-height sliver — looking like the
    /// app "closed". A required height floor keeps the window usable.
    private func enforceMinimumHeight() {
        let floor = view.heightAnchor.constraint(greaterThanOrEqualToConstant: 480)
        floor.priority = .required
        floor.isActive = true
    }

    var topViewController: NSViewController? { stack.last }
    var canGoBack: Bool { stack.count > 1 }
    var currentTitle: String { stack.last?.title ?? "" }

    func setRoot(_ controller: NSViewController) {
        let savedFrame = view.window?.frame
        for child in children { detach(child) }
        stack = [controller]
        attach(controller)
        onStackChange?()
        restoreWindowFrame(savedFrame)
    }

    /// The window's size tracks the content split-item's fitting size, so swapping
    /// in a scroll-backed root (e.g. Settings) makes the window re-fit to that
    /// near-zero height. Restoring the prior frame — synchronously and once more
    /// after the layout pass — keeps a source switch from ever resizing the
    /// window. The required height floor is the backstop if both are bypassed.
    private func restoreWindowFrame(_ frame: NSRect?) {
        guard let frame, let window = view.window, window.isVisible else { return }
        window.setFrame(frame, display: true)
        DispatchQueue.main.async { [weak window] in window?.setFrame(frame, display: true) }
    }

    func push(_ controller: NSViewController) {
        if let current = stack.last { current.view.isHidden = true }
        stack.append(controller)
        attach(controller)
        onStackChange?()
    }

    func pop() {
        guard stack.count > 1 else { return }
        let top = stack.removeLast()
        detach(top)
        if let revealed = stack.last {
            revealed.view.isHidden = false
            (revealed as? any ContentReappearing)?.viewBecameVisible()
        }
        onStackChange?()
    }

    func popToRoot() {
        while stack.count > 1 { pop() }
    }

    private func attach(_ controller: NSViewController) {
        addChild(controller)
        view.addManaged(controller.view)
        controller.view.pinEdges(to: view)
    }

    private func detach(_ controller: NSViewController) {
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }
}
