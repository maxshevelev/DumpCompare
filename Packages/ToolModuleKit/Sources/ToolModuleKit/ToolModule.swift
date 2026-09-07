import AppKit

/// An instrument for working on a dump: it reads the open file, shows its own
/// UI in the window's left panel, marks zones in the dump, and can write back
/// (`Design/TOOL_MODULES_PLAN.md`).
///
/// A tool-module is a *type*, never an instance: what the app keeps is the list
/// of them, and what it makes when the user picks one is a session. Everything
/// here is what the Tools menu needs to draw the item before anything has been
/// opened.
///
/// Applicability is not here on purpose. The host offers every tool-module for
/// every file; whether there is a FIT table in this image is a question only
/// the tool-module can answer and only after reading, and the answer belongs in
/// its panel as a sentence rather than in the menu as a grey item that explains
/// nothing.
public protocol ToolModule {
    /// Stable, reverse-DNS, and never shown: it keys the panel's remembered
    /// width and identifies the module in the menu's state. Renaming one
    /// forgets that width, which is the whole cost of getting it wrong.
    static var identifier: String { get }
    /// The Tools menu item.
    static var title: String { get }
    /// How wide the panel opens the first time. The user's own width, once they
    /// drag the divider, outranks it from then on.
    static var preferredPanelWidth: CGFloat { get }

    /// Builds the session that runs this tool-module against one open file.
    /// Called on activation; the host lives at least as long as the session.
    @MainActor static func makeSession(host: any ToolHost) -> any ToolSession
}
