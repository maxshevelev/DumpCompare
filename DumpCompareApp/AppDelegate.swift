import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Every open comparison window, in the order they were made. The app owns
    /// its windows rather than being one window's owner: ⇧⌘N adds one, closing
    /// one drops it, and a file handed to the app has to be routed to one of
    /// them rather than to "the" window.
    private var windowControllers: [MainWindowController] = []

    /// Drops a window from `windowControllers` when it closes, so a closed
    /// window is neither kept alive nor offered a file to open.
    private var closeObserver: NSObjectProtocol?
    /// URLs handed to us by Launch Services before the window existed. An
    /// "Open with" / double-click launch can deliver `application(_:open:)`
    /// before `applicationDidFinishLaunching` finishes building the window, so
    /// they queue here and drain once it is up.
    private var pendingOpenURLs: [URL] = []
    private var isReady = false
    /// Observes theme changes so a Settings change re-themes the running app
    /// without a relaunch (§3.2).
    private var themeObserver: NSObjectProtocol?

    /// The Settings window, owned by the app rather than by a window: there is
    /// one of it however many windows are open. Lazy, so it is not built until
    /// ⌘, is pressed.
    private lazy var settingsWindowController = SettingsWindowController()

    /// Which window has which file open (§4.1 rule 6). The application's, not a
    /// window's: the rule is that a file is open once in the app, and only
    /// something above the windows can answer that.
    private lazy var openDocuments = OpenDocumentRegistry()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app is single-window, so the system's automatic window tabbing
        // (which would otherwise inject "Show Tab Bar"/"Show All Tabs" into the
        // View menu) has nothing to merge and is dead UI. Disable it.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Apply the stored theme before any window appears, so the first frame
        // is already in the right appearance (§3.2).
        applyTheme()
        // The menu bar belongs to the application, not to a window: it is built
        // once, here, and its commands travel the responder chain to whichever
        // window is key.
        NSApp.mainMenu = MainMenu.build(settingsTarget: self)
        themeObserver = NotificationCenter.default.addObserver(
            forName: AppTheme.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyTheme()
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                self?.windowControllers.removeAll { $0.window === window }
            }
        }
        makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        // The window is up; drain any files Launch Services handed us first.
        isReady = true
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            openFiles(urls)
        }
    }

    /// File ▸ New Window (⇧⌘N).
    @objc func newWindow(_ sender: Any?) {
        makeWindow()
    }

    /// Builds a window, wires it to the application's open-file registry, and
    /// shows it.
    ///
    /// Only the first window saves its frame: one autosave name can serve one
    /// window, so every later one is cascaded off the window in front of it
    /// instead — which is also where a new window belongs on screen.
    @discardableResult
    private func makeWindow() -> MainWindowController {
        // Only the launch window saves a frame: one autosave name can serve one
        // window, and a second window writing to the same key would fight the
        // first over one saved size.
        let isFirst = windowControllers.isEmpty
        let controller = MainWindowController(
            frameAutosaveName: isFirst ? "MainWindow" : nil)
        controller.mainViewController.openDocuments = openDocuments
        openDocuments.register(controller.mainViewController)
        windowControllers.append(controller)
        // Nothing places the window by hand: `NSWindowController` cascades a
        // window it shows unless that window autosaves its frame, so the launch
        // window lands where it was left and every later one steps down and
        // right of the one in front.
        controller.showWindow(nil)
        return controller
    }

    /// The window a file handed to the app should open into: the one in front,
    /// or a fresh one when every window has been closed (the app stays running
    /// with no window only while something else keeps it alive).
    private func openFiles(_ urls: [URL]) {
        let controller = frontmostWindowController() ?? makeWindow()
        controller.mainViewController.openFiles(urls)
    }

    /// The key window's controller, else the most recently made one.
    private func frontmostWindowController() -> MainWindowController? {
        if let key = NSApp.keyWindow,
           let controller = windowControllers.first(where: { $0.window === key }) {
            return controller
        }
        return windowControllers.last
    }

    /// Finder double-click / "Open with" hands the file here. The files flow
    /// into the same open pipeline as the Open panel (§4.1), in the window in
    /// front — a file launched with the app opens directly into a pane.
    func application(_ application: NSApplication, open urls: [URL]) {
        if isReady {
            openFiles(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.showWindow(sender)
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
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
