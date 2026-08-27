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
        AppearanceSettings.set(fontFamily: "Menlo", rowHeightScale: 0.7, fontSize: 20)
        AppearanceSettings.resetToDefaults()
        // Written out rather than read back from the constants under test: with
        // `defaultRowHeightScale` on both sides of the assertion, a default of
        // 3.0 would pass here and triple every row in the dump.
        XCTAssertEqual(AppearanceSettings.fontFamily, "")
        XCTAssertEqual(AppearanceSettings.rowHeightScale, 0.8, accuracy: 0.0001)
        XCTAssertEqual(AppearanceSettings.fontSize, 13, accuracy: 0.0001)
    }

    /// The font size defaults to the built-in 13 pt and persists like the other
    /// appearance values (§3.2).
    func testFontSizeDefaultsTo13() {
        // resetToDefaults in setUp cleared the stored size.
        XCTAssertEqual(AppearanceSettings.fontSize, 13, accuracy: 0.0001)
    }

    func testSetFontSizePersistsAndNotifies() {
        var notified = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: nil
        ) { _ in notified += 1 }

        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily,
                               rowHeightScale: AppearanceSettings.rowHeightScale,
                               fontSize: 18)

        XCTAssertEqual(AppearanceSettings.fontSize, 18, accuracy: 0.0001)
        XCTAssertEqual(UserDefaults.standard.double(forKey: AppearanceSettings.fontSizeKey), 18)
        XCTAssertEqual(notified, 1)

        NotificationCenter.default.removeObserver(token)
    }

    /// `font()` with no explicit size uses the configured font size, so the dump
    /// follows the setting (§3.2).
    func testFontFollowsConfiguredSize() {
        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily,
                               rowHeightScale: AppearanceSettings.rowHeightScale,
                               fontSize: 20)
        XCTAssertEqual(AppearanceSettings.font().pointSize, 20, accuracy: 0.001)
        // An explicit size still wins over the setting.
        XCTAssertEqual(AppearanceSettings.font(size: 12).pointSize, 12, accuracy: 0.001)
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
