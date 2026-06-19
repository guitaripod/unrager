import UIKit
import UnragerKit

/// A rounded grid of up to four photos. One photo fills the width 16:9; two
/// sit side by side; three put a tall lead photo beside a stacked pair; four
/// form a 2×2. A fifth-and-beyond is collapsed into a "+N" overlay on the last
/// tile. Tapping any tile reports its index so the cell can open the viewer at
/// that photo. Reuse-safe: `prepareForReuse()` cancels every tile's load.
final class PhotoGridView: UIView {
    var onTapPhoto: ((Int) -> Void)?

    private var tiles: [AsyncImageView] = []
    private let overflowLabel = UILabel()
    private let column = UIStackView()
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        column.axis = .vertical
        column.spacing = 3
        column.layer.cornerRadius = DesignSystem.Radius.media
        column.layer.cornerCurve = .continuous
        column.clipsToBounds = true
        addManaged(column)
        column.pinEdges(to: self)

        overflowLabel.font = .systemFont(ofSize: 28, weight: .bold)
        overflowLabel.textColor = .white
        overflowLabel.textAlignment = .center
        overflowLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        overflowLabel.isHidden = true

        let height = heightAnchor.constraint(equalToConstant: 180)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setRounded(_ radius: CGFloat) {
        column.layer.cornerRadius = radius
    }

    func configure(urls: [URL], contentWidth: CGFloat, imagesEnabled: Bool) {
        rebuild(count: min(urls.count, 4), totalAspectHeight: layoutHeight(for: urls.count, width: contentWidth))
        guard imagesEnabled else {
            tiles.forEach { $0.cancel() }
            return
        }
        let tileSize = CGSize(width: contentWidth / 2, height: contentWidth / 2)
        for (index, tile) in tiles.enumerated() where index < urls.count {
            tile.load(url: urls[index], targetSize: tileSize)
        }
        if urls.count > 4 {
            overflowLabel.isHidden = false
            overflowLabel.text = "+\(urls.count - 4)"
        } else {
            overflowLabel.isHidden = true
        }
    }

    func prepareForReuse() {
        tiles.forEach { $0.cancel() }
        onTapPhoto = nil
    }

    private func layoutHeight(for count: Int, width: CGFloat) -> CGFloat {
        switch count {
        case 1: return (width * 9 / 16).rounded()
        default: return width.rounded()
        }
    }

    private func rebuild(count: Int, totalAspectHeight: CGFloat) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tiles = (0..<count).map { _ in makeTile() }
        heightConstraint?.constant = max(120, totalAspectHeight)
        overflowLabel.removeFromSuperview()

        switch count {
        case 0:
            break
        case 1:
            column.addArrangedSubview(tiles[0])
        case 2:
            column.addArrangedSubview(row(tiles[0], tiles[1]))
        case 3:
            let stacked = UIStackView(arrangedSubviews: [tiles[1], tiles[2]])
            stacked.axis = .vertical
            stacked.spacing = 3
            stacked.distribution = .fillEqually
            column.addArrangedSubview(row(tiles[0], stacked))
        default:
            column.addArrangedSubview(row(tiles[0], tiles[1]))
            column.addArrangedSubview(row(tiles[2], tiles[3]))
        }

        if let last = tiles.last {
            last.addManaged(overflowLabel)
            overflowLabel.pinEdges(to: last)
        }
    }

    private func row(_ a: UIView, _ b: UIView) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [a, b])
        stack.axis = .horizontal
        stack.spacing = 3
        stack.distribution = .fillEqually
        return stack
    }

    private func makeTile() -> AsyncImageView {
        let tile = AsyncImageView(frame: .zero)
        tile.contentMode = .scaleAspectFill
        tile.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tileTapped(_:)))
        tile.addGestureRecognizer(tap)
        tile.isAccessibilityElement = true
        tile.accessibilityTraits = .image
        return tile
    }

    @objc private func tileTapped(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? AsyncImageView,
              let index = tiles.firstIndex(of: view) else { return }
        onTapPhoto?(index)
    }
}
