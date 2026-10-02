import UIKit
import UnragerKit

/// A rounded grid of up to four photos. A lone photo fills the width at its
/// real aspect ratio (clamped); two sit side by side; three put a tall lead
/// photo beside a stacked pair; four form a 2×2. A fifth-and-beyond is
/// collapsed into a "+N" overlay on the last tile. Tapping any tile reports its
/// index so the cell can open the viewer at that photo. Reuse-safe:
/// `prepareForReuse()` cancels every tile's load.
final class PhotoGridView: UIView {
    var onTapPhoto: ((Int) -> Void)?

    private var tiles: [AsyncImageView] = []
    private let overflowLabel = UILabel()
    private let column = UIStackView()
    private var heightConstraint: NSLayoutConstraint?
    private var builtLayout: (count: Int, height: CGFloat)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        column.axis = .vertical
        column.spacing = 3
        column.layer.cornerRadius = DesignSystem.Radius.media
        column.layer.cornerCurve = .continuous
        column.clipsToBounds = true
        addManaged(column)
        column.pinEdges(to: self)

        overflowLabel.font = DesignSystem.Typography.system(28, weight: .bold)
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

    /// The image view for a given photo position, so the viewer zooms from the
    /// exact tapped tile rather than the whole grid.
    func tileView(at index: Int) -> UIView? {
        index >= 0 && index < tiles.count ? tiles[index] : nil
    }

    /// Lays the grid out for `urls` and starts each tile's load. Reconfiguring a
    /// grid that already has this shape keeps its tiles, so a like or a read
    /// mark never tears the photos down and reloads them.
    func configure(urls: [URL], contentWidth: CGFloat, imagesEnabled: Bool, aspectRatio: CGFloat? = nil,
                   altTexts: [String?] = []) {
        let height = layoutHeight(for: urls.count, width: contentWidth, aspectRatio: aspectRatio)
        let count = min(urls.count, 4)
        if builtLayout?.count != count || builtLayout?.height != height {
            rebuild(count: count, totalAspectHeight: height)
            builtLayout = (count, height)
        }
        for (index, tile) in tiles.enumerated() {
            let alt = altTexts.indices.contains(index) ? altTexts[index] : nil
            tile.accessibilityLabel = alt.flatMap { $0.isEmpty ? nil : $0 } ?? "Photo \(index + 1) of \(urls.count)"
            tile.accessibilityHint = "Opens the photo"
        }
        guard imagesEnabled else {
            tiles.forEach { $0.cancel() }
            return
        }
        for (index, tile) in tiles.enumerated() where index < urls.count {
            tile.load(url: urls[index], targetSize: tileSize(at: index, count: count, width: contentWidth, height: height))
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

    /// The size tile `index` is drawn at, so its image is decoded for that
    /// size: a tile in a pair, or the lead of three, is half the width and the
    /// full height, and decoding it as a half-width square would stretch it.
    private func tileSize(at index: Int, count: Int, width: CGFloat, height: CGFloat) -> CGSize {
        switch count {
        case 1: return CGSize(width: width, height: height)
        case 2: return CGSize(width: width / 2, height: height)
        case 3: return index == 0 ? CGSize(width: width / 2, height: height) : CGSize(width: width / 2, height: height / 2)
        default: return CGSize(width: width / 2, height: height / 2)
        }
    }

    /// A lone photo gets its true aspect, clamped between a wide-panorama floor
    /// (2:1) and a portrait ceiling (≈3:4) so neither a thin strip nor a
    /// screen-eating column dominates the scroll. Multiple photos keep the
    /// fixed square grid. Falls back to 16:9 when dimensions are unknown.
    private func layoutHeight(for count: Int, width: CGFloat, aspectRatio: CGFloat?) -> CGFloat {
        switch count {
        case 1:
            guard let aspectRatio, aspectRatio > 0 else { return (width * 9 / 16).rounded() }
            let natural = width / aspectRatio
            return min(max(natural, width * 0.5), width * 1.3).rounded()
        default:
            return width.rounded()
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
