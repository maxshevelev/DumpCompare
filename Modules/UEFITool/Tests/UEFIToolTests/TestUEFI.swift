import Foundation
import UEFIImage

/// The small UEFI structures the pure target is tested against.
///
/// Each builder lays a header out at the start of a fresh buffer and hands back
/// the bytes, the node that points at them, and the image to read through — so
/// a test reads a field back the same way the panel does and checks the words.
enum TestUEFI {
    struct Built {
        let bytes: [UInt8]
        let node: UEFINode
        let image: UEFIImage
        var reader: ImageReader { ImageReader(bytes) }
    }

    // A little-endian byte writer, the mirror of the reader the parser uses.
    private struct Writer {
        private(set) var bytes: [UInt8] = []
        mutating func u8(_ v: UInt8) { bytes.append(v) }
        mutating func u16(_ v: UInt16) { bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        mutating func u24(_ v: UInt32) {
            bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)]
        }
        mutating func u32(_ v: UInt32) { bytes += (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        mutating func u64(_ v: UInt64) { bytes += (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        mutating func guid(_ g: EFIGUID) { bytes += g.bytes }
        mutating func fill(_ count: Int, _ value: UInt8 = 0) {
            bytes += [UInt8](repeating: value, count: count)
        }
    }

    private static func pad(_ bytes: [UInt8], to count: UInt64) -> [UInt8] {
        guard bytes.count < Int(count) else { return bytes }
        return bytes + [UInt8](repeating: 0, count: Int(count) - bytes.count)
    }

    private static func image(
        _ node: UEFINode,
        totalSize: UInt64,
        addressDiff: UInt64? = 0xFFFF_0000
    ) -> UEFIImage {
        UEFIImage(size: totalSize, roots: [node], addressDiff: addressDiff)
    }

    /// A volume header: the file system GUID, the length, the signature, and
    /// the attributes that carry the erase polarity (§3).
    static func volume(
        revision: UInt8 = 2,
        length: UInt64 = 0x1000,
        signature: UInt32 = 0x5654_4152,
        attributes: UInt32 = 0x0000_0800,
        headerLength: UInt16 = 0x38,
        checksum: UInt16 = 0x1234,
        extOffset: UInt16 = 0,
        guid: EFIGUID = KnownGUIDs.ffsV2,
        name: String = "FFSv2",
        totalSize: UInt64 = 0x1000
    ) -> Built {
        var w = Writer()
        w.fill(0x10)
        w.guid(guid)
        w.u64(length)
        w.u32(signature)
        w.u32(attributes)
        w.u16(headerLength)
        w.u16(checksum)
        w.u16(extOffset)
        w.fill(1)
        w.u8(revision)
        let node = UEFINode(
            id: .root.child(0),
            kind: .volume,
            subtype: revision,
            name: name,
            guid: guid,
            header: 0..<0x38,
            body: 0x38..<totalSize
        )
        return Built(bytes: pad(w.bytes, to: totalSize), node: node, image: image(node, totalSize: totalSize))
    }

    /// An FFS file header: the name GUID, the two checksums, the type, the
    /// attributes, the size and the state (§5).
    static func file(
        type: UInt8 = 0x07,
        attributes: UInt8 = 0x04,
        size: UInt32 = 0x100,
        state: UInt8 = 0x80,
        headerChecksum: UInt8 = 0xAA,
        bodyChecksum: UInt8 = 0xBB,
        guid: EFIGUID = KnownGUIDs.volumeTopFile,
        name: String = "Volume Top File",
        totalSize: UInt64 = 0x100
    ) -> Built {
        var w = Writer()
        w.guid(guid)
        w.u8(headerChecksum)
        w.u8(bodyChecksum)
        w.u8(type)
        w.u8(attributes)
        w.u24(size)
        w.u8(state)
        let node = UEFINode(
            id: .root.child(0),
            kind: .file,
            subtype: type,
            name: name,
            guid: guid,
            header: 0..<0x18,
            body: 0x18..<totalSize
        )
        return Built(bytes: pad(w.bytes, to: totalSize), node: node, image: image(node, totalSize: totalSize))
    }

    /// A section header: the size and the type. A size of the extended marker
    /// keeps the real one in 32 bits just after (§6).
    static func section(
        type: UInt8 = 0x19,
        size: UInt32 = 0x40,
        name: String = "",
        totalSize: UInt64 = 0x40
    ) -> Built {
        var w = Writer()
        if size == 0xFF_FFFF {
            w.u24(0xFF_FFFF)
            w.u8(type)
            w.u32(0x10_0000)
        } else {
            w.u24(size)
            w.u8(type)
        }
        let headerSize: UInt64 = size == 0xFF_FFFF ? 8 : 4
        let node = UEFINode(
            id: .root.child(0),
            kind: .section,
            subtype: type,
            name: name,
            header: 0..<headerSize,
            body: headerSize..<totalSize
        )
        return Built(bytes: pad(w.bytes, to: totalSize), node: node, image: image(node, totalSize: totalSize))
    }

    /// A valid Intel microcode header, the shape §7.1 checks for. The checksum
    /// is left at zero because the reader validates the rest, not the sum.
    static func microcode(
        revision: UInt32 = 0xF0,
        signature: UInt32 = 0x0008_06EA,
        platformIDs: UInt32 = 1,
        dataSize: UInt32 = 0x40,
        totalSize: UInt32 = 0x100
    ) -> Built {
        var w = Writer()
        w.u32(1)            // HeaderType
        w.u32(revision)     // UpdateRevision
        w.u16(0x2019)       // DateYear, BCD
        w.u8(0x15)          // DateDay, BCD
        w.u8(0x07)          // DateMonth, BCD
        w.u32(signature)    // ProcessorSignature
        w.u32(0)            // Checksum
        w.u32(1)            // LoaderRevision
        w.u32(platformIDs)
        w.u32(dataSize)
        w.u32(totalSize)
        w.fill(0x20)        // the rest of the 0x30 header
        let node = UEFINode(
            id: .root.child(0),
            kind: .microcode,
            name: "",
            header: 0..<0x30,
            body: 0x30..<UInt64(totalSize)
        )
        let size = UInt64(totalSize)
        return Built(bytes: pad(w.bytes, to: size), node: node, image: image(node, totalSize: size))
    }

    /// Space that belongs to no structure: no header, nothing to read back.
    static func padding(totalSize: UInt64 = 0x100) -> Built {
        let node = UEFINode(kind: .padding, name: "", range: 0..<totalSize)
        return Built(
            bytes: [UInt8](repeating: 0xFF, count: Int(totalSize)),
            node: node,
            image: image(node, totalSize: totalSize)
        )
    }
}
