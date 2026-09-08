import XCTest
@testable import UEFITool
import UEFIImage

/// What the tree's columns and title say about a node, decided in the pure
/// target so the view controller lays out text rather than choosing any of it.
final class UEFITreeDisplayTests: XCTestCase {
    // MARK: - The Type column

    func testTheTypeColumnReadsTheNodeInUEFIToolWords() {
        XCTAssertEqual(UEFITreeDisplay.typeText(for: TestUEFI.volume().node), "Volume")
        XCTAssertEqual(UEFITreeDisplay.typeText(for: TestUEFI.file().node), "File")
        XCTAssertEqual(UEFITreeDisplay.typeText(for: TestUEFI.section().node), "Section")
        XCTAssertEqual(UEFITreeDisplay.typeText(for: TestUEFI.microcode().node), "Intel microcode")
        XCTAssertEqual(UEFITreeDisplay.typeText(for: TestUEFI.intelImage().node), "Image")
        XCTAssertEqual(UEFITreeDisplay.typeText(for: TestUEFI.padding().node), "Padding")
    }

    // MARK: - The Subtype column

    /// A file and a section are named from the FFS and section type tables the
    /// parser already uses — the generated table has no answer for them.
    func testAFileAndSectionSubtypeComeFromTheParserTables() {
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: TestUEFI.file(type: 0x07).node), "Driver")
        // An unknown file type keeps its number.
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: TestUEFI.file(type: 0x7F).node), "File type 0x7F")
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: TestUEFI.section(type: 0x19).node), "Raw")
    }

    /// Every other type reads from the generated `UEFITypes` tables.
    func testOtherSubtypesComeFromTheGeneratedTables() {
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: TestUEFI.volume().node), "FFSv2")
        let capsule = UEFINode(
            kind: .capsule, name: "",
            guid: EFIGUID("4A3CA68B-7723-48FB-803D-578CC1FEC44D"),
            header: 0..<0, body: 0..<0x100
        )
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: TestUEFI.intelImage().node), "Intel")
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: capsule), "Aptio signed")
        let region = UEFINode(kind: .region, subtype: 7, name: "", header: 0..<0, body: 0..<0x100)
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: region), "Microcode")
        let padding = UEFINode(kind: .padding, name: "", range: 0..<0x100, isErased: true)
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: padding), "Empty (FFh)")
    }

    /// A node with no subtype says nothing in the column — not a guess.
    func testANodeWithNoSubtypeLeavesTheColumnEmpty() {
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: TestUEFI.microcode().node), "")
        let freeSpace = UEFINode(kind: .freeSpace, name: "", range: 0..<0x100)
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: freeSpace), "")
    }

    // MARK: - The title

    /// The title leads with what the image is: the top of the tree, type and
    /// subtype. A capsule file leads with its capsule, a dump with its first root.
    func testTheTitleLeadsWithTheImageType() {
        XCTAssertEqual(UEFITreeDisplay.imageType(of: TestUEFI.volume().image), "Volume · FFSv2")
        XCTAssertEqual(UEFITreeDisplay.imageType(of: TestUEFI.intelImage().image), "Image · Intel")
        XCTAssertEqual(UEFITreeDisplay.imageType(of: TestUEFI.file().image), "File · Driver")
        let capsule = UEFINode(
            kind: .capsule, name: "",
            guid: EFIGUID("4A3CA68B-7723-48FB-803D-578CC1FEC44D"),
            header: 0..<0, body: 0..<0x100
        )
        XCTAssertEqual(UEFITreeDisplay.imageType(of: UEFIImage(size: 0x100, roots: [capsule])), "Capsule · Aptio signed")
    }

    /// A top with no subtype leads with the type alone.
    func testATitleWithNoSubtypeIsJustTheType() {
        XCTAssertEqual(UEFITreeDisplay.imageType(of: TestUEFI.microcode().image), "Intel microcode")
    }

    func testAnEmptyImageHasNoTypeToLeadWith() {
        XCTAssertEqual(UEFITreeDisplay.imageType(of: UEFIImage(size: 0, roots: [])), "")
    }

    // MARK: - The name

    /// A node with a GUID is named by the catalogue, and by the GUID itself
    /// while the catalogue has no name for it — the whole of the first paint
    /// before a download lands.
    func testAGuidNodeIsNamedByTheCatalogueOrTheGuid() {
        let volume = TestUEFI.volume().node
        let ffsV2 = KnownGUIDs.ffsV2

        XCTAssertEqual(UEFITreeDisplay.name(for: volume, catalogue: .empty), ffsV2.description)
        let named = GuidsCatalogue(names: [ffsV2: "Firmware File System 2"])
        XCTAssertEqual(UEFITreeDisplay.name(for: volume, catalogue: named), "Firmware File System 2")
    }

    /// A file with a GUID shows its GUID until the catalogue names it — the
    /// parser's own name is not a substitute for the community's.
    func testAFileWithAGuidShowsTheGuidUntilNamed() {
        let file = TestUEFI.file().node
        let guid = KnownGUIDs.volumeTopFile

        XCTAssertEqual(UEFITreeDisplay.name(for: file, catalogue: .empty), guid.description)
        let named = GuidsCatalogue(names: [guid: "Volume Top File"])
        XCTAssertEqual(UEFITreeDisplay.name(for: file, catalogue: named), "Volume Top File")
    }

    /// A node without a GUID keeps the name the parser gave it.
    func testANodeWithoutAGuidKeepsItsParserName() {
        let freeSpace = UEFINode(kind: .freeSpace, name: "Tail", range: 0..<0x100)
        XCTAssertEqual(UEFITreeDisplay.name(for: freeSpace, catalogue: .empty), "Tail")
    }

    /// A node without a GUID and without a name falls back to its kind.
    func testANodeWithoutAGuidOrNameFallsBackToItsKind() {
        let padding = UEFINode(kind: .padding, name: "", range: 0..<0x100)
        XCTAssertEqual(UEFITreeDisplay.name(for: padding, catalogue: .empty), "Padding")
    }
}
