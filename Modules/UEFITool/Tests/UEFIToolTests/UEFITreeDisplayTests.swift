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

    // MARK: - The hidden top row

    /// The image the parser groups several things under: one `.uefiImage` over
    /// the whole file, holding the scan of it (§4). Whatever the children, the
    /// fold that hides it keys off them, never off its kind.
    private func wrapperImage(_ children: [UEFINode]) -> UEFIImage {
        let wrapper = UEFINode(
            kind: .uefiImage,
            subtype: UEFITypes.Sub.uefiImage,
            name: "UEFI image",
            header: 0..<0,
            body: 0..<0x1000,
            isFixed: true,
            children: children
        )
        return UEFIImage(size: 0x1000, roots: [wrapper])
    }

    private func volumeNode() -> UEFINode {
        UEFINode(
            kind: .volume,
            subtype: 2,
            name: "FFSv2",
            guid: KnownGUIDs.ffsV2,
            header: 0..<0x38,
            body: 0x38..<0x1000
        )
    }

    /// The parser's image root does no work as a row: its one job is to say the
    /// whole image is UEFI, so it moves into the title and its children open the
    /// outline. The summary leads with the root's name.
    func testAnImageRootIsFoldedIntoTheTitle() {
        let presented = UEFITreeDisplay.present(wrapperImage([volumeNode()]))

        XCTAssertEqual(presented.title?.kind, .uefiImage)
        XCTAssertEqual(presented.title?.name, "UEFI image")
        XCTAssertEqual(presented.rows.map(\.kind), [.volume])
    }

    /// A lone real root the file already had — a volume off a chip — folds the
    /// same way the invented image root does, whatever its header: the predicate
    /// is purely structural, one root with children of its own. Its children
    /// open the tree, and the title names it by its type, the words its row
    /// would have shown.
    func testALoneRealRootWithChildrenIsFoldedIntoTheTitle() {
        let volume = UEFINode(
            kind: .volume,
            subtype: 2,
            name: "FFSv2",
            guid: KnownGUIDs.ffsV2,
            header: 0..<0x38,
            body: 0x38..<0x1000,
            children: [
                UEFINode(kind: .file, name: "", header: 0..<0x18, body: 0x18..<0x40)
            ]
        )
        let image = UEFIImage(size: 0x1000, roots: [volume])

        let presented = UEFITreeDisplay.present(image)

        XCTAssertEqual(presented.title?.kind, .volume)
        XCTAssertEqual(presented.rows.map(\.kind), [.file])
        XCTAssertEqual(
            UEFITreeDisplay.summary(of: image),
            "Volume · FFSv2 · 2 nodes · 1 volume · 1 file"
        )
    }

    /// A root with nothing under it has no tree to open and no children to put
    /// in its place, so it stays the one row — the fold keys off the children,
    /// not off the kind or the header.
    func testALeafRootIsNotFoldedAway() {
        let volume = volumeNode()
        let image = UEFIImage(size: 0x1000, roots: [volume])

        let presented = UEFITreeDisplay.present(image)

        XCTAssertNil(presented.title)
        XCTAssertEqual(presented.rows.map(\.kind), [.volume])
        XCTAssertEqual(UEFITreeDisplay.summary(of: image), "Volume · FFSv2 · 1 node · 1 volume")
    }

    /// A file with several roots has no single top to stand for — each row earns
    /// its place, so none is folded into the title.
    func testARootWithSeveralTopsIsNotFoldedAway() {
        let capsule = UEFINode(
            kind: .capsule, name: "EFI capsule",
            header: 0..<0x20, body: 0x20..<0x1020
        )
        let padding = UEFINode(kind: .padding, name: "", range: 0x1020..<0x1120)
        let image = UEFIImage(size: 0x1120, roots: [capsule, padding])

        let presented = UEFITreeDisplay.present(image)

        XCTAssertNil(presented.title)
        XCTAssertEqual(presented.rows.map(\.kind), [.capsule, .padding])
        XCTAssertEqual(UEFITreeDisplay.summary(of: image), "Capsule · 2 nodes")
    }

    /// A single wrapper-shaped root with nothing under it is the leaf case above
    /// wearing a wrapper's kind: no children, so it stays a row.
    func testAnEmptyImageRootIsNotFoldedAway() {
        let image = wrapperImage([])

        let presented = UEFITreeDisplay.present(image)

        XCTAssertNil(presented.title)
        XCTAssertEqual(presented.rows.count, 1)
        XCTAssertEqual(UEFITreeDisplay.summary(of: image), "Image · UEFI · 1 node")
    }

    /// An image with nothing in it at all is not an image, and the summary says
    /// so instead of counting zero nodes.
    func testAnEmptyImageSummarySaysNothingLooksLikeFirmware() {
        XCTAssertEqual(UEFITreeDisplay.summary(of: UEFIImage(size: 0, roots: [])), "Nothing here looks like a firmware image.")
        XCTAssertEqual(UEFITreeDisplay.summary(of: nil), "")
    }

    /// The summary's lead is the folded root's name, and the count of what the
    /// tree accounts for follows it.
    func testASummaryLeadsWithTheRootNameAndCounts() {
        XCTAssertEqual(
            UEFITreeDisplay.summary(of: wrapperImage([volumeNode()])),
            "UEFI image · 2 nodes · 1 volume"
        )
    }

    /// The kind words the UEFI image root reads as: the Image type, the UEFI
    /// subtype, and the fallback name — the same words an Intel root gets, with
    /// the other subtype.
    func testAUefiImageReadsAsTheImageUefiWords() {
        let node = UEFINode(
            kind: .uefiImage,
            subtype: UEFITypes.Sub.uefiImage,
            name: "",
            header: 0..<0,
            body: 0..<0x100
        )

        XCTAssertEqual(UEFITreeDisplay.typeText(for: node), "Image")
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: node), "UEFI")
        XCTAssertEqual(UEFITreeDisplay.name(for: node, catalogue: .empty), "UEFI image")
    }
}
