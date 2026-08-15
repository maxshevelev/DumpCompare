import DumpCompareCore
import XCTest
@testable import DumpCompare

/// The Appearance settings (§3.2): the hex font family and the row-height
/// factor. Defaults to the system monospaced font at the built-in scale,
/// persists to UserDefaults, and notifies open hex views to re-lay out so the
/// dump reflects the change live.
@MainActor
final class AppearanceSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppearanceSettings.resetToDefaults()
    }

    override func tearDown() {
        AppearanceSettings.resetToDefaults()
        super.tearDown()
    }

    func testDefaultsToSystemFontAndDefaultScale() {
        XCTAssertEqual(AppearanceSettings.fontFamily, AppearanceSettings.systemFontSentinel)
        XCTAssertEqual(AppearanceSettings.rowHeightScale, AppearanceSettings.defaultRowHeightScale)
    }

    func testSetPersistsAndNotifies() throws {
        let family = try XCTUnwrap(AppearanceSettings.monospacedFontFamilies().first)
        var notified = 0
        // queue: nil delivers synchronously on the posting thread.
        let token = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: nil
        ) { _ in notified += 1 }

        AppearanceSettings.set(fontFamily: family, rowHeightScale: 0.9)

        XCTAssertEqual(AppearanceSettings.fontFamily, family)
        XCTAssertEqual(AppearanceSettings.rowHeightScale, 0.9)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppearanceSettings.fontFamilyKey), family)
        XCTAssertEqual(UserDefaults.standard.double(forKey: AppearanceSettings.rowHeightScaleKey), 0.9)
        XCTAssertEqual(notified, 1)

        NotificationCenter.default.removeObserver(token)
    }

    func testResetRestoresDefaults() {
        AppearanceSettings.set(fontFamily: "Menlo", rowHeightScale: 0.7)
        AppearanceSettings.resetToDefaults()
        XCTAssertEqual(AppearanceSettings.fontFamily, AppearanceSettings.systemFontSentinel)
        XCTAssertEqual(AppearanceSettings.rowHeightScale, AppearanceSettings.defaultRowHeightScale)
    }

    func testMonospacedFamiliesAreSortedAndFixedPitch() throws {
        let families = AppearanceSettings.monospacedFontFamilies()
        XCTAssertFalse(families.isEmpty, "the system has at least one monospaced family")
        XCTAssertEqual(families, families.sorted())
        for family in families {
            let font = try XCTUnwrap(
                NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)
            )
            XCTAssertTrue(font.isFixedPitch, "\(family) must be fixed-pitch")
        }
    }

    func testFontResolutionFallsBackToSystemMonospaced() {
        // Unknown family names fall back to the system monospaced font rather
        // than producing a broken font.
        AppearanceSettings.set(fontFamily: "No Such Family", rowHeightScale: 0.8)
        let resolved = AppearanceSettings.font(size: 13)
        let expected = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        XCTAssertTrue(resolved.isFixedPitch)
        XCTAssertEqual(resolved.familyName, expected.familyName)
    }
}
