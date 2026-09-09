import XCTest
import AppKit
@testable import DumpCompare

/// The About panel's credits — the open-source projects whose data the app
/// shows, named with the links to follow (`AboutCredits`).
final class AboutCreditsTests: XCTestCase {
    /// The panel has to say that data came from outside, and the two projects
    /// that supplied it have to be named with their authors.
    func testTheCreditsNameBothProjectsAndTheirAuthors() throws {
        let text = AboutCredits.text().string

        XCTAssertTrue(text.contains("UEFITool"), "the UEFI data project is named")
        XCTAssertTrue(text.contains("LongSoft"), "UEFITool's author is named")
        XCTAssertTrue(text.contains("CPUMicrocodes"), "the microcode project is named")
        XCTAssertTrue(text.contains("platomav"), "CPUMicrocodes' author is named")
    }

    /// A project is only *usable* from the About panel if its name is a link —
    /// a bare mention would send the reader back to a search engine.
    func testEachProjectAndAuthorCarriesItsLink() throws {
        let attributed = AboutCredits.text()
        var links: [URL] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }

        XCTAssertTrue(links.contains(URL(string: "https://github.com/LongSoft/UEFITool")!))
        XCTAssertTrue(links.contains(URL(string: "https://github.com/LongSoft")!))
        XCTAssertTrue(links.contains(URL(string: "https://github.com/platomav/CPUMicrocodes")!))
        XCTAssertTrue(links.contains(URL(string: "https://github.com/platomav")!))
    }

    /// The credits render inside the standard About panel under whichever of
    /// the app's two themes is on, so no run may be painted a fixed colour.
    func testEveryRunUsesASemanticColour() throws {
        let attributed = AboutCredits.text()
        let semantic: [NSColor] = [.labelColor, .secondaryLabelColor, .linkColor]

        attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            guard let colour = value as? NSColor else {
                XCTFail("every run carries an explicit foreground colour")
                return
            }
            XCTAssertTrue(semantic.contains { $0.isEqual(colour) },
                          "\(colour) is fixed; the About panel must follow the theme")
        }
    }
}
