import XCTest
@testable import UEFIFormat

/// The pass that needs an address rather than an offset (§10).
final class SecondPassTests: XCTestCase {
    /// A 16 KiB image whose last bytes are a Volume Top File — the whole of
    /// what ties this format to an address.
    private var anchoredImage: [UInt8] {
        TestImage.volume(
            length: 0x4000,
            files: [TestImage.file(body: [1, 2, 3, 4, 5, 6, 7, 8])],
            lastFile: TestImage.volumeTopFile(size: 0x100)
        )
    }

    /// `addressDiff = 0x100000000 - (base + size)` of the last VTF (§5.7). For
    /// an image mapped right up against the top of the address space this is
    /// the same as `0x100000000 - image size`, which is the identity the FIT
    /// document leans on.
    func testTheVolumeTopFileFixesEveryAddress() {
        let parsed = UEFIParser.parse(anchoredImage)

        XCTAssertEqual(parsed.addressDiff, 0x1_0000_0000 - 0x4000)
        XCTAssertEqual(parsed.address(forOffset: 0x3FC0), 0xFFFF_FFC0)
        XCTAssertEqual(parsed.offset(forAddress: 0xFFFF_FFC0), 0x3FC0)
    }

    /// A dump of one BIOS region, or of an EC, has no VTF and is not defective
    /// for it. Addresses are simply unknown, and `addressDiff` says so without
    /// a diagnostic anyone has to dismiss.
    func testNoVolumeTopFileMeansNoAddressesAndNoComplaint() {
        let parsed = UEFIParser.parse(TestImage.volume(length: 0x1000))

        XCTAssertNil(parsed.addressDiff)
        XCTAssertNil(parsed.resetVector)
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// Moving the VTF moves every address in the image (§11).
    func testTheVolumeTopFileIsMarkedFixed() {
        let parsed = UEFIParser.parse(anchoredImage)
        let vtf = parsed.allNodes.first { $0.guid == KnownGUIDs.volumeTopFile }

        XCTAssertEqual(vtf?.name, "Volume Top File")
        XCTAssertEqual(vtf?.isFixed, true)
    }

    /// The image's own statement of where it is loaded, at the last
    /// forty-eight bytes of the address space.
    func testTheResetVectorIsReadFromInsideTheVolumeTopFile() {
        let parsed = UEFIParser.parse(anchoredImage)

        XCTAssertEqual(parsed.resetVector?.offset, 0x3FD0)
        XCTAssertEqual(parsed.resetVector?.peiCoreEntryPoint, 0xFFF8_0000)
        XCTAssertEqual(parsed.resetVector?.bootFvBaseAddress, 0xFFF0_0000)
        XCTAssertEqual(parsed.resetVector?.apStartupSegment, 0xFFFF_0000)
        XCTAssertEqual(parsed.resetVector?.resetVector, [UInt8](repeating: 0x90, count: 8))
        XCTAssertEqual(parsed.resetVector?.apEntryVector, [UInt8](repeating: 0xEA, count: 8))
    }

    /// EDK2 leaves a placeholder in the fields it did not fill in, and a
    /// consumer reading one as an address would follow it into nothing.
    func testAPlaceholderFieldIsNotAnAddress() {
        let image = TestImage.volume(
            length: 0x4000,
            lastFile: TestImage.volumeTopFile(size: 0x100, peiCoreEntryPoint: 0x1234_5678)
        )
        let vector = UEFIParser.parse(image).resetVector

        XCTAssertEqual(vector?.isFilledIn(vector!.peiCoreEntryPoint), false)
        XCTAssertEqual(vector?.isFilledIn(vector!.bootFvBaseAddress), true)
    }

    /// A file with the right GUID but no room for a reset vector in it. The
    /// image is still anchored — that comes from where the file ends — but
    /// there is no vector to read, and inventing one from the bytes before the
    /// file would be worse than saying so.
    func testAVolumeTopFileTooSmallForAResetVectorIsReported() {
        let image = TestImage.volume(
            length: 0x4000,
            lastFile: TestImage.file(
                guid: KnownGUIDs.volumeTopFile, body: [1, 2, 3, 4, 5, 6, 7, 8]
            )
        )

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.addressDiff, 0x1_0000_0000 - 0x4000)
        XCTAssertNil(parsed.resetVector)
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .truncated(.resetVector) })
    }

    /// Several VTFs in one image, and only the last one is at the top of the
    /// address space (§5.7).
    func testTheLastVolumeTopFileWins() {
        let image = TestImage.volume(
            length: 0x4000,
            files: [TestImage.volumeTopFile(size: 0x100)],
            lastFile: TestImage.volumeTopFile(size: 0x100)
        )

        let parsed = UEFIParser.parse(image)
        let fixed = parsed.allNodes.filter { $0.guid == KnownGUIDs.volumeTopFile && $0.isFixed }

        XCTAssertEqual(parsed.addressDiff, 0x1_0000_0000 - 0x4000)
        XCTAssertEqual(fixed.map(\.range), [0x3F00..<0x4000])
    }

    /// A VTF inside a volume that is itself inside a section is still the
    /// anchor, and the tree it has to be marked in is three levels deep.
    func testAVolumeTopFileNestedInASectionIsStillFound() {
        let inner = TestImage.volume(length: 0x400, lastFile: TestImage.volumeTopFile(size: 0x100))
        let image = TestImage.volume(
            length: 0x1000,
            files: [TestImage.sectionedFile(sections: [
                TestImage.section(type: Section.firmwareVolumeImage, body: inner)
            ])]
        )

        let parsed = UEFIParser.parse(image)
        let vtf = parsed.allNodes.first { $0.guid == KnownGUIDs.volumeTopFile }

        XCTAssertEqual(vtf?.isFixed, true)
        XCTAssertEqual(parsed.addressDiff, 0x1_0000_0000 - (vtf!.range.upperBound))
    }
}
