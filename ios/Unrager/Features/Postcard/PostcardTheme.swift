import UIKit

/// A screenshot palette, mirroring the TUI's `ShotTheme`. Each preset is a
/// real aesthetic (not a color shuffle) decoupled from the live app theme, so
/// the postcard look can be picked without touching the app's appearance. The
/// background is either a solid fill (`backgroundEnd == nil`) or a top→bottom
/// vertical gradient.
///
/// Raw values persist in `UserDefaults` (see `PostcardStore`), so new cases
/// are appended — never inserted — and `ordered` handles presentation order.
enum PostcardTheme: Int, CaseIterable, Sendable {
    case glass
    case synthwave
    case cutout
    case moss
    case blueprint
    case arcade
    case matchApp
    case paper
    case ember

    /// Picker order: curated presets first, Match-the-app trailing.
    static var ordered: [PostcardTheme] {
        allCases.filter { $0 != .matchApp } + [.matchApp]
    }

    var title: String {
        switch self {
        case .glass: return "Glass"
        case .synthwave: return "Synthwave"
        case .cutout: return "Cutout"
        case .moss: return "Moss"
        case .blueprint: return "Blueprint"
        case .arcade: return "Arcade"
        case .matchApp: return "Match App"
        case .paper: return "Paper"
        case .ember: return "Ember"
        }
    }

    /// Top background color (the only one used when `backgroundEnd` is nil).
    var background: UIColor {
        switch self {
        case .glass: return UIColor(rgb: 0xEBF3FA)
        case .synthwave: return UIColor(rgb: 0x0A041C)
        case .cutout: return UIColor(rgb: 0xF3E4CA)
        case .moss: return UIColor(rgb: 0x1E2A20)
        case .blueprint: return UIColor(rgb: 0x072B5C)
        case .arcade: return .black
        case .matchApp: return DesignSystem.Color.background
        case .paper: return UIColor(rgb: 0xFBF8F1)
        case .ember: return UIColor(rgb: 0x1A1210)
        }
    }

    /// Bottom gradient stop; nil for solid-fill themes.
    var backgroundEnd: UIColor? {
        switch self {
        case .glass: return UIColor(rgb: 0xB8CEE8)
        case .synthwave: return UIColor(rgb: 0x5A1A66)
        case .cutout: return UIColor(rgb: 0xE6D0AA)
        case .moss: return UIColor(rgb: 0x2C3A2E)
        case .ember: return UIColor(rgb: 0x3B1D12)
        case .blueprint, .arcade, .matchApp, .paper: return nil
        }
    }

    var text: UIColor {
        switch self {
        case .glass: return UIColor(rgb: 0x142236)
        case .synthwave: return UIColor(rgb: 0xFF6EC7)
        case .cutout: return UIColor(rgb: 0x3A2A1A)
        case .moss: return UIColor(rgb: 0xE8E4D8)
        case .blueprint: return UIColor(rgb: 0xF0F4F8)
        case .arcade: return UIColor(rgb: 0x39FF14)
        case .matchApp: return DesignSystem.Color.label
        case .paper: return UIColor(rgb: 0x2B2620)
        case .ember: return UIColor(rgb: 0xF5E3D3)
        }
    }

    var secondaryText: UIColor {
        switch self {
        case .glass: return UIColor(rgb: 0x5C728A)
        case .synthwave: return UIColor(rgb: 0xA07AC8)
        case .cutout: return UIColor(rgb: 0x8C6A3F)
        case .moss: return UIColor(rgb: 0x8BA08E)
        case .blueprint: return UIColor(rgb: 0x7AA4D0)
        case .arcade: return UIColor(rgb: 0x3D8E3A)
        case .matchApp: return DesignSystem.Color.secondaryLabel
        case .paper: return UIColor(rgb: 0x8A8073)
        case .ember: return UIColor(rgb: 0xB08A72)
        }
    }

    var accent: UIColor {
        switch self {
        case .glass: return UIColor(rgb: 0x2E8BFF)
        case .synthwave: return UIColor(rgb: 0x36E0E0)
        case .cutout: return UIColor(rgb: 0xC0392B)
        case .moss: return UIColor(rgb: 0x9CAF88)
        case .blueprint: return UIColor(rgb: 0x22D3EE)
        case .arcade: return UIColor(rgb: 0xFF00FF)
        case .matchApp: return DesignSystem.Color.accent
        case .paper: return UIColor(rgb: 0xB4552D)
        case .ember: return UIColor(rgb: 0xFF7A3C)
        }
    }

    /// Whether the background reads as dark — drives the swatch border and any
    /// luminance-sensitive chrome in the picker.
    var isDark: Bool {
        switch self {
        case .synthwave, .moss, .blueprint, .arcade, .ember: return true
        case .glass, .cutout, .paper: return false
        case .matchApp: return false
        }
    }
}
