import UIKit
import UnragerKit

/// Up to four photos laid out by `PhotoMosaic`: each keeps its own shape, so
/// nothing is cropped and nothing is letterboxed. A fifth-and-beyond is
/// collapsed into a "+N" overlay on the last tile. Tapping any tile reports its
/// index so the cell can open the viewer at that photo. Reuse-safe:
/// `prepareForReuse()` cancels every tile's load.
final class PhotoGridView: UIView {
    var onTapPhoto: ((Int) -> Void)?

    private var tiles: [AsyncImageView] = []
    private let overflowLabel = UILabel()
    private var ratios: [CGFloat?] = []
    private var mosaic = PhotoMosaic(tiles: [], height: 0)
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous

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
        layer.cornerRadius = radius
    }

    /// The image view for a given photo position, so the viewer zooms from the
    /// exact tapped tile rather than the whole grid.
    func tileView(at index: Int) -> UIView? {
        index >= 0 && index < tiles.count ? tiles[index] : nil
    }

    /// Lays the grid out for `urls` and starts each tile's load. Reconfiguring a
    /// grid that already has this shape keeps its tiles, so a like or a read
    /// mark never tears the photos down and reloads them.
    func configure(urls: [URL], ratios: [CGFloat?], width: CGFloat, imagesEnabled: Bool,
                   altTexts: [String?] = []) {
        let count = min(urls.count, PhotoMosaic.maxPhotos)
        self.ratios = Array(ratios.prefix(count))
        mosaic = PhotoMosaic.make(ratios: self.ratios, width: width)
        heightConstraint?.constant = max(1, mosaic.height.rounded())
        if tiles.count != count { rebuild(count: count) }
        setNeedsLayout()
        for (index, tile) in tiles.enumerated() {
            let alt = altTexts.indices.contains(index) ? altTexts[index] : nil
            tile.accessibilityLabel = alt.flatMap { $0.isEmpty ? nil : $0 } ?? "Photo \(index + 1) of \(urls.count)"
            tile.accessibilityHint = "Opens the photo"
        }
        guard imagesEnabled else {
            tiles.forEach { $0.cancel() }
            return
        }
        for (index, tile) in tiles.enumerated() where mosaic.tiles.indices.contains(index) {
            tile.load(url: urls[index], targetSize: mosaic.tiles[index].size)
        }
        overflowLabel.isHidden = urls.count <= PhotoMosaic.maxPhotos
        overflowLabel.text = "+\(urls.count - PhotoMosaic.maxPhotos)"
    }

    func prepareForReuse() {
        tiles.forEach { $0.cancel() }
        onTapPhoto = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        relayoutIfWidthChanged()
        for (tile, frame) in zip(tiles, mosaic.tiles) { tile.frame = frame }
    }

    /// Rebuilds the mosaic when the grid ends up a different width than it was
    /// configured for (a rotation or a split view), so tiles still fill it.
    private func relayoutIfWidthChanged() {
        let drawn = PhotoMosaic.make(ratios: ratios, width: bounds.width)
        guard drawn != mosaic else { return }
        mosaic = drawn
        heightConstraint?.constant = max(1, drawn.height.rounded())
    }

    private func rebuild(count: Int) {
        tiles.forEach { $0.removeFromSuperview() }
        overflowLabel.removeFromSuperview()
        tiles = (0..<count).map { _ in makeTile() }
        tiles.forEach(addSubview)
        if let last = tiles.last {
            last.addManaged(overflowLabel)
            overflowLabel.pinEdges(to: last)
        }
    }

    private func makeTile() -> AsyncImageView {
        let tile = AsyncImageView(frame: .zero)
        tile.contentMode = .scaleAspectFill
        tile.clipsToBounds = true
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
