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
        mutating func raw(_ bytes: [UInt8]) { self.bytes += bytes }
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

    // MARK: - NVRAM stores and entries

    /// A VSS store's 16-byte header: the `$VSS` signature, size, the format and
    /// state bytes, and the two reserved words (§9).
    static func nvramVssStore(state: UInt8 = 0x01, totalSize: UInt64 = 0x50) -> Built {
        var w = Writer()
        w.u32(0x5353_5624)     // $VSS
        w.u32(UInt32(totalSize))
        w.u8(0x5A)             // format
        w.u8(state)
        w.u16(0)               // reserved
        w.u32(0)               // reserved1
        let node = UEFINode(
            kind: .vssStore,
            name: "VSS store",
            header: 0..<16,
            body: 16..<totalSize,
            isFixed: true
        )
        return Built(bytes: pad(w.bytes, to: totalSize), node: node, image: image(node, totalSize: totalSize))
    }

    /// A VSS2 store's 28-byte header: the store GUID, size, then the same four
    /// fields a VSS store keeps, pushed out past the GUID (§9).
    static func nvramVss2Store(state: UInt8 = 0x01, totalSize: UInt64 = 0x40) -> Built {
        var w = Writer()
        w.fill(16)             // store GUID
        w.u32(UInt32(totalSize))
        w.u8(0x5A)             // format
        w.u8(state)
        w.u16(0)               // reserved
        w.u32(0)               // reserved1
        let node = UEFINode(
            kind: .vss2Store,
            name: "VSS2 store",
            header: 0..<28,
            body: 28..<totalSize,
            isFixed: true
        )
        return Built(bytes: pad(w.bytes, to: totalSize), node: node, image: image(node, totalSize: totalSize))
    }

    /// A standard VSS variable's 32-byte header: the marker, state, reserved,
    /// attributes, the two size words, and the vendor GUID (§9). A VSS and a
    /// VSS2 store lay this out identically.
    static func nvramVssVariable(
        state: UInt8 = 0x7F,
        attributes: UInt32 = 0x0000_0003,
        vendorGuid: EFIGUID = EFIGUID(low: 0x1111_1111, high: 0x2222_2222)
    ) -> Built {
        var w = Writer()
        w.u8(0xAA)
        w.u8(0x55)
        w.u8(state)
        w.u8(0)                // reserved
        w.u32(attributes)
        w.u32(0)               // name size
        w.u32(0)               // data size
        w.guid(vendorGuid)
        let node = UEFINode(
            kind: .vssEntry,
            subtype: UEFITypes.Sub.standardVssEntry,
            name: "BootOrder",
            header: 0..<32,
            body: 32..<32,
            isFixed: true
        )
        return Built(bytes: pad(w.bytes, to: 32), node: node, image: image(node, totalSize: 32))
    }

    /// An FTW working block's 28-byte header: the signature GUID, the header
    /// CRC32, the state, and the 32-bit write-queue size (§9).
    static func nvramFtwStore(crc: UInt32 = 0x1234_5678, state: UInt8 = 0x01) -> Built {
        var w = Writer()
        w.fill(16)             // signature GUID
        w.u32(crc)             // header CRC32, state and CRC blanked when checked
        w.u8(state)
        w.u8(0); w.u8(0); w.u8(0) // reserved
        w.u32(0x14)            // len_write_queue (32-bit, low nibble 4)
        let node = UEFINode(
            kind: .ftwStore,
            name: "FTW store",
            header: 0..<28,
            body: 28..<28,
            isFixed: true
        )
        return Built(bytes: pad(w.bytes, to: 28), node: node, image: image(node, totalSize: 28))
    }

    /// An Apple SysF store: the 11-byte header, zero free space, and the CRC32
    /// over everything before it in the final four bytes (§9).
    static func nvramSysfStore(totalSize: UInt64 = 0x40, crc: UInt32? = nil) -> Built {
        var bytes: [UInt8] = []
        bytes += (0..<4).map { UInt8((0x7379_7346 >> (8 * $0)) & 0xFF) } // Fsys
        bytes.append(0)                                                 // unknown
        bytes += (0..<4).map { UInt8((UInt32(0) >> (8 * $0)) & 0xFF) }  // unknown1
        bytes += [UInt8(totalSize & 0xFF), UInt8((totalSize >> 8) & 0xFF)]
        let crcStart = Int(totalSize) - 4
        while bytes.count < crcStart { bytes.append(0) }
        let crcValue = crc ?? Checksums.crc32(bytes)
        bytes += (0..<4).map { UInt8((crcValue >> (8 * $0)) & 0xFF) }
        let node = UEFINode(
            kind: .sysFStore,
            name: "Apple SysF store",
            header: 0..<11,
            body: 11..<totalSize,
            isFixed: true
        )
        return Built(bytes: bytes, node: node, image: image(node, totalSize: totalSize))
    }

    /// A Phoenix EVSA store's 20-byte header: a store entry whose signature is
    /// `EVSA`, then attributes, the store size and a reserved word. The checksum
    /// makes the header add up to zero past the type byte (§9).
    static func nvramEvsaStore(
        attributes: UInt32 = 0,
        totalSize: UInt64 = 0x30,
        checksum: UInt8? = nil
    ) -> Built {
        var bytes: [UInt8] = [0xEC, 0]   // type, checksum patched below
        bytes += [0x14, 0x00]            // header size, 20
        bytes += (0..<4).map { UInt8((0x4156_5345 >> (8 * $0)) & 0xFF) } // EVSA
        bytes += (0..<4).map { UInt8((attributes >> (8 * $0)) & 0xFF) }
        bytes += (0..<4).map { UInt8((UInt32(totalSize) >> (8 * $0)) & 0xFF) }
        bytes += [0, 0, 0, 0]            // reserved
        bytes[1] = checksum ?? (0 &- Checksums.sum8(bytes[2...]))
        while bytes.count < Int(totalSize) { bytes.append(0xFF) }
        let node = UEFINode(
            kind: .evsaStore,
            name: "Phoenix EVSA store",
            header: 0..<20,
            body: 20..<totalSize,
            isFixed: true
        )
        return Built(bytes: bytes, node: node, image: image(node, totalSize: totalSize))
    }

    /// A Phoenix EVSA data entry: a type byte, a checksum, a size word, the two
    /// id words and an attributes word, then the data. The extended-header bit
    /// inserts a data-size word before the data (§9).
    static func nvramEvsaDataEntry(
        guidId: UInt16 = 1,
        varId: UInt16 = 2,
        attributes: UInt32 = 0x0000_0007,
        data: [UInt8] = [0x01, 0x02],
        checksum: UInt8? = nil
    ) -> Built {
        let extended = attributes & 0x1000_0000 != 0
        var bytes: [UInt8] = [0xEF, 0]   // type, checksum patched below
        let entrySize = UInt16((extended ? 16 : 12) + data.count)
        bytes += [UInt8(entrySize & 0xFF), UInt8((entrySize >> 8) & 0xFF)]
        bytes += [UInt8(guidId & 0xFF), UInt8((guidId >> 8) & 0xFF)]
        bytes += [UInt8(varId & 0xFF), UInt8((varId >> 8) & 0xFF)]
        bytes += (0..<4).map { UInt8((attributes >> (8 * $0)) & 0xFF) }
        if extended {
            bytes += (0..<4).map { UInt8((UInt32(data.count) >> (8 * $0)) & 0xFF) }
        }
        bytes += data
        bytes[1] = checksum ?? (0 &- Checksums.sum8(bytes[2...]))
        let headerSize: UInt64 = extended ? 16 : 12
        let node = UEFINode(
            kind: .evsaEntry,
            subtype: UEFITypes.Sub.dataEvsaEntry,
            name: "Lang",
            header: 0..<headerSize,
            body: headerSize..<UInt64(bytes.count),
            isFixed: true
        )
        return Built(bytes: bytes, node: node, image: image(node, totalSize: UInt64(bytes.count)))
    }

    /// A Microsoft SLIC marker, whole: the type and size, the version, the OEM
    /// id and table id, the windows flag, the SLIC version, and the signature.
    static func nvramSlicMarker() -> Built {
        var bytes: [UInt8] = []
        bytes += (0..<4).map { UInt8((UInt32(1) >> (8 * $0)) & 0xFF) }  // type
        bytes += (0..<4).map { UInt8((UInt32(0xB6) >> (8 * $0)) & 0xFF) } // size
        bytes += (0..<4).map { UInt8((UInt32(1) >> (8 * $0)) & 0xFF) }  // version
        bytes += Array("TESTCO".utf8)                                   // OEM id
        bytes += Array("TABLID01".utf8)                                 // OEM table id
        bytes += (0..<8).map { UInt8((UInt64(0x2053_574F_444E_4957) >> (8 * $0)) & 0xFF) } // windows flag
        bytes += (0..<4).map { UInt8((UInt32(1) >> (8 * $0)) & 0xFF) }  // SLIC version
        bytes += [UInt8](repeating: 0, count: 16)                       // reserved
        bytes += [UInt8](repeating: 0xEE, count: 128)                   // signature
        let node = UEFINode(
            kind: .slicData,
            subtype: UEFITypes.Sub.markerSlicData,
            name: "SLIC marker",
            header: 0..<UInt64(bytes.count),
            body: UInt64(bytes.count)..<UInt64(bytes.count),
            isFixed: true
        )
        return Built(bytes: bytes, node: node, image: image(node, totalSize: UInt64(bytes.count)))
    }

    /// A Phoenix flash map's 16-byte header: the `_FLASH_MAP` signature, the
    /// entry count and a reserved word (§9).
    static func nvramFlashMapStore(numEntries: UInt16 = 1) -> Built {
        var w = Writer()
        w.raw(Array("_FLASH_MAP".utf8))
        w.u16(numEntries)
        w.u32(0)               // reserved
        let node = UEFINode(
            kind: .flashMapStore,
            name: "Phoenix SCT flash map",
            header: 0..<16,
            body: 16..<16,
            isFixed: true
        )
        return Built(bytes: w.bytes, node: node, image: image(node, totalSize: 16))
    }

    /// A Phoenix flash map entry: the region GUID, its data and entry types,
    /// its physical address, size and offset — one fixed 36-byte record.
    static func nvramFlashMapEntry(
        guid: EFIGUID = EFIGUID(low: 0x1111_1111, high: 0x2222_2222),
        dataType: UInt16 = 0,
        entryType: UInt16 = 0,
        address: UInt64 = 0xFFF0_0000,
        size: UInt32 = 0x1000,
        offset: UInt32 = 0x40
    ) -> Built {
        var w = Writer()
        w.guid(guid)
        w.u16(dataType)
        w.u16(entryType)
        w.u64(address)
        w.u32(size)
        w.u32(offset)
        let node = UEFINode(
            kind: .flashMapEntry,
            subtype: UEFITypes.Sub.volumeFlashMapEntry,
            name: guid.description,
            guid: guid,
            header: 0..<36,
            body: 36..<36,
            isFixed: true
        )
        return Built(bytes: w.bytes, node: node, image: image(node, totalSize: 36))
    }
}
