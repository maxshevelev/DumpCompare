import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    /// URLs handed to us by Launch Services before the window existed. An
    /// "Open with" / double-click launch can deliver `application(_:open:)`
    /// before `applicationDidFinishLaunching` finishes building the window, so
    /// they queue here and drain once it is up.
    private var pendingOpenURLs: [URL] = []
    private var isReady = false
    /// Observes theme changes so a Settings change re-themes the running app
    /// without a relaunch (§3.2).
    private var themeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app is single-window, so the system's automatic window tabbing
        // (which would otherwise inject "Show Tab Bar"/"Show All Tabs" into the
        // View menu) has nothing to merge and is dead UI. Disable it.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Apply the stored theme before any window appears, so the first frame
        // is already in the right appearance (§3.2).
        applyTheme()
        themeObserver = NotificationCenter.default.addObserver(
            forName: AppTheme.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyTheme()
        }
        let windowController = MainWindowController()
        windowController.showWindow(nil)
        mainWindowController = windowController
        NSApp.activate(ignoringOtherApps: true)
        // The window is up; drain any files Launch Services handed us first.
        isReady = true
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            mainWindowController?.mainViewController.openFiles(urls)
        }
    }

    /// Finder double-click / "Open with" hands the file here. The app is
    /// single-window, so the files flow into the same open pipeline as the Open
    /// panel (§4.1); a file launched with the app opens directly into a pane.
    func application(_ application: NSApplication, open urls: [URL]) {
        if isReady {
            mainWindowController?.mainViewController.openFiles(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    /// Maps the stored theme onto `NSApp.appearance`: nil for system (follow the
    /// OS), an explicit appearance for light/dark.
    private func applyTheme() {
        NSApp.appearance = AppTheme.current.appearance
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
