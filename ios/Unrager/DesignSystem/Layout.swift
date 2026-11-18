import UIKit

extension UIViewController {
    /// A full-height guide centred in the view that never grows past a readable
    /// content width, so feeds, lists and text keep their shape on a wide canvas
    /// (iPad, a resized window) and fill it on a narrow one. Pin a screen's
    /// content to this instead of the view's edges; the page colour still runs
    /// edge to edge behind it.
    func makeContentGuide(maxWidth: CGFloat = 0) -> UILayoutGuide {
        let cap = maxWidth > 0
            ? maxWidth
            : (traitCollection.userInterfaceIdiom == .pad ? DesignSystem.padContentWidth : DesignSystem.maxContentWidth)
        let guide = UILayoutGuide()
        view.addLayoutGuide(guide)
        let fillWidth = guide.widthAnchor.constraint(equalTo: view.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: view.topAnchor),
            guide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            guide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guide.widthAnchor.constraint(lessThanOrEqualToConstant: cap),
            fillWidth,
        ])
        return guide
    }
}

extension UIView {


    func addManaged(_ subview: UIView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subview)
    }

    @discardableResult
    func pinEdges(to guide: UILayoutGuide, insets: UIEdgeInsets = .zero) -> [NSLayoutConstraint] {
        let constraints = [
            leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: guide.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -insets.bottom),
        ]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }

    /// Horizontal edges to a centred content guide, vertical edges to a view's
    /// safe area — for chrome that sits between the bars but stays in the column.
    func pinEdges(to guide: UILayoutGuide, safeAreaOf view: UIView, insets: UIEdgeInsets = .zero) {
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: safe.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -insets.bottom),
        ])
    }

    func pinEdges(to other: UIView, insets: UIEdgeInsets = .zero) {
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }

    func pinEdges(toSafeAreaOf other: UIView, insets: UIEdgeInsets = .zero) {
        let guide = other.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: guide.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -insets.bottom),
        ])
    }
}
