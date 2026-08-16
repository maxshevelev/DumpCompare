import Cocoa

/// The minimap panel shown to the right of the hex panes (§ N).
///
/// Stage 1 is an empty vertical panel: the split host, the divider, and the
/// show/hide toggle exist, but nothing is drawn inside yet. Later stages add
/// the per-file mini rows, the viewport rectangle, and the divider line that
/// follows the pane layout.
final class MinimapView: NSView {
    /// The panel's quiet background — the same paper the hex dumps sit on, so
    /// the panel reads as part of the content area while idle.
    private static let background = NSColor.textBackgroundColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
