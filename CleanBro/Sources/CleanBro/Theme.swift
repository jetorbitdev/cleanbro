import SwiftUI
import AppKit

/// Design tokens. Dark values come from "Rapi — Dark Theme Tokens";
/// light values are their counterparts on a light background.
enum Theme {
    // MARK: backgrounds
    static let window   = Color(light: .hex(0xFFFFFF), dark: .hex(0x1E1F21))
    static let sidebar  = Color(light: .hex(0xF2F2F4), dark: .hex(0x2A2B2E))
    static let canvas   = Color(light: .hex(0xFFFFFF), dark: .hex(0x18191B))
    static let card     = Color(light: .hex(0xF5F5F7), dark: .hex(0x27292C))
    static let footer   = Color(light: .hex(0xF7F7F9), dark: .hex(0x232427))
    static let control  = Color(light: .hex(0xFFFFFF), dark: .hex(0x2E3033))
    static let cardHover = Color(light: .hex(0xEDEDF0), dark: .hex(0x303235))
    static let rowHover  = Color(light: .hex(0xF0F0F2), dark: .hex(0x26282B))
    static let navActive = Color(light: .black.withAlphaComponent(0.07), dark: .white.withAlphaComponent(0.10))
    static let navHover  = Color(light: .black.withAlphaComponent(0.04), dark: .white.withAlphaComponent(0.05))
    static let rowHighlight = Color(light: .black.withAlphaComponent(0.05), dark: .white.withAlphaComponent(0.07))
    static let toast = Color(light: .hex(0x28282A, alpha: 0.92), dark: .hex(0x3A3C40, alpha: 0.96))

    // MARK: text
    static let textPrimary   = Color(light: .hex(0x1D1D1F), dark: .hex(0xF2F2F4))
    static let textSecondary = Color(light: .hex(0x6E6E73), dark: .hex(0xA3A8AD))
    static let textTertiary  = Color(light: .hex(0x8E8E93), dark: .hex(0x7E8388))
    static let textMuted     = Color(light: .hex(0xAEAEB2), dark: .hex(0x5D6166))

    // MARK: borders, tracks
    static let borderSubtle  = Color(light: .black.withAlphaComponent(0.06), dark: .white.withAlphaComponent(0.08))
    static let border        = Color(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.10))
    static let borderStrong  = Color(light: .black.withAlphaComponent(0.12), dark: .white.withAlphaComponent(0.14))
    static let sidebarEdge   = Color(light: .black.withAlphaComponent(0.10), dark: .black.withAlphaComponent(0.5))
    static let track         = Color(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.09))

    // MARK: accent
    static let accent        = Color(nsColor: .oklch(0.55, 0.13, 175))
    static let accentBar     = Color(light: .oklch(0.55, 0.13, 175), dark: .oklch(0.62, 0.13, 175))
    static let accentText    = Color(light: .oklch(0.48, 0.11, 175), dark: .oklch(0.80, 0.10, 175))
    static let accentSubtle  = Color(light: .oklch(0.95, 0.03, 175), dark: .oklch(0.30, 0.04, 175))

    // MARK: radius
    enum Radius {
        static let card: CGFloat = 8
        static let tile: CGFloat = 8
        static let subTile: CGFloat = 5
        static let button: CGFloat = 7
        static let nav: CGFloat = 6
    }
}

extension Color {
    /// Resolves per appearance, so it follows the light/dark setting live.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    static func hex(_ v: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    /// CSS oklch(L C h) → sRGB.
    static func oklch(_ L: Double, _ C: Double, _ h: Double, alpha: CGFloat = 1) -> NSColor {
        let a = C * cos(h * .pi / 180), b = C * sin(h * .pi / 180)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ x: Double) -> CGFloat {
            let x = min(max(x, 0), 1)
            return CGFloat(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        return NSColor(srgbRed: gamma( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                       green:   gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                       blue:    gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
                       alpha: alpha)
    }
}
