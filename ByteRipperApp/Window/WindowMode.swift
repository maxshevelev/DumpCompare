import Foundation

/// Operating mode of the main comparison window (§2, §3 of REQUIREMENTS.md).
enum WindowMode {
    /// No file open — placeholder with a clickable icon and drop hint.
    case empty

    /// One file open — a single file pane fills the client area.
    case singleFile

    /// Two files open — two synchronized panes.
    case comparison
}
