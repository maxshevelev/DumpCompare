import Cocoa

/// User-configurable hex-view appearance (§3.2): the monospaced font (family
/// and size) and the row-height compaction factor. Persisted app-wide; both
/// panes share them.
///
/// Mirrors the `WordSize` pattern: values are read live from `UserDefaults`,
/// and `set(_:...)` posts `didChangeNotification` so open hex views (and pane
/// headers) re-lay out. The font is a family name, with an empty string as the
/// sentinel for "the system monospaced font".
enum AppearanceSettings {
    static let fontFamilyKey = "HexFontFamily"
    static let rowHeightScaleKey = "HexRowHeightScale"
    static let fontSizeKey = "HexFontSize"

    /// Posted after a change so open hex views re-lay out (§3.2).
    static let didChangeNotification = Notification.Name("AppearanceSettingsDidChange")

    /// Stored as the font family when the user wants the system monospaced font
    /// rather than a named family.
    static let systemFontSentinel = ""

    /// The built-in row-height factor (the font's natural padded line height).
    static let defaultRowHeightScale: CGFloat = 0.8
    /// The range the Settings slider offers. The lower bound keeps the row
    /// taller than the glyph ink, so rows never visibly collide.
    static let rowHeightScaleRange: ClosedRange<CGFloat> = 0.65...1.0

    /// The built-in hex font size, in points.
    static let defaultFontSize: CGFloat = 13
    /// The range the Settings stepper offers.
    static let fontSizeRange: ClosedRange<CGFloat> = 9...24
    /// What one Zoom In / Zoom Out moves the size by (§3.2) — the same point
    /// the Settings stepper steps, so the two controls agree about what a step
    /// is and the menu never lands between the stepper's values.
    static let fontSizeStep: CGFloat = 1

    /// The configured font family; empty means the system monospaced font.
    static var fontFamily: String {
        UserDefaults.standard.string(forKey: fontFamilyKey) ?? systemFontSentinel
    }

    /// The configured row-height factor, falling back to the built-in default.
    static var rowHeightScale: CGFloat {
        let stored = UserDefaults.standard.double(forKey: rowHeightScaleKey)
        guard stored > 0 else { return defaultRowHeightScale }
        return CGFloat(stored)
    }

    /// The configured hex font size in points, falling back to the built-in
    /// default.
    static var fontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        guard stored > 0 else { return defaultFontSize }
        return CGFloat(stored)
    }

    /// Persists the three appearance settings and notifies observers to re-lay
    /// out (§3.2). `fontSize` defaults to the current value, so a caller that
    /// changes only the family or the row height leaves the size untouched.
    static func set(fontFamily: String, rowHeightScale: CGFloat, fontSize: CGFloat = fontSize) {
        UserDefaults.standard.set(fontFamily, forKey: fontFamilyKey)
        UserDefaults.standard.set(rowHeightScale, forKey: rowHeightScaleKey)
        UserDefaults.standard.set(fontSize, forKey: fontSizeKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Moves the hex font size by `step` points, clamped to `fontSizeRange` —
    /// Zoom In and Zoom Out (§3.2). Everything else about the appearance is
    /// left as it stands.
    ///
    /// Returns false when the size did not move, which is the whole answer at
    /// either end of the range: the menu items dim there rather than repeating
    /// a change that cannot happen.
    @discardableResult
    static func zoom(by step: CGFloat) -> Bool {
        let current = fontSize
        let clamped = min(max(current + step, fontSizeRange.lowerBound), fontSizeRange.upperBound)
        guard clamped != current else { return false }
        set(fontFamily: fontFamily, rowHeightScale: rowHeightScale, fontSize: clamped)
        return true
    }

    /// Whether a zoom of `step` would change anything — what the menu asks
    /// before it draws the item enabled.
    static func canZoom(by step: CGFloat) -> Bool {
        let clamped = min(max(fontSize + step, fontSizeRange.lowerBound), fontSizeRange.upperBound)
        return clamped != fontSize
    }

    /// Restores the built-in defaults and notifies (used by tests, and by the
    /// Settings UI if it ever gains a "Reset" affordance).
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: fontFamilyKey)
        UserDefaults.standard.removeObject(forKey: rowHeightScaleKey)
        UserDefaults.standard.removeObject(forKey: fontSizeKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// The hex font for the current settings. A named family is resolved to its
    /// regular-weight member; unknown or empty families fall back to the
    /// system monospaced font. `size` defaults to the configured font size, so
    /// the dump and its mirrors ask for `font()` and follow the setting; the
    /// fixed-size call sites (form fields, the decoding preview) pass their own.
    static func font(size: CGFloat = fontSize) -> NSFont {
        let family = fontFamily
        guard !family.isEmpty else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if let resolved = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return resolved
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The bold member of the same family — used where emphasis must match the
    /// hex font exactly (the Search All results excerpts). A monospaced family
    /// shares one advance width across weights, so bolding never shifts bytes.
    static func boldFont(size: CGFloat = fontSize) -> NSFont {
        let family = fontFamily
        guard !family.isEmpty else {
            return .monospacedSystemFont(ofSize: size, weight: .bold)
        }
        if let resolved = NSFontManager.shared.font(withFamily: family, traits: [.boldFontMask], weight: 9, size: size) {
            return resolved
        }
        return .monospacedSystemFont(ofSize: size, weight: .bold)
    }

    /// Width of one monospaced glyph cell — the horizontal pitch shared by the
    /// hex view and the Settings text-decoding preview.
    static func charWidth(for font: NSFont) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// The baseline that places the glyph ink vertically centered in a row.
    /// `NSString.draw(at:)` anchors the text's ascent line at the point in a
    /// flipped view, so centering the ascent box alone would push the ink low in
    /// the row (a font's ascender far exceeds its cap height). Measure the ink
    /// bounds of a representative glyph and solve for the point that centers
    /// those bounds in `rowHeight` (§3.2).
    static func centeredBaseline(font: NSFont, rowHeight: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "0A", attributes: [.font: font]))
        let ink = CTLineGetImageBounds(line, nil)
        // ink.minY sits below the baseline (negative), ink.maxY above it.
        return rowHeight / 2 - (font.ascender + font.leading) + (ink.minY + ink.maxY) / 2
    }

    /// The monospaced font families available to the Settings font popup, in
    /// alphabetical order. A family counts when its regular-weight member
    /// reports `isFixedPitch`.
    static func monospacedFontFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { family in
                guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) else { return false }
                return font.isFixedPitch
            }
            .sorted()
    }
}
