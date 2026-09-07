import AppKit
import XCTest
@testable import ToolModuleKit

/// The three ways a scrolling detail is wrong by default, pinned down without a
/// panel around it.
@MainActor
final class ToolDetailScrollTests: XCTestCase {
    /// A detail sized like a panel's lower pane, laid out.
    private func scroll(height: CGFloat = 200) -> ToolDetailScroll {
        let scroll = ToolDetailScroll()
        scroll.translatesAutoresizingMaskIntoConstraints = true
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: height)
        scroll.layoutSubtreeIfNeeded()
        return scroll
    }

    private func row(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    func testTheDocumentStartsAtTheTop() {
        let scroll = self.scroll()

        XCTAssertTrue(scroll.documentView?.isFlipped ?? false,
                      "an unflipped document makes a scroll view show the bottom of "
                      + "anything taller than itself — the first row would be the "
                      + "one out of view")
    }

    func testWithNoRowsTheDocumentIsExactlyTheVisibleArea() {
        let scroll = self.scroll()
        scroll.showPlaceholder("Select a row to see what it is.")
        scroll.layoutSubtreeIfNeeded()

        let document = scroll.documentView?.frame.height ?? 0
        XCTAssertEqual(document, scroll.contentView.bounds.height, accuracy: 0.5,
                       "the placeholder is centred in the document, so the document "
                       + "has to be the visible area or the text sits below the fold")
        XCTAssertFalse(scroll.placeholder.isHidden)
    }

    func testRowsTallerThanTheVisibleAreaGrowTheDocument() {
        let scroll = self.scroll(height: 60)
        scroll.prepareForRows(subject: "row")
        for index in 0..<20 {
            scroll.content.addArrangedSubview(row("Field \(index)"))
        }
        scroll.layoutSubtreeIfNeeded()

        let document = scroll.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(document, scroll.contentView.bounds.height,
                             "twenty rows do not fit in 60 points, so the document "
                             + "grows and the detail scrolls")
        XCTAssertTrue(scroll.placeholder.isHidden)
    }

    /// Scrolls a filled detail down and hands back where it ended up.
    private func scrolledDetail(subject: String) -> (ToolDetailScroll, CGFloat) {
        let scroll = self.scroll(height: 60)
        scroll.prepareForRows(subject: subject)
        for index in 0..<20 {
            scroll.content.addArrangedSubview(row("Field \(index)"))
        }
        scroll.layoutSubtreeIfNeeded()
        scroll.documentView?.scroll(NSPoint(x: 0, y: 120))
        scroll.layoutSubtreeIfNeeded()
        return (scroll, scroll.documentVisibleRect.origin.y)
    }

    func testADifferentSubjectOpensAtItsFirstRow() {
        let (scroll, scrolled) = scrolledDetail(subject: "row 1")
        XCTAssertGreaterThan(scrolled, 0, "the detail was scrolled down first")

        scroll.prepareForRows(subject: "row 2")
        scroll.content.addArrangedSubview(row("Only field"))
        scroll.layoutSubtreeIfNeeded()

        XCTAssertEqual(scroll.documentVisibleRect.origin.y, 0, accuracy: 0.5,
                       "another row's fields start at the first one, not wherever "
                       + "the last row had been left")
    }

    /// A panel re-reads for reasons that are nothing to do with the user — an
    /// edit anywhere in the dump costs a re-parse, and the panel re-renders the
    /// same row from it. That must not move the reader.
    func testTheSameSubjectKeepsTheReadersPlace() {
        let (scroll, scrolled) = scrolledDetail(subject: "row 1")
        XCTAssertGreaterThan(scrolled, 0, "the detail was scrolled down first")

        scroll.prepareForRows(subject: "row 1")
        for index in 0..<20 {
            scroll.content.addArrangedSubview(row("Field \(index)"))
        }
        scroll.layoutSubtreeIfNeeded()

        XCTAssertEqual(scroll.documentVisibleRect.origin.y, scrolled, accuracy: 0.5,
                       "a re-read of the same row left the detail where it was")
    }

    /// The placeholder forgets the subject: the row it described is no longer
    /// on screen, so the next row's fields are a fresh start.
    func testAfterThePlaceholderTheNextSubjectStartsAtTheTop() {
        let (scroll, _) = scrolledDetail(subject: "row 1")
        scroll.showPlaceholder("Nothing selected.")
        scroll.layoutSubtreeIfNeeded()

        scroll.prepareForRows(subject: "row 1")
        for index in 0..<20 {
            scroll.content.addArrangedSubview(row("Field \(index)"))
        }
        scroll.layoutSubtreeIfNeeded()

        XCTAssertEqual(scroll.documentVisibleRect.origin.y, 0, accuracy: 0.5,
                       "the same row picked again after nothing was selected "
                       + "opens at its first field")
    }

    func testThePlaceholderAndTheRowsAreNeverBothOnScreen() {
        let scroll = self.scroll()
        scroll.prepareForRows(subject: "row")
        scroll.content.addArrangedSubview(row("Field"))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.placeholder.isHidden, "rows replace the placeholder")

        scroll.showPlaceholder("Nothing selected.")
        scroll.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.content.arrangedSubviews.isEmpty,
                      "the placeholder replaces the rows")
    }
}
