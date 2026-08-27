import Cocoa
import XCTest
@testable import DumpCompare

/// The app theme (§3.2): follow the system, or force light / dark. Defaults to
/// system, persists to UserDefaults, and notifies so the app re-applies the
/// theme to `NSApp.appearance`.
@MainActor
final class AppThemeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppTheme.resetToDefaults()
    }

    override func tearDown() {
        AppTheme.resetToDefaults()
        super.tearDown()
    }

    func testThemeDefaultsToSystem() {
        XCTAssertEqual(AppTheme.current, .system)
    }

    func testSetPersistsAndNotifies() {
        var notified = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppTheme.didChangeNotification, object: nil, queue: nil
        ) { _ in notified += 1 }

        AppTheme.set(.dark)

        XCTAssertEqual(AppTheme.current, .dark)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.userDefaultsKey), "dark")
        XCTAssertEqual(notified, 1)

        NotificationCenter.default.removeObserver(token)
    }

    func testResetRestoresSystem() {
        AppTheme.set(.light)
        AppTheme.resetToDefaults()
        XCTAssertEqual(AppTheme.current, .system)
    }

    /// "System" maps to nil (follow the OS); light/dark map to the matching
    /// named appearances, and the two forced themes differ.
    func testAppearanceMapping() {
        XCTAssertNil(AppTheme.system.appearance)
        XCTAssertNotNil(AppTheme.light.appearance)
        XCTAssertNotNil(AppTheme.dark.appearance)
        XCTAssertNotEqual(AppTheme.light.appearance, AppTheme.dark.appearance)
    }

    func testTitles() {
        XCTAssertEqual(AppTheme.system.title, "System")
        XCTAssertEqual(AppTheme.light.title, "Light")
        XCTAssertEqual(AppTheme.dark.title, "Dark")
    }
}
