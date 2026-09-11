import Foundation

/// The one `UserDefaults` the app reads and writes.
///
/// Everything that keeps a preference goes through this rather than through
/// `UserDefaults.standard`, for one reason: the app suite runs the real app as
/// its test host, in the real container. Every test that set a word size, a
/// theme, a layout direction or a fill pattern was writing into the user's own
/// settings — and reading whatever the user had left there, which is a test
/// that passes or fails depending on the machine it runs on. The technical-debt
/// note in `Design/TODO.md` about a test that lands 4 pt out only in a full run
/// suspects exactly that kind of leftover.
///
/// Under a test run this is a suite of its own, wiped as the process starts, so
/// every run begins from the app's defaults and ends leaving nothing behind.
///
/// What it cannot cover: the autosaves AppKit performs itself — a window's
/// frame, a split view's positions, a toolbar's configuration — which go to
/// `UserDefaults.standard` inside AppKit and take no seam. Isolating those as
/// well means a different bundle identifier for the test host, which is a
/// different container and a build-configuration change.
enum AppDefaults {
    /// The suite a test run gets instead of the user's own settings.
    static let testSuiteName = "dev.maxik.DumpCompare.tests"

    static let store: UserDefaults = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
              let suite = UserDefaults(suiteName: testSuiteName)
        else { return .standard }
        // A run starts from the app's own defaults, whatever the last one did.
        suite.removePersistentDomain(forName: testSuiteName)
        return suite
    }()
}
