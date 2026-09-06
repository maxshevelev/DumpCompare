import Foundation
@testable import UEFIFormat

/// Images built by hand, byte for byte.
///
/// A parser is only as trustworthy as the images it has been shown, and the
/// interesting ones are the broken ones: a stale checksum, a size of zero, a
/// block map that disagrees with the header. Those cannot be found — they have
/// to be built. So every fixture here is assembled in code with each field
/// spelled out, and every way of breaking one is a parameter.
///
/// No real dump is ever committed to this repository, which this also settles.
struct BinaryWriter {
    private(set) var bytes: [UInt8] = []

    var count: UInt64 { UInt64(bytes.count) }

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes += [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }

    mutating func u24(_ value: UInt32) {
        bytes += (0..<3).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    mutating func u32(_ value: UInt32) {
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    mutating func u64(_ value: UInt64) {
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    mutating func guid(_ value: EFIGUID) { bytes += value.bytes }

    mutating func raw(_ value: [UInt8]) { bytes += value }

    mutating func fill(_ count: UInt64, with byte: UInt8) {
        bytes += [UInt8](repeating: byte, count: Int(count))
    }

    mutating func pad(to size: UInt64, with byte: UInt8) {
        if count < size { fill(size - count, with: byte) }
    }
}

enum TestImage {
    static let driverGUID = KnownGUIDs.guid("11111111-2222-3333-4444-555555555555")

    /// An FFS file, checksums correct unless a test asks otherwise. Raw by
    /// default, because a raw file's body is the bytes it says it is — every
    /// other type's body is read as sections, which is a different test.
    static func file(
        guid: EFIGUID = driverGUID,
        type: UInt8 = FFS.rawType,
        attributes: UInt8 = 0,
        state: UInt8 = 0xF8,
        body: [UInt8],
        volumeRevision: UInt8 = 2,
        size: UInt32? = nil,
        headerChecksum: UInt8? = nil,
        bodyChecksum: UInt8? = nil
    ) -> [UInt8] {
        let total = UInt32(FFS.headerSize) + UInt32(body.count)
        let bodySum: UInt8 = attributes & FFS.checksumBit != 0
            ? 0 &- Checksums.sum8(body)
            : (volumeRevision == 1 ? FFS.fixedChecksum : FFS.fixedChecksum2)

        var header = BinaryWriter()
        header.guid(guid)
        header.u8(0)                       // header checksum, filled in below
        header.u8(bodyChecksum ?? bodySum)
        header.u8(type)
        header.u8(attributes)
        header.u24(size ?? total)
        header.u8(state)

        // The header sum leaves out both checksum bytes and the state byte, so
        // computing it with a zero in place of the first one is exact.
        var bytes = header.bytes
        let sum = Checksums.sum8(bytes) &- bytes[0x10] &- bytes[0x11] &- bytes[0x17]
        bytes[0x10] = headerChecksum ?? (0 &- sum)
        return bytes + body
    }

    /// An FFSv3 large file: the size lives in a 64-bit field after the base
    /// header, and the header is eight bytes longer for it (§5.2).
    static func largeFile(
        guid: EFIGUID = driverGUID,
        type: UInt8 = 0x07,
        body: [UInt8]
    ) -> [UInt8] {
        let total = FFS.largeHeaderSize + UInt64(body.count)
        var header = BinaryWriter()
        header.guid(guid)
        header.u8(0)                       // header checksum, filled in below
        header.u8(FFS.fixedChecksum2)
        header.u8(type)
        header.u8(FFS.largeFile)
        header.u24(0)
        header.u8(0xF8)                    // state
        header.u64(total)

        var bytes = header.bytes
        let sum = Checksums.sum8(bytes) &- bytes[0x10] &- bytes[0x11] &- bytes[0x17]
        bytes[0x10] = 0 &- sum
        return bytes + body
    }

    /// A section: a three-byte size, a type, whatever the type puts in front
    /// of the body, and the body.
    static func section(
        type: UInt8,
        body: [UInt8],
        extra: [UInt8] = [],
        size: UInt32? = nil,
        extendedSize: Bool = false
    ) -> [UInt8] {
        var writer = BinaryWriter()
        let total = UInt32(4 + (extendedSize ? 4 : 0) + extra.count + body.count)
        if extendedSize {
            writer.u24(Section.extendedSizeMarker)
            writer.u8(type)
            writer.u32(size ?? total)
        } else {
            writer.u24(size ?? total)
            writer.u8(type)
        }
        writer.raw(extra)
        writer.raw(body)
        return writer.bytes
    }

    /// A compression section, whose header says how big the body gets and how
    /// it was squeezed (§6.2).
    static func compressionSection(algorithm: UInt8, body: [UInt8]) -> [UInt8] {
        var extra = BinaryWriter()
        extra.u32(UInt32(body.count) * 3)
        extra.u8(algorithm)
        return section(type: Section.compression, body: body, extra: extra.bytes)
    }

    /// A GUID-defined section. `dataOffset` is from the start of the section,
    /// so a vendor header between the structure and the data just moves it
    /// along (§6.3).
    static func guidedSection(
        guid: EFIGUID,
        body: [UInt8],
        vendorHeader: [UInt8] = []
    ) -> [UInt8] {
        var extra = BinaryWriter()
        extra.guid(guid)
        extra.u16(UInt16(4 + Section.guidDefinedHeaderSize) + UInt16(vendorHeader.count))
        extra.u16(0)                                  // Attributes
        extra.raw(vendorHeader)
        return section(type: Section.guidDefined, body: body, extra: extra.bytes)
    }

    /// A name section: UCS-2 with a terminating zero.
    static func nameSection(_ text: String) -> [UInt8] {
        var writer = BinaryWriter()
        for unit in Array(text.utf16) { writer.u16(unit) }
        writer.u16(0)
        return section(type: Section.userInterface, body: writer.bytes)
    }

    /// A file whose body is a run of sections, four-byte aligned.
    static func sectionedFile(
        guid: EFIGUID = driverGUID,
        type: UInt8 = 0x07,
        sections: [[UInt8]]
    ) -> [UInt8] {
        var body = BinaryWriter()
        for section in sections {
            body.pad(to: alignUp(body.count, to: 4)!, with: 0xFF)
            body.raw(section)
        }
        return file(guid: guid, type: type, body: body.bytes)
    }

    /// A volume, its files laid out eight-byte aligned, the rest erased.
    static func volume(
        fileSystem: EFIGUID = KnownGUIDs.ffsV2,
        revision: UInt8 = 2,
        length: UInt64 = 0x400,
        files: [[UInt8]] = [],
        emptyByte: UInt8 = 0xFF,
        blockMapLength: UInt64? = nil,
        checksum: UInt16? = nil,
        extendedHeader: EFIGUID? = nil,
        trailing: [UInt8] = []
    ) -> [UInt8] {
        // The extended header goes straight after the block map, and the base
        // header's length does not grow to cover it (§3.2).
        let extHeaderOffset: UInt16 = extendedHeader == nil ? 0 : 0x48
        var header = BinaryWriter()
        header.fill(16, with: 0)                          // ZeroVector
        header.guid(fileSystem)
        header.u64(length)
        header.u32(FV.signature)
        header.u32(emptyByte == 0xFF ? FV.erasePolarity : 0)
        header.u16(0x48)                                  // HeaderLength
        header.u16(0)                                     // Checksum, filled in below
        header.u16(extHeaderOffset)
        header.u8(0)                                      // Reserved
        header.u8(revision)
        header.u32(1)                                     // BlockMap: NumBlocks
        header.u32(UInt32(blockMapLength ?? length))      //           Length
        header.u32(0)
        header.u32(0)

        var bytes = header.bytes
        let computed = Checksums.checksum16(bytes) ?? 0
        let stored = checksum ?? computed
        bytes[FV.checksumOffset] = UInt8(truncatingIfNeeded: stored)
        bytes[FV.checksumOffset + 1] = UInt8(truncatingIfNeeded: stored >> 8)

        var volume = BinaryWriter()
        volume.raw(bytes)
        if let extendedHeader {
            volume.guid(extendedHeader)
            volume.u32(0x14)                              // ExtHeaderSize
        }
        for file in files {
            volume.pad(to: alignUp(volume.count, to: 8)!, with: emptyByte)
            volume.raw(file)
        }
        volume.raw(trailing)
        volume.pad(to: length, with: emptyByte)
        return volume.bytes
    }

    /// A volume with nothing before or after it.
    static func image(padding before: UInt64 = 0, _ volume: [UInt8], after: UInt64 = 0) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: Int(before)) + volume
            + [UInt8](repeating: 0xFF, count: Int(after))
    }
}
