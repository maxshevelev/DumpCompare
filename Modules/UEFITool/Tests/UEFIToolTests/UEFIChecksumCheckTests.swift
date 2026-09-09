import XCTest
import UEFIImage
@testable import UEFITool

/// `UEFIChecksumCheck`: which checksum fields of a node are wrong, found the
/// same way a fix would be found — `UEFIChemsums.repairs` returns only the
/// writes that differ, so empty means valid and non-empty is both the flag and
/// the fix.
final class UEFIChecksumCheckTests: XCTestCase {
    // MARK: - Volume

    /// A volume whose stored checksum disagrees with its header is one
    /// `.volume` problem, and the fix repairs exactly the checksum bytes.
    func testACorruptVolumeHeaderFlagsVolume() {
        var built = TestUEFI.volume(checksum: 0xFFFF)
        built = changed(built, at: 0x05, to: built.bytes[0x05] &+ 1)  // a GUID byte

        XCTAssertEqual(badFields(of: built)[volumeID(built)], [.volume])

        let fixed = fixing(built)
        XCTAssertTrue(badFields(of: fixed).isEmpty, "writing back the repair clears the flag")
    }

    /// A volume whose checksum already checks out is not flagged at all.
    func testAValidVolumeIsNotFlagged() {
        let fixed = fixing(TestUEFI.volume(checksum: 0xFFFF))
        XCTAssertTrue(badFields(of: fixed).isEmpty)
    }

    // MARK: - FFS file inside a volume

    /// With the checksum attribute bit set a file checks its body by sum; a
    /// flipped body byte is a `.fileBody` problem and a flipped header byte is
    /// `.fileHeader`. Both start from a fully valid file so the other field
    /// cannot leak in.
    func testFileHeaderAndBodyAreDistinctFields() {
        let valid = fixingFile(TestUEFI.file(attributes: 0x44, bodyChecksum: 0), revision: 2)

        let bodyCorrupt = valid.changedFileByte(0x18, to: 0x01)
        XCTAssertEqual(bodyCorrupt.badFields()[bodyCorrupt.file.id], [.fileBody])

        let headerCorrupt = valid.changedFileByte(0x00, to: 0x01)
        XCTAssertEqual(headerCorrupt.badFields()[headerCorrupt.file.id], [.fileHeader])
    }

    /// With the checksum attribute bit unset a file's body must hold the fixed
    /// value of the volume's revision — `0x5A` for revision 1, `0xAA` for
    /// revision 2 — and the body is flagged when it holds the other one.
    func testUncheckedFileBodyHonoursTheVolumeRevision() {
        for (revision, own) in [(1 as UInt8, 0x5A as UInt8), (2 as UInt8, 0xAA as UInt8)] {
            let other: UInt8 = revision == 1 ? 0xAA : 0x5A
            let valid = fixingFile(TestUEFI.file(attributes: 0x04, bodyChecksum: own), revision: revision)
            let wrongBody = valid.changedFileByte(0x11, to: other)  // the stored body checksum byte
            XCTAssertEqual(
                wrongBody.badFields()[wrongBody.file.id],
                [.fileBody],
                "revision \(revision) file wants 0x\(String(own, radix: 16)), not 0x\(String(other, radix: 16))"
            )
        }
    }

    /// The revision a file is checked against is its volume's, read from the
    /// volume's subtype; a volume-less file has no revision.
    func testVolumeRevisionComesFromTheContainingVolume() {
        let held = volumeHolding(TestUEFI.file(), revision: 3)
        XCTAssertEqual(UEFIChecksumCheck.volumeRevision(of: held.file, in: held.image), 3)

        let alone = TestUEFI.file()
        XCTAssertNil(UEFIChecksumCheck.volumeRevision(of: alone.node, in: alone.image))
    }

    // MARK: - Microcode

    /// A microcode image is one `.microcode` problem when a dword anywhere in
    /// its range is off, and the fix lands on the single checksum dword.
    func testACorruptMicrocodeFlagsMicrocode() {
        let corrupt = changed(TestUEFI.microcode(), at: 0x60) { $0 &+ 1 }  // a body byte
        XCTAssertEqual(badFields(of: corrupt)[microcodeID(corrupt)], [.microcode])

        let repair = UEFIChecksumCheck.repairs(
            for: corrupt.node, volumeRevision: nil, in: corrupt.reader
        )
        XCTAssertEqual(repair.first?.offset, 0x10)
        XCTAssertEqual(repair.count, 1)

        let fixed = fixing(corrupt)
        XCTAssertTrue(badFields(of: fixed).isEmpty)
    }

    /// Writing back what `repairs` says makes the whole image sum to zero — the
    /// round trip every valid case above rests on.
    func testWritingTheRepairMakesASumZeroImage() {
        let fixed = fixing(TestUEFI.microcode())
        XCTAssertEqual(Checksums.sum32(of: fixed.node.range, in: fixed.reader), 0)
    }

    // MARK: - A real volume holding a real file

    /// A volume with a genuine header (and a checksum `repairs` agrees with)
    /// that holds the fixture's file in its body, at the offset its header
    /// leaves — the shape a parse produces, so `badFields` can walk it the way
    /// the session will.
    private struct Holding {
        var bytes: [UInt8]
        let headerLength: Int
        let image: UEFIImage

        var file: UEFINode {
            image.allNodes.first { $0.kind == .file }!
        }

        var reader: ImageReader { ImageReader(bytes) }

        func badFields() -> [NodeID: Set<UEFIChecksumField>] {
            UEFIChecksumCheck.badFields(in: image, reader: reader)
        }

        /// The file's own byte `index` replaced, keeping the volume's header
        /// and the file's node where they are.
        func changedFileByte(_ index: Int, to value: UInt8) -> Holding {
            var bytes = bytes
            bytes[headerLength + index] = value
            return Holding(bytes: bytes, headerLength: headerLength, image: image)
        }
    }

    private func volumeHolding(_ file: TestUEFI.Built, revision: UInt8) -> Holding {
        let headerLength = 0x38
        let volume = TestUEFI.volume(
            revision: revision, headerLength: UInt16(headerLength), totalSize: UInt64(headerLength)
        )
        var bytes = volume.bytes  // the genuine 0x38-byte volume header
        bytes += file.bytes       // then the file, in the volume's body

        let fileNode = shifted(file.node, by: UInt64(headerLength))
        let volumeNode = UEFINode(
            kind: .volume,
            subtype: revision,
            name: "Vol",
            header: 0..<UInt64(headerLength),
            body: UInt64(headerLength)..<UInt64(bytes.count),
            children: [fileNode]
        )

        // The volume's stored checksum must already be right, or `badFields`
        // would flag the volume too — this is the container, not the test.
        var fixed = bytes
        for repair in UEFIChecksumCheck.repairs(for: volumeNode, volumeRevision: revision, in: ImageReader(bytes)) {
            for (index, byte) in repair.bytes.enumerated() {
                fixed[Int(repair.offset + UInt64(index))] = byte
            }
        }
        let image = UEFIImage(size: UInt64(fixed.count), roots: [volumeNode], addressDiff: nil)
        return Holding(bytes: fixed, headerLength: headerLength, image: image)
    }

    /// A file held by a volume whose checksums `repairs` writes back — a valid
    /// file, the start of every corrupt-one-field-at-a-time test.
    private func fixingFile(_ file: TestUEFI.Built, revision: UInt8) -> Holding {
        var holding = volumeHolding(file, revision: revision)
        let repairs = UEFIChecksumCheck.repairs(
            for: holding.file, volumeRevision: revision, in: holding.reader
        )
        XCTAssertFalse(repairs.isEmpty, "the fixture file was meant to be corrupt")
        var bytes = holding.bytes
        for repair in repairs {
            for (index, byte) in repair.bytes.enumerated() {
                bytes[Int(repair.offset + UInt64(index))] = byte
            }
        }
        return Holding(bytes: bytes, headerLength: holding.headerLength, image: holding.image)
    }

    /// The node's ranges slid down by `d`, so a structure built at offset zero
    /// sits where its container's body leaves room for it.
    private func shifted(_ node: UEFINode, by d: UInt64) -> UEFINode {
        var node = node
        node.header = (node.header.lowerBound + d)..<(node.header.upperBound + d)
        node.body = (node.body.lowerBound + d)..<(node.body.upperBound + d)
        node.tail = (node.tail.lowerBound + d)..<(node.tail.upperBound + d)
        node.children = node.children.map { shifted($0, by: d) }
        return node
    }

    // MARK: - Single-structure lookups and byte surgery

    private func volumeID(_ built: TestUEFI.Built) -> NodeID {
        built.image.allNodes.first { $0.kind == .volume }!.id
    }

    private func microcodeID(_ built: TestUEFI.Built) -> NodeID {
        built.image.allNodes.first { $0.kind == .microcode }!.id
    }

    private func badFields(of built: TestUEFI.Built) -> [NodeID: Set<UEFIChecksumField>] {
        UEFIChecksumCheck.badFields(in: built.image, reader: built.reader)
    }

    /// A copy of the fixture with one byte replaced — `Built.bytes` is a `let`,
    /// and the node and image ranges do not move, so only the bytes change.
    private func changed(
        _ built: TestUEFI.Built, at index: Int, to value: UInt8
    ) -> TestUEFI.Built {
        var bytes = built.bytes
        bytes[index] = value
        return TestUEFI.Built(bytes: bytes, node: built.node, image: built.image)
    }

    private func changed(
        _ built: TestUEFI.Built, at index: Int, _ transform: (UInt8) -> UInt8
    ) -> TestUEFI.Built {
        changed(built, at: index, to: transform(built.bytes[index]))
    }

    /// Writes back what `UEFIChecksumCheck.repairs` says the node's checksums
    /// should be. The result must be a valid node — the contrast every
    /// "valid → empty" assertion needs, found by construction rather than by a
    /// second copy of the arithmetic.
    private func fixing(_ built: TestUEFI.Built) -> TestUEFI.Built {
        let repairs = UEFIChecksumCheck.repairs(
            for: built.node, volumeRevision: nil, in: built.reader
        )
        XCTAssertFalse(repairs.isEmpty, "the fixture was meant to be corrupt")
        var bytes = built.bytes
        for repair in repairs {
            for (index, byte) in repair.bytes.enumerated() {
                bytes[Int(repair.offset + UInt64(index))] = byte
            }
        }
        return TestUEFI.Built(bytes: bytes, node: built.node, image: built.image)
    }
}
