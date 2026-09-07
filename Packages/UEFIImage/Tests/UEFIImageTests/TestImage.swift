import Foundation
@testable import UEFIImage

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

    /// A Volume Top File whose last forty-eight bytes are the reset vector
    /// (§5.7) — which is where they are in a real image, since the file's last
    /// byte is mapped at `0xFFFFFFFF`.
    static func volumeTopFile(
        size: UInt64 = 0x100,
        peiCoreEntryPoint: UInt32 = 0xFFF8_0000,
        bootFvBaseAddress: UInt32 = 0xFFF0_0000
    ) -> [UInt8] {
        var body = BinaryWriter()
        body.fill(size - FFS.headerSize - ResetVector.size, with: 0xFF)
        body.fill(8, with: 0xEA)                      // ApEntryVector
        body.fill(8, with: 0xFF)                      // Reserved0
        body.u32(peiCoreEntryPoint)
        body.fill(12, with: 0xFF)                     // Reserved1
        body.fill(8, with: 0x90)                      // ResetVector
        body.u32(0xFFFF_0000)                         // ApStartupSegment
        body.u32(bootFvBaseAddress)
        return file(guid: KnownGUIDs.volumeTopFile, body: body.bytes)
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
        trailing: [UInt8] = [],
        lastFile: [UInt8]? = nil
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
        if let lastFile {
            // Flush against the end of the volume, the way a Volume Top File
            // is — with a pad file covering the space in front of it, which is
            // how a real volume reaches one (§5.7).
            let start = length - UInt64(lastFile.count)
            let gap = start - volume.count
            if gap >= FFS.headerSize {
                volume.raw(file(
                    guid: .zero,
                    type: FFS.padType,
                    body: [UInt8](repeating: emptyByte, count: Int(gap - FFS.headerSize))
                ))
            }
            volume.pad(to: start, with: emptyByte)
            volume.raw(lastFile)
        }
        volume.pad(to: length, with: emptyByte)
        return volume.bytes
    }

    /// An Intel microcode image, its dword checksum correct unless a test
    /// breaks it (§7.1).
    static func microcode(
        signature: UInt32 = 0x0003_06A9,
        revision: UInt32 = 0x1F,
        year: UInt16 = 0x2019,
        month: UInt8 = 0x07,
        day: UInt8 = 0x15,
        dataSize: UInt32 = 0x40,
        totalSize: UInt32? = nil,
        headerType: UInt32 = 1,
        loaderRevision: UInt32 = 1,
        checksum: UInt32? = nil
    ) -> [UInt8] {
        let total = totalSize ?? (UInt32(Microcode.headerSize) + dataSize)
        var writer = BinaryWriter()
        writer.u32(headerType)
        writer.u32(revision)
        writer.u16(year)
        writer.u8(day)
        writer.u8(month)
        writer.u32(signature)
        writer.u32(0)                   // checksum, filled in below
        writer.u32(loaderRevision)
        writer.u32(1)                   // PlatformIds
        writer.u32(dataSize)
        writer.u32(total)
        writer.u32(0)                   // MetadataSize
        writer.u32(0)                   // UpdateRevisionMin
        writer.u32(0)                   // Reserved
        var bytes = writer.bytes
        bytes += [UInt8](repeating: 0x5A, count: max(0, Int(total) - bytes.count))

        let sum = Checksums.sum32(of: 0..<UInt64(bytes.count), in: ImageReader(bytes)) ?? 0
        let stored = checksum ?? (0 &- sum)
        for index in 0..<4 { bytes[0x10 + index] = UInt8(truncatingIfNeeded: stored >> (8 * index)) }
        return bytes
    }

    /// An Intel flash descriptor: `0x1000` bytes, the signature at `0x10`, and
    /// a region section at `RegionBase << 4`.
    static func descriptor(
        regions: [(type: FlashRegionType, range: Range<UInt64>)],
        regionBase: UInt32 = 0x04,
        version1: Bool = false
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: Int(Descriptor.size))
        func put(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        func put(_ value: UInt16, at offset: Int) {
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        put(Descriptor.signature, at: 0x10)
        put(regionBase << 16, at: Int(Descriptor.mapOffset))
        put(version1 ? Descriptor.reservedVersion : 0x0020_0000, at: Int(Descriptor.versionOffset))

        let section = Int(regionBase) << 4
        for type in FlashRegionType.allCases {
            let entry = section + type.rawValue * 4
            guard entry + 4 <= bytes.count else { break }
            guard let region = regions.first(where: { $0.type == type }) else {
                put(UInt16(0), at: entry)          // limit zero: the region is absent
                put(UInt16(0), at: entry + 2)
                continue
            }
            put(UInt16(region.range.lowerBound >> 12), at: entry)
            put(UInt16((region.range.upperBound - 1) >> 12), at: entry + 2)
        }
        return bytes
    }

    /// A full flash dump: a descriptor and the contents of the regions it maps.
    static func intelImage(
        size: UInt64,
        regions: [(type: FlashRegionType, range: Range<UInt64>)],
        contents: [FlashRegionType: [UInt8]] = [:],
        version1: Bool = false,
        regionBase: UInt32 = 0x04
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: Int(size))
        let descriptor = self.descriptor(regions: regions, regionBase: regionBase, version1: version1)
        bytes.replaceSubrange(0..<descriptor.count, with: descriptor)
        for (type, content) in contents {
            guard let region = regions.first(where: { $0.type == type }) else { continue }
            let start = Int(region.range.lowerBound)
            bytes.replaceSubrange(start..<(start + content.count), with: content)
        }
        return bytes
    }

    /// A capsule wrapping an image.
    static func capsule(
        guid: EFIGUID = KnownGUIDs.guid("3B6686BD-0D76-4030-B70E-B5519E2FC5A0"),
        headerSize: UInt32 = 0x20,
        imageSize: UInt32? = nil,
        romImageOffset: UInt16? = nil,
        body: [UInt8],
        trailing: UInt64 = 0
    ) -> [UInt8] {
        var writer = BinaryWriter()
        writer.guid(guid)
        writer.u32(headerSize)
        writer.u32(0)                                        // Flags
        writer.u32(imageSize ?? (headerSize + UInt32(body.count)))
        if let romImageOffset {
            writer.u16(romImageOffset)
            writer.u16(0)                                    // RomLayoutOffset
        }
        // A signed capsule's image starts after the certificate, which is what
        // `RomImageOffset` measures — not after the header.
        writer.pad(to: UInt64(romImageOffset ?? UInt16(headerSize)), with: 0xFF)
        writer.raw(body)
        writer.fill(trailing, with: 0xFF)
        return writer.bytes
    }

    /// A volume with nothing before or after it.
    static func image(padding before: UInt64 = 0, _ volume: [UInt8], after: UInt64 = 0) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: Int(before)) + volume
            + [UInt8](repeating: 0xFF, count: Int(after))
    }
}
