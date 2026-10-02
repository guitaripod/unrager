import Testing
import UIKit
@testable import Unrager

@Suite("Colour contrast")
struct HandlePaletteTests {
    private func luminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test("Every handle tint reads at 4.5:1 on its background in both modes")
    func paletteContrast() {
        for entry in DesignSystem.handlePaletteRGB {
            #expect(contrast(UIColor(rgb: entry.light), .white) >= 4.5, "light \(String(entry.light, radix: 16))")
            #expect(contrast(UIColor(rgb: entry.dark), .black) >= 4.5, "dark \(String(entry.dark, radix: 16))")
        }
    }

    @Test("Increase Contrast moves a tint further from the background")
    @MainActor
    func highContrastStepsAway() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let normal = UITraitCollection(traitsFrom: [.init(userInterfaceStyle: style), .init(accessibilityContrast: .normal)])
            let high = UITraitCollection(traitsFrom: [.init(userInterfaceStyle: style), .init(accessibilityContrast: .high)])
            let background: UIColor = style == .dark ? .black : .white
            for color in [DesignSystem.Color.accent, DesignSystem.Color.like, DesignSystem.Color.retweet,
                          DesignSystem.handleColor("fieldnotes")] {
                #expect(contrast(color.resolvedColor(with: high), background)
                        > contrast(color.resolvedColor(with: normal), background))
            }
        }
    }
}
