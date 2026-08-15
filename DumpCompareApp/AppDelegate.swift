import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app is single-window, so the system's automatic window tabbing
        // (which would otherwise inject "Show Tab Bar"/"Show All Tabs" into the
        // View menu) has nothing to merge and is dead UI. Disable it.
        NSWindow.allowsAutomaticWindowTabbing = false
        let windowController = MainWindowController()
        windowController.showWindow(nil)
        mainWindowController = windowController
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
