import AppKit
import UnragerKit

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

    var topViewController: NSViewController? { stack.last }
    var canGoBack: Bool { stack.count > 1 }
    var currentTitle: String { stack.last?.title ?? "" }

    func setRoot(_ controller: NSViewController) {
        for child in children { detach(child) }
        stack = [controller]
        attach(controller)
        onStackChange?()
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
        stack.last?.view.isHidden = false
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
