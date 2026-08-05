import AppKit
import SwiftUI

/// Design tokens for Satori. One source of truth for color, spacing, radius,
/// elevation, motion and type.
///
/// Color philosophy is drawn from the app's own icon — an ivory rounded square
/// with pale lavender and one warm-gold spark rising from an open book:
///   • paper      — warm ivory reading surface (the "page" you read on)
///   • accent     — lavender; interaction (selection, primary action, focus)
///   • gold       — the spark of understanding; used ONLY for the moment an
///                  answer is being formed / appears, never for chrome
/// So every color has one job. Chrome (icons, hairlines, labels) stays neutral.
///
/// Type roles (design doc 4.6): the reading surface speaks in serif (you are
/// reading), the chrome speaks in the system sans, code stays monospaced.
/// The PDF canvas itself is rendered by PDFKit; the serif role applies to
/// reading-area typography (notes, markdown) wherever SwiftUI text is set.
///
/// Each adaptive color is defined ONCE as an `NSColor` (`*Color`) and exposed
/// to SwiftUI via `Color(nsColor:)`; `SatoriThemeAppKit` aliases the same
/// instances, so AppKit views (the PDF selection toolbar) can never drift
/// from the SwiftUI theme.
enum SatoriTheme {
    // MARK: Adaptive colors — single source of truth

    /// Warm ivory paper for the reading / learning surface. The "book".
    static let paperColor = NSColor(name: "SatoriPaper") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.098, green: 0.092, blue: 0.118, alpha: 1)   // #191821 warm dark
            : NSColor(srgbRed: 0.965, green: 0.949, blue: 0.918, alpha: 1)   // #F6F2EA warm ivory
    }
    static let paper = Color(nsColor: paperColor)

    /// A raised paper surface (fields, hover chips, the live answer).
    static let paperRaisedColor = NSColor(name: "SatoriPaperRaised") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.145, green: 0.135, blue: 0.165, alpha: 1)
            : NSColor(white: 1.0, alpha: 1)
    }
    static let paperRaised = Color(nsColor: paperRaisedColor)

    /// Lavender — interaction. A calm ink-violet on light, brighter on dark.
    static let accentColor = NSColor(name: "SatoriAccent") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.68, green: 0.63, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.42, green: 0.35, blue: 0.74, alpha: 1)
    }
    static let accent = Color(nsColor: accentColor)

    /// A faint lavender wash for selected rows / active chips.
    static let accentWashColor = NSColor(name: "SatoriAccentWash") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.68, green: 0.63, blue: 0.98, alpha: 0.18)
            : NSColor(srgbRed: 0.42, green: 0.35, blue: 0.74, alpha: 0.10)
    }
    static let accentWash = Color(nsColor: accentWashColor)

    /// 实心强调色：两种模式下都能承载白字（对话气泡、主按钮）。
    static let accentButton = Color(nsColor: accentButtonColor)
    static let accentButtonHover = Color(nsColor: accentButtonHoverColor)

    /// Warm gold — the spark of understanding. Answer moment only.
    static let goldColor = NSColor(name: "SatoriGold") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.90, green: 0.68, blue: 0.32, alpha: 1)
            : NSColor(srgbRed: 0.71, green: 0.46, blue: 0.16, alpha: 1)
    }
    static let gold = Color(nsColor: goldColor)

    static let goldWashColor = NSColor(name: "SatoriGoldWash") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.90, green: 0.68, blue: 0.32, alpha: 0.16)
            : NSColor(srgbRed: 0.71, green: 0.46, blue: 0.16, alpha: 0.10)
    }
    static let goldWash = Color(nsColor: goldWashColor)

    /// A filled accent surface that stays readable with white text in BOTH
    /// modes. The bright dark-mode `accent` works as a tint on dark paper,
    /// not as a filled button face — so the primary button gets a deeper
    /// violet instead of washing white-on-lavender out.
    static let accentButtonColor = NSColor(name: "SatoriAccentButton") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.43, green: 0.37, blue: 0.80, alpha: 1)
            : NSColor(srgbRed: 0.36, green: 0.30, blue: 0.66, alpha: 1)
    }
    static let accentButtonHoverColor = NSColor(name: "SatoriAccentButtonHover") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.50, green: 0.44, blue: 0.86, alpha: 1)
            : NSColor(srgbRed: 0.43, green: 0.37, blue: 0.76, alpha: 1)
    }

    // MARK: Neutral chrome

    /// Hairline separators and borders. A whisper, never a competing line.
    static let hairline = Color.primary.opacity(0.08)

    /// Default tint for chrome icons.
    static let iconChrome = Color.secondary

    // MARK: Type

    // Reading surface: serif (the reader's own text). Chrome: system sans.
    // Code: monospaced. The identity's warmth is carried by color and space,
    // not a display face, so the UI never fights the reader's font settings.

    // MARK: Spacing (design doc scale: 8, 12, 16, 20, 24, 32)

    enum Spacing {
        static let xs: CGFloat = 4   // tight insets between 8-scale steps
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radius — per docs/plans/2026-08-04-reading-workspace-design.md:
    // 8 for controls, 12 for cards, 16 for major empty states. The doc caps
    // the family at 16; xl stays for API parity with lg.

    enum Radius {
        static let sm: CGFloat = 8    // controls, chips
        static let md: CGFloat = 12   // cards, surfaces
        static let lg: CGFloat = 16   // major empty states, sheets
        static let xl: CGFloat = 16   // hero surfaces (doc max)
    }

    // MARK: Motion

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let standard = Animation.spring(response: 0.34, dampingFraction: 0.86)
        static let gentle = Animation.easeInOut(duration: 0.28)
    }
}

private extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - AppKit-facing colors

/// The same tokens exposed as `NSColor`s for AppKit views (the PDF selection
/// toolbar). These alias SatoriTheme's dynamic `NSColor` instances, so a
/// platform-agnostic view stays consistent with the SwiftUI theme in both
/// light and dark mode.
enum SatoriThemeAppKit {
    static let accent = SatoriTheme.accentColor
    /// White text on the accent button — picked for contrast on both modes.
    static let onAccent = NSColor.white
    /// The raised paper surface the toolbar sits on (warm ivory in light mode,
    /// warm dark in dark mode), so it reads as a distinct surface over the PDF.
    static let paperRaised = SatoriTheme.paperRaisedColor
    /// The filled primary-button face — deep enough to carry white text in
    /// both modes.
    static let accentButton = SatoriTheme.accentButtonColor
    /// A faint lavender wash (hover tint) on raised surfaces.
    static let accentWash = SatoriTheme.accentWashColor
    static let accentButtonHover = SatoriTheme.accentButtonHoverColor
    /// A hairline that stays visible on raised surfaces in both modes
    /// (soft black in light, soft white in dark).
    static let hairlineStrong = NSColor(name: "SatoriHairlineStrong") { appearance in
        appearance.isDarkMode
            ? NSColor.white.withAlphaComponent(0.22)
            : NSColor.black.withAlphaComponent(0.14)
    }
    /// PDF 文字选中的高亮：薰衣草强调色的半透明版。PDFKit 默认用系统蓝
    /// （selectedTextBackgroundColor），和主题的暖纸 + 薰衣草不搭；用覆盖层
    /// 把高亮叠成这个颜色，亮暗模式都保持文字可读。
    static let selectionHighlight = NSColor(name: "SatoriSelectionHighlight") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.68, green: 0.63, blue: 0.98, alpha: 0.60)
            : NSColor(srgbRed: 0.42, green: 0.35, blue: 0.74, alpha: 0.55)
    }
}

// MARK: - Reusable surface modifiers

extension View {
    /// A raised paper surface. `emphasized` marks the live "understanding"
    /// moment with a warm-gold hairline — the spark — instead of lavender.
    func satoriPaper(
        radius: CGFloat = SatoriTheme.Radius.md,
        padding: CGFloat = SatoriTheme.Spacing.md,
        emphasized: Bool = false
    ) -> some View {
        self
            .padding(padding)
            .background(SatoriTheme.paperRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        emphasized ? SatoriTheme.gold.opacity(0.45) : SatoriTheme.hairline,
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(emphasized ? 0.10 : 0.04), radius: emphasized ? 12 : 5, y: emphasized ? 3 : 1)
    }

    /// A recessed surface for context blocks and inline chips.
    func satoriInset(radius: CGFloat = SatoriTheme.Radius.sm) -> some View {
        self.background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
