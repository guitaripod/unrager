import UIKit
import UnragerKit

/// Up to four photos laid out by `PhotoMosaic`: each tile has its photo's own
/// shape, so nothing is cropped. A photo whose real shape isn't its tile's (an
/// extreme panorama or a very tall screenshot, or one the server mis-measured)
/// is shown whole over a frosted copy of itself; that is decided by the
/// picture once it lands, never by what was promised before. A photo with a
/// description wears a small ALT badge, and a fifth-and-beyond is collapsed
/// into a "+N" overlay on the last tile. Tapping any tile reports its index so
/// the cell can open the viewer at that photo. Reuse-safe: `prepareForReuse()`
/// cancels every tile's load.
final class PhotoGridView: UIView {
    var onTapPhoto: ((Int) -> Void)?

    private var tiles: [AsyncImageView] = []
    private var backdrops: [AmbientBackdropView] = []
    private var altBadges: [UILabel] = []
    private let overflowLabel = UILabel()
    private var urls: [URL] = []
    private var ratios: [CGFloat?] = []
    private var mosaic = PhotoMosaic(tiles: [], height: 0)
    private var heightConstraint: NSLayoutConstraint?
    private var outlined = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        accessibilityIgnoresInvertColors = true

        overflowLabel.font = DesignSystem.Typography.system(28, weight: .bold)
        overflowLabel.textColor = .white
        overflowLabel.textAlignment = .center
        overflowLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        overflowLabel.isHidden = true

        let height = heightAnchor.constraint(equalToConstant: 180)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PhotoGridView, _) in
            view.layer.borderColor = DesignSystem.Color.separator.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Rounds the grid's corners and, when rounded, outlines it with a hairline,
    /// so a dark photo still has an edge on a dark page.
    func setRounded(_ radius: CGFloat) {
        layer.cornerRadius = radius
        outlined = radius > 0
        layer.borderColor = DesignSystem.Color.separator.cgColor
        setNeedsLayout()
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
        self.urls = Array(urls.prefix(count))
        self.ratios = Array(ratios.prefix(count))
        mosaic = PhotoMosaic.make(ratios: self.ratios, width: width)
        heightConstraint?.constant = max(1, mosaic.height.rounded())
        if tiles.count != count { rebuild(count: count) }
        setNeedsLayout()
        for (index, tile) in tiles.enumerated() {
            let alt = altTexts.indices.contains(index) ? altTexts[index].flatMap { $0.isEmpty ? nil : $0 } : nil
            tile.accessibilityLabel = alt ?? "Photo \(index + 1) of \(urls.count)"
            tile.accessibilityHint = "Opens the photo"
            altBadges[index].isHidden = alt == nil
        }
        guard imagesEnabled else {
            tiles.forEach { $0.cancel() }
            backdrops.forEach { $0.clear() }
            return
        }
        for (index, tile) in tiles.enumerated() where mosaic.tiles.indices.contains(index) {
            tile.load(url: self.urls[index], targetSize: mosaic.tiles[index].size)
        }
        overflowLabel.isHidden = urls.count <= PhotoMosaic.maxPhotos
        overflowLabel.text = "+\(urls.count - PhotoMosaic.maxPhotos)"
    }

    func prepareForReuse() {
        tiles.forEach { $0.cancel() }
        backdrops.forEach { $0.clear() }
        onTapPhoto = nil
    }

    /// Fills a tile with its photo when that is the tile's shape, and otherwise
    /// shows the photo whole over a frosted copy of itself.
    private func fit(_ index: Int, to image: UIImage) {
        guard tiles.indices.contains(index), mosaic.tiles.indices.contains(index) else { return }
        let fills = MediaShape.matches(image.size, in: mosaic.tiles[index].size)
        tiles[index].contentMode = fills ? .scaleAspectFill : .scaleAspectFit
        if fills {
            backdrops[index].clear()
        } else {
            backdrops[index].show(from: image, key: urls[index].absoluteString)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        relayoutIfWidthChanged()
        let scale = max(traitCollection.displayScale, 1)
        layer.borderWidth = outlined ? 1 / scale : 0
        for (index, frame) in mosaic.tiles.enumerated() where tiles.indices.contains(index) {
            let tileFrame = frame.aligned(toScale: scale)
            tiles[index].frame = tileFrame
            backdrops[index].frame = tileFrame
            altBadges[index].frame = CGRect(x: tileFrame.minX + 8, y: tileFrame.maxY - 26, width: 34, height: 18)
            if let image = tiles[index].image { fit(index, to: image) }
        }
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
        (tiles as [UIView] + backdrops + altBadges).forEach { $0.removeFromSuperview() }
        overflowLabel.removeFromSuperview()
        tiles = (0..<count).map { makeTile(index: $0) }
        backdrops = (0..<count).map { _ in AmbientBackdropView(frame: .zero) }
        altBadges = (0..<count).map { _ in makeAltBadge() }
        for index in 0..<count {
            addSubview(backdrops[index])
            addSubview(tiles[index])
            addSubview(altBadges[index])
        }
        if let last = tiles.last {
            last.addManaged(overflowLabel)
            overflowLabel.pinEdges(to: last)
        }
    }

    private func makeTile(index: Int) -> AsyncImageView {
        let tile = AsyncImageView(frame: .zero)
        tile.contentMode = .scaleAspectFill
        tile.clipsToBounds = true
        tile.fadesIn = true
        tile.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tileTapped(_:)))
        tile.addGestureRecognizer(tap)
        tile.isAccessibilityElement = true
        tile.accessibilityTraits = .image
        tile.onLoad = { [weak self] image in self?.fit(index, to: image) }
        return tile
    }

    private func makeAltBadge() -> UILabel {
        let badge = UILabel()
        badge.text = "ALT"
        badge.font = DesignSystem.Typography.system(10, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 4
        badge.layer.masksToBounds = true
        badge.isUserInteractionEnabled = false
        badge.isAccessibilityElement = false
        badge.isHidden = true
        return badge
    }

    @objc private func tileTapped(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? AsyncImageView,
              let index = tiles.firstIndex(of: view) else { return }
        onTapPhoto?(index)
    }
}

private extension CGRect {
    /// The rect with every edge on a device pixel, so neighbouring tiles meet
    /// along one line with no hairline gap or overlap between them.
    func aligned(toScale scale: CGFloat) -> CGRect {
        let minX = (self.minX * scale).rounded() / scale
        let minY = (self.minY * scale).rounded() / scale
        let maxX = (self.maxX * scale).rounded() / scale
        let maxY = (self.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
