import AppKit

/// The type size a tool-module's panel draws at: its table rows, the detail
/// fields under them, and the lines around both.
///
/// Two things live here rather than in each panel. The sizes were spelled
/// per module — "11 for a row, 12 for a heading", the same numbers copied into
/// both firmware panels — and `CLAUDE.md` says what two tool-modules both need
/// moves to a shared package. And the size is the app's **Zoom**: the one
/// setting behind View > Zoom In / Zoom Out and the Settings font stepper, so a
/// panel grows with the dump beside it instead of staying at a size the reader
/// cannot change.
///
/// A tool-module never links the app, so the defaults key and the notification
/// name are spelled here and the app's `AppearanceSettings` takes them from
/// this — one definition rather than two that drift apart. The values are read
/// live, exactly as the hex view reads them; a panel re-reads them when
/// `zoomDidChangeNotification` arrives.
public enum ToolPanelFont {
    /// The `UserDefaults` key the app's Zoom — and the Settings stepper behind
    /// it — writes the size to.
    public static let zoomSizeKey = "HexFontSize"

    /// Where the size is read from. The app points this at its own
    /// `AppDefaults.store` at launch, so a test run reads the suite the app
    /// reads rather than the user's real settings; a package cannot see the
    /// app, hence the seam rather than the decision being made here.
    public static var defaults: UserDefaults = .standard

    /// Posted after the zoom moves, so a panel on screen re-reads the size.
    public static let zoomDidChangeNotification =
        Notification.Name("AppearanceSettingsDidChange")

    /// The size a panel draws body text at with nothing stored — the app's
    /// own default zoom.
    public static let defaultSize: CGFloat = 13

    /// The span the zoom moves within. A stored size outside it is clamped: a
    /// panel follows the zoom, and the zoom cannot leave this range.
    public static let sizeRange: ClosedRange<CGFloat> = 9...24

    /// Body text: a table cell, a detail row, the summary and notice lines.
    public static var size: CGFloat {
        let stored = defaults.double(forKey: zoomSizeKey)
        guard stored > 0 else { return defaultSize }
        return min(max(CGFloat(stored), sizeRange.lowerBound), sizeRange.upperBound)
    }

    /// A detail's heading — one point over the body, the step the panels
    /// already read at before either of them followed the zoom.
    public static var titleSize: CGFloat { size + 1 }

    /// Body text at `weight`.
    public static func body(weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    /// A detail's heading.
    public static func title() -> NSFont {
        .systemFont(ofSize: titleSize, weight: .semibold)
    }

    /// Body text with digits of one width — what an address, a size or an
    /// index is drawn with, so a column of numbers lines up.
    public static func monospacedDigits() -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// What one table row is tall at this size.
    ///
    /// A panel's table has to ask for this and set `rowSizeStyle = .custom`:
    /// the styles AppKit offers are three fixed heights that have nothing to do
    /// with the font, and `.small` (17 points) clips the text of anything past
    /// about 12. Measured off the font rather than scaled from the size, plus
    /// the padding that keeps the ink off the row's edges and the selection
    /// from looking tight.
    public static var rowHeight: CGFloat {
        let font = body()
        let line = font.ascender - font.descender + font.leading
        return line.rounded(.up) + 5
    }

    /// How tall the header above such a table has to be for a label at this
    /// size to fit — a header keeps whatever height it was made with, so a
    /// panel sets this itself once it has raised the header's font.
    public static var headerHeight: CGFloat {
        max(rowHeight, 17)
    }

    /// The size the panels' fixed widths were chosen at. A column 96 points
    /// wide is 96 points wide *for text this size*, so every such number is a
    /// measurement at this size and scales from it.
    public static let designSize: CGFloat = 11

    /// What a width laid out at `designSize` comes to at the current size —
    /// what keeps a column's text inside it, and a detail's labels in one
    /// column, once the zoom has moved.
    public static func scaled(_ width: CGFloat) -> CGFloat {
        (width * size / designSize).rounded()
    }

    /// The width of the label column in a detail list. The rows read as a
    /// column of pairs only while every label has the same width, and that
    /// width has to follow the size.
    public static var detailLabelWidth: CGFloat { scaled(104) }

    /// Calls `handler` on the main queue whenever the zoom moves, and hands
    /// back the token the caller has to keep — an observer nobody holds is one
    /// `NotificationCenter` stops calling.
    public static func observeZoom(
        _ handler: @escaping @Sendable @MainActor () -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: zoomDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
