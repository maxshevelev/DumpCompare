import DumpCompareCore
import XCTest
@testable import DumpCompare

/// The Comparison settings (§10.3.1): the distance that decides what Next /
/// Previous Difference treats as one change. Defaults to 64 bytes, persists to
/// UserDefaults, notifies so an open comparison re-groups live, and is offered
/// as its own Settings tab.
@MainActor
final class ComparisonSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ComparisonSettings.resetToDefaults()
    }

    override func tearDown() {
        ComparisonSettings.resetToDefaults()
        super.tearDown()
    }

    func testDefaultsToFourRows() {
        XCTAssertEqual(ComparisonSettings.groupingGap, 64)
        XCTAssertEqual(ComparisonSettings.groupingGap, ComparisonSettings.defaultGroupingGap)
        XCTAssertEqual(ComparisonSettings.groupingGapChoices, [16, 32, 64, 256])
    }

    func testSetPersistsAndNotifies() {
        var notified = 0
        // queue: nil delivers synchronously on the posting thread.
        let token = NotificationCenter.default.addObserver(
            forName: ComparisonSettings.didChangeNotification, object: nil, queue: nil
        ) { _ in notified += 1 }

        ComparisonSettings.set(groupingGap: 32)

        XCTAssertEqual(ComparisonSettings.groupingGap, 32)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: ComparisonSettings.groupingGapKey), 32)
        XCTAssertEqual(notified, 1)

        NotificationCenter.default.removeObserver(token)
    }

    /// A value the popup no longer offers (an older build, a hand-edited plist)
    /// must not leave navigation grouping by something arbitrary.
    func testAnUnrecognisedStoredValueFallsBackToTheDefault() {
        UserDefaults.standard.set(7, forKey: ComparisonSettings.groupingGapKey)
        XCTAssertEqual(ComparisonSettings.groupingGap, ComparisonSettings.defaultGroupingGap)
    }

    func testResetRestoresTheDefault() {
        ComparisonSettings.set(groupingGap: 256)
        ComparisonSettings.resetToDefaults()
        XCTAssertEqual(ComparisonSettings.groupingGap, ComparisonSettings.defaultGroupingGap)
    }

    // MARK: - The tab

    /// The popup lists every choice in bytes and rows, with the stored value
    /// selected.
    func testThePopupListsTheChoicesAndSelectsTheCurrentOne() throws {
        ComparisonSettings.set(groupingGap: 32)
        let controller = ComparisonSettingsViewController()
        controller.loadView()
        let popup = try XCTUnwrap(descendants(of: controller.view, NSPopUpButton.self).first)

        XCTAssertEqual(popup.itemTitles,
                       ["16 bytes (1 row)", "32 bytes (2 rows)", "64 bytes (4 rows)", "256 bytes (16 rows)"])
        XCTAssertEqual(popup.titleOfSelectedItem, "32 bytes (2 rows)")
    }

    /// Choosing an item writes the setting immediately — no Apply button.
    func testChoosingAnItemPersistsTheDistance() throws {
        let controller = ComparisonSettingsViewController()
        controller.loadView()
        let popup = try XCTUnwrap(descendants(of: controller.view, NSPopUpButton.self).first)

        // Not the default, so the assertion needs the write to have happened.
        popup.selectItem(withTitle: "256 bytes (16 rows)")
        NSApp.sendAction(popup.action!, to: popup.target, from: popup)

        XCTAssertEqual(ComparisonSettings.groupingGap, 256)
    }

    /// The Settings window offers the tab and switches to it.
    func testTheSettingsWindowHasAComparisonTab() throws {
        let settings = SettingsWindowController()
        let toolbar = try XCTUnwrap(settings.window?.toolbar)
        let identifier = NSToolbarItem.Identifier("Comparison")
        XCTAssertTrue(settings.toolbarDefaultItemIdentifiers(toolbar).contains(identifier))

        let item = try XCTUnwrap(settings.toolbar(toolbar, itemForItemIdentifier: identifier,
                                                  willBeInsertedIntoToolbar: true))
        XCTAssertEqual(item.label, "Comparison")
        let target = try XCTUnwrap(item.target as? NSObject)
        target.perform(try XCTUnwrap(item.action))
        XCTAssertTrue(settings.window?.contentViewController is ComparisonSettingsViewController)
    }

}
