import XCTest
@testable import UEFIImage

/// What kind of thing the file is (§1): a capsule, an Intel flash dump, or
/// bytes to be searched.
final class TopLevelParseTests: XCTestCase {
    private let volume = TestImage.volume(
        length: 0x1000,
        files: [TestImage.file(body: [1, 2, 3, 4, 5, 6, 7, 8])]
    )

    // MARK: - Intel images

    /// The whole image is one node of kind `.intelImage` whose body is the
    /// file; the descriptor, regions and the padding between them sit under it
    /// (§2.2).
    func testAnIntelImageIsOneNodeOverTheWholeDump() {
        let image = TestImage.intelImage(
            size: 0x8000,
            regions: [
                (.descriptor, 0..<0x1000),
                (.me, 0x1000..<0x3000),
                (.bios, 0x4000..<0x8000)
            ],
            contents: [.bios: volume]
        )

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.roots.map(\.kind), [.intelImage])
        let root = parsed.roots[0]
        XCTAssertEqual(root.name, "Intel image")
        XCTAssertEqual(root.subtype, UEFITypes.Sub.intelImage)
        XCTAssertEqual(root.uefiItemType, UEFITypes.Item.image.rawValue)
        XCTAssertEqual(root.header, 0..<0)
        XCTAssertEqual(root.body, 0..<0x8000)
        XCTAssertTrue(root.isFixed)
        XCTAssertEqual(
            root.children.map(\.kind),
            [.flashDescriptor, .region, .padding, .region]
        )
        XCTAssertEqual(
            root.children.map(\.range),
            [0..<0x1000, 0x1000..<0x3000, 0x3000..<0x4000, 0x4000..<0x8000]
        )
        XCTAssertEqual(root.children.map(\.name)[1], "ME region")
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// A BIOS region is volumes and padding; an ME region is a format of its
    /// own and is kept whole (§2.2).
    func testOnlySomeRegionsAreReadFurther() {
        let image = TestImage.intelImage(
            size: 0x8000,
            regions: [(.descriptor, 0..<0x1000), (.me, 0x1000..<0x2000), (.bios, 0x4000..<0x8000)],
            contents: [.bios: volume, .me: volume]
        )

        let parsed = UEFIParser.parse(image)
        let children = parsed.roots[0].children
        let me = children.first { $0.name == "ME region" }
        let bios = children.first { $0.name == "BIOS region" }

        XCTAssertEqual(me?.children.count, 0)
        XCTAssertEqual(bios?.children.map(\.kind), [.volume, .padding])
        XCTAssertEqual(bios?.children.first?.range, 0x4000..<0x5000)
    }

    /// A version 1 descriptor describes five regions, and the bytes of a sixth
    /// pair are something else entirely (§2.2).
    func testAVersionOneDescriptorReadsFiveRegions() {
        let regions: [(type: FlashRegionType, range: Range<UInt64>)] = [
            (.descriptor, 0..<0x1000),
            (.bios, 0x1000..<0x4000),
            (.microcode, 0x4000..<0x8000)
        ]
        let image = TestImage.intelImage(size: 0x8000, regions: regions, version1: true)

        let parsed = UEFIParser.parse(image)

        let children = parsed.roots[0].children
        XCTAssertEqual(children.map(\.kind), [.flashDescriptor, .region, .padding])
        XCTAssertNil(children.first { $0.name == "Microcode region" })
    }

    func testOverlappingRegionsAreReported() {
        let image = TestImage.intelImage(
            size: 0x8000,
            regions: [
                (.descriptor, 0..<0x1000),
                (.me, 0x1000..<0x5000),
                (.bios, 0x4000..<0x8000)
            ]
        )

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.overlappingRegions])
        XCTAssertEqual(parsed.roots[0].children.map(\.range), [0..<0x1000, 0x1000..<0x5000, 0x5000..<0x8000])
    }

    /// A dump that stops short of what the descriptor describes — half of a
    /// chip read over a bad connection is exactly this.
    func testARegionRunningPastTheEndIsCutAndReported() {
        let image = Array(TestImage.intelImage(
            size: 0x8000,
            regions: [(.descriptor, 0..<0x1000), (.bios, 0x1000..<0x8000)]
        )[0..<0x4000])

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.roots[0].children.map(\.range), [0..<0x1000, 0x1000..<0x4000])
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.truncated(.flashDescriptor)])
    }

    /// A descriptor whose own map is out of range is still a descriptor, and
    /// still an Intel image. The rest of the image gets searched rather than
    /// given up on (§2.2).
    func testABrokenRegionMapFallsBackToASearch() {
        var image = TestImage.intelImage(
            size: 0x8000,
            regions: [(.descriptor, 0..<0x1000), (.bios, 0x1000..<0x8000)]
        )
        image.replaceSubrange(0x1000..<(0x1000 + volume.count), with: volume)
        image[Int(Descriptor.mapOffset) + 2] = 0xFF     // RegionBase above 0xE0

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.truncated(.flashDescriptor)])
        let children = parsed.roots[0].children
        XCTAssertEqual(children.map(\.kind), [.flashDescriptor, .volume, .padding])
        XCTAssertEqual(children[1].range, 0x1000..<0x2000)
    }

    // MARK: - Capsules

    /// The envelope a vendor shipped the image in: the image starts where
    /// `HeaderSize` says, and reading from byte zero finds nothing (§1.1).
    func testACapsuleIsUnwrappedAndItsImageParsed() {
        let parsed = UEFIParser.parse(TestImage.capsule(body: volume))

        XCTAssertEqual(parsed.roots.map(\.kind), [.capsule])
        XCTAssertEqual(parsed.roots[0].name, "EFI capsule")
        XCTAssertEqual(parsed.roots[0].header, 0..<0x20)
        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.volume])
        XCTAssertEqual(parsed.roots[0].children[0].range, 0x20..<0x1020)
    }

    /// A capsule claiming less than the file holds has something after it, and
    /// dropping it silently would lose bytes (§1.1). A capsule and trailing
    /// bytes are two things at the top, so they are grouped under the UEFI
    /// image root the way any other multi-thing file is (§4).
    func testWhatFollowsACapsuleIsKept() {
        let parsed = UEFIParser.parse(TestImage.capsule(body: volume, trailing: 0x100))

        XCTAssertEqual(parsed.roots.map(\.kind), [.uefiImage])
        let children = parsed.roots[0].children
        XCTAssertEqual(children.map(\.kind), [.capsule, .padding])
        XCTAssertEqual(children.map(\.range), [0..<0x1020, 0x1020..<0x1120])
    }

    /// Aptio signed capsules put a certificate between the header and the
    /// image, and only `RomImageOffset` knows how long it is (§1.1).
    func testAnAptioCapsuleTakesItsBodyOffsetFromRomImageOffset() {
        let image = TestImage.capsule(
            guid: KnownGUIDs.guid("4A3CA68B-7723-48FB-803D-578CC1FEC44D"),
            headerSize: 0x20,
            romImageOffset: 0x100,
            body: volume
        )

        let parsed = UEFIParser.parse(image)

        // The certificate and trailing bytes leave padding after the capsule,
        // so the file is capsule + padding at the top and is grouped under the
        // image root; the capsule itself is its first child.
        XCTAssertEqual(parsed.roots.map(\.kind), [.uefiImage])
        let capsule = parsed.roots[0].children[0]
        XCTAssertEqual(capsule.name, "AMI Aptio signed capsule")
        XCTAssertEqual(capsule.header, 0..<0x100)
        XCTAssertEqual(capsule.children.map(\.kind), [.volume])
    }

    func testAGuidThatIsNotACapsuleIsJustBytes() {
        var image = [UInt8](repeating: 0xFF, count: 0x200)
        image.replaceSubrange(0..<16, with: TestImage.driverGUID.bytes)

        XCTAssertEqual(UEFIParser.parse(image).roots.map(\.kind), [.padding])
    }

    // MARK: - Microcode

    /// What a FIT table mostly points at, so the tree has to know one when it
    /// sees one (§7.1).
    func testMicrocodeIsFoundInARawArea() {
        let image = TestImage.image(padding: 0x100, TestImage.microcode(), after: 0x100)

        let parsed = UEFIParser.parse(image)
        // Padding, microcode, padding — several things at the top, so they sit
        // under the image root; the microcode is the middle child.
        let microcode = parsed.roots[0].children[1]

        XCTAssertEqual(microcode.kind, .microcode)
        XCTAssertEqual(microcode.name, "Microcode 000306A9, revision 0000001F")
        XCTAssertEqual(microcode.header, 0x100..<0x130)
        XCTAssertEqual(microcode.body, 0x130..<0x170)
        XCTAssertTrue(microcode.isFixed)
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// The header read back as values, which is what a FIT entry pointing here
    /// has to be shown as.
    func testAMicrocodeHeaderReadsBackAsValues() {
        let image = TestImage.microcode(signature: 0x000A_0655, revision: 0x1C)
        let header = MicrocodeHeader.read(at: 0, in: ImageReader(image))

        XCTAssertEqual(header?.processorSignature, 0x000A_0655)
        XCTAssertEqual(header?.updateRevision, 0x1C)
        XCTAssertEqual(header?.date, "2019-07-15")
        XCTAssertEqual(header?.dataSize, 0x40)
        XCTAssertEqual(header?.range, 0..<0x70)
    }

    /// The header carries whether the image's dwords sum to zero, so a panel
    /// can say the checksum counts without re-reading the image.
    func testTheHeaderSaysWhetherItsImageSumsToZero() {
        let good = MicrocodeHeader.read(at: 0, in: ImageReader(TestImage.microcode()))
        XCTAssertTrue(good?.checksumIsCorrect ?? false)

        // A checksum that does not make the sum zero reads as not counting.
        let bad = MicrocodeHeader.read(
            at: 0, in: ImageReader(TestImage.microcode(checksum: 0xDEAD_BEEF))
        )
        XCTAssertFalse(bad?.checksumIsCorrect ?? true)
    }

    /// The header also says what the field would have to be for the sum to come
    /// out zero — the value a fix writes — so a panel that shows the image's
    /// checksum wrong can say what it should be. A correct image is already
    /// that value, and an unreadable one has no answer.
    func testTheHeaderSaysWhatTheChecksumShouldBe() {
        // A wrong stored field reads back the correct one the fixture put in
        // place of `0xDEAD_BEEF` — the value a fix would write back.
        let good = MicrocodeHeader.read(at: 0, in: ImageReader(TestImage.microcode()))
        let bad = MicrocodeHeader.read(
            at: 0, in: ImageReader(TestImage.microcode(checksum: 0xDEAD_BEEF))
        )
        XCTAssertEqual(bad?.computedChecksum, good?.checksum)
        // The stored value of a correct image is the value it should be.
        XCTAssertEqual(good?.computedChecksum, good?.checksum)
        XCTAssertNotEqual(bad?.computedChecksum, bad?.checksum)

        // A header whose declared total runs past the image cannot be summed,
        // so there is nothing to say it should be — not a fabricated answer.
        var truncated = TestImage.microcode(totalSize: 0x2000)
        truncated = Array(truncated.prefix(0x100))
        let ragged = MicrocodeHeader.read(at: 0, in: ImageReader(truncated))
        XCTAssertFalse(ragged?.checksumIsCorrect ?? true)
        XCTAssertNil(ragged?.computedChecksum)
    }

    func testBytesThatAreNotMicrocodeReadBackAsNothing() {
        XCTAssertNil(MicrocodeHeader.read(
            at: 0, in: ImageReader([UInt8](repeating: 0xFF, count: 0x100))
        ))
        XCTAssertNil(MicrocodeHeader.read(at: 0, in: ImageReader([UInt8]([1, 0, 0, 0]))))
    }

    /// The dword `0x00000001` is everywhere. Only the whole header — the loader
    /// revision, the sizes and the BCD date — decides.
    func testADwordOfOneIsNotMicrocode() {
        var image = [UInt8](repeating: 0x00, count: 0x200)
        image[0x40] = 0x01

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.roots.map(\.kind), [.padding])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    func testAnImpossibleDateIsNotMicrocode() {
        let image = TestImage.microcode(year: 0x2019, month: 0x13, day: 0x15)

        XCTAssertEqual(UEFIParser.parse(image).roots.map(\.kind), [.padding])
    }

    func testMicrocodeWithABrokenChecksumIsReported() {
        let image = TestImage.microcode(checksum: 0x1234)

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.roots.map(\.kind), [.microcode])
        XCTAssertEqual(parsed.diagnostics.count, 1)
        guard case .checksumMismatch(.microcodeHeader, let stored, _) = parsed.diagnostics[0].kind
        else { return XCTFail("expected a microcode checksum diagnostic") }
        XCTAssertEqual(stored, 0x1234)
    }

    /// An empty microcode slot is `FF FF FF FF` and is perfectly legal — the
    /// FIT specification allows entries pointing at one (§7.1).
    func testAnEmptySlotStaysPadding() {
        let image = [UInt8](repeating: 0xFF, count: 0x200)

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.roots.map(\.kind), [.padding])
        XCTAssertTrue(parsed.roots[0].isErased)
    }

    /// A microcode region is a run of them, back to back.
    func testAMicrocodeRegionIsReadAsMicrocode() {
        let image = TestImage.intelImage(
            size: 0x8000,
            regions: [(.descriptor, 0..<0x1000), (.microcode, 0x1000..<0x2000)],
            contents: [.microcode: TestImage.microcode() + TestImage.microcode(revision: 0x20)]
        )

        let parsed = UEFIParser.parse(image)
        let region = parsed.roots[0].children.first { $0.name == "Microcode region" }

        XCTAssertEqual(region?.children.map(\.kind), [.microcode, .microcode, .padding])
        XCTAssertEqual(region?.children.map(\.range).first, 0x1000..<0x1070)
    }

    // MARK: - The UEFI image wrapper

    /// The tree has one root. A lone volume off a chip already is that root —
    /// it is not wrapped in an invented image it is not.
    func testALoneVolumeIsItsOwnRoot() {
        let parsed = UEFIParser.parse(volume)

        XCTAssertEqual(parsed.roots.count, 1)
        let root = parsed.roots[0]
        XCTAssertEqual(root.kind, .volume)
        XCTAssertEqual(root.header, 0..<0x48)
        XCTAssertEqual(root.body, 0x48..<0x1000)
        XCTAssertEqual(root.children.map(\.kind).first, .file)
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// Several things at the top — a run of microcode with padding around it —
    /// are a file that is more than one image, and are grouped under the UEFI
    /// image node UEFITool always shows as its root (§4).
    func testSeveralThingsAtTheTopAreGroupedUnderAUefiImage() {
        let image = TestImage.image(padding: 0x100, TestImage.microcode(), after: 0x100)

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.roots.count, 1)
        let root = parsed.roots[0]
        XCTAssertEqual(root.kind, .uefiImage)
        XCTAssertEqual(root.name, "UEFI image")
        XCTAssertEqual(root.subtype, UEFITypes.Sub.uefiImage)
        XCTAssertEqual(root.uefiItemType, UEFITypes.Item.image.rawValue)
        XCTAssertEqual(root.header, 0..<0)
        XCTAssertEqual(root.body, 0..<0x270)
        XCTAssertTrue(root.isFixed)
        XCTAssertEqual(root.children.map(\.kind), [.padding, .microcode, .padding])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// The wrapper is not invented a second time around a file that is already
    /// an Intel image: that root stays the single root, with the descriptor and
    /// regions under it, not under a UEFI image.
    func testAnIntelImageIsNotWrappedInAUefiImage() {
        let image = TestImage.intelImage(
            size: 0x8000,
            regions: [(.descriptor, 0..<0x1000), (.bios, 0x1000..<0x8000)],
            contents: [.bios: volume]
        )

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.roots.count, 1)
        XCTAssertEqual(parsed.roots.map(\.kind), [.intelImage])
    }
}
