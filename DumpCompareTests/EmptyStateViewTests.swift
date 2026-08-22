import XCTest
@testable import DumpCompare

/// §3.1 empty state: the landing screen is a large clickable icon (replacing
/// the old titled Open File button), a "Drop files here" headline and the
/// up-to-two-files hint. Clicking the icon is wired to the same open-panel
/// action the button used.
@MainActor
final class EmptyStateViewTests: XCTestCase {
    private func makeEmptyView() -> EmptyStateView {
        let view = EmptyStateView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        return view
    }

    /// The Open File affordance is now an icon button: the titled button is
    /// gone, replaced by a borderless button whose image carries the "Open File"
    /// accessibility label and fires the open-panel action.
    func testOpenFileIconReplacesTitledButton() {
        let view = makeEmptyView()
        let buttons = descendants(of: view, NSButton.self)

        XCTAssertFalse(buttons.contains { $0.title == "Open File" },
                       "the titled Open File button must be gone")
        guard let icon = buttons.first(where: { $0.accessibilityLabel() == "Open File" }) else {
            return XCTFail("an icon button labelled Open File must exist")
        }
        XCTAssertFalse(icon.isBordered)
        XCTAssertNotNil(icon.image)
        XCTAssertEqual(icon.action, #selector(MainViewController.presentOpenPanel))
    }

    func testHeadlineAndHint() {
        let view = makeEmptyView()
        let labels = descendants(of: view, NSTextField.self).map { $0.stringValue }

        XCTAssertTrue(labels.contains("Drop files here"), "the headline must be shown")
        XCTAssertTrue(labels.contains("Up to two files can be compared side by side."),
                      "the up-to-two-files hint must be shown")
    }

}
