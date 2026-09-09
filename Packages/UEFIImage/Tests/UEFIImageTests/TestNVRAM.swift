import Foundation
@testable import UEFIImage

/// NVRAM store images, built byte for byte on top of `TestImage`.
///
/// A VSS store is a 16-byte header followed by a run of variables, each a
/// header, a UCS-2 name, and a data blob. The interesting images are the
/// broken ones — a deleted variable, a size that overruns — so every field is
/// a parameter.
enum TestNVRAM {
    /// The NVRAM main store volume GUID.
    static let nvramVolumeGUID = NvramGuids.nvramMainStoreVolumeGuid

    /// A UCS-2 string with a terminating zero, the way a variable name is
    /// stored in a VSS store.
    static func ucs2(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for unit in Array(text.utf16) {
            bytes.append(UInt8(truncatingIfNeeded: unit))
            bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        bytes += [0, 0]
        return bytes
    }

    /// A standard VSS variable: the 0x55AA marker, state, attributes, the name
    /// and data sizes, the vendor GUID, the name, and the data.
    static func vssVariable(
        name: String,
        data: [UInt8] = [0x01, 0x02],
        vendorGuid: EFIGUID = TestImage.driverGUID,
        state: UInt8 = NVRAM.vssVariableValid,
        attributes: UInt32 = 0x0000_0003
    ) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u8(NVRAM.variableMarkerFirst)   // 0xAA
        writer.u8(NVRAM.variableMarkerLast)    // 0x55
        writer.u8(state)
        writer.u8(0)                           // reserved
        writer.u32(attributes)
        let nameBytes = ucs2(name)
        writer.u32(UInt32(nameBytes.count))    // NameSize
        writer.u32(UInt32(data.count))         // DataSize
        writer.guid(vendorGuid)
        writer.raw(nameBytes)
        writer.raw(data)
        return writer.bytes
    }

    /// An authenticated VSS variable: a 60-byte header. Where a standard header
    /// keeps the name and data sizes and the vendor GUID at offsets 8, 12 and
    /// 16, an authenticated one puts the two halves of a monotonic counter, a
    /// timestamp and a key index before the sizes — so the real name and data
    /// sizes sit at offsets 36 and 40, and the vendor GUID moves down the header
    /// to its last sixteen bytes, offset 44, just before the name at 60.
    static func authVssVariable(
        name: String,
        data: [UInt8] = [0x01, 0x02],
        vendorGuid: EFIGUID = TestImage.driverGUID,
        state: UInt8 = NVRAM.vssVariableAdded,
        attributes: UInt32 = NVRAM.vssAttributeTimeBasedAuth | 0x0000_0007
    ) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u8(NVRAM.variableMarkerFirst)   // 0xAA
        writer.u8(NVRAM.variableMarkerLast)    // 0x55
        writer.u8(state)
        writer.u8(0)                           // reserved
        writer.u32(attributes)
        let nameBytes = ucs2(name)
        writer.u32(0)                          // monotonic counter, low
        writer.u32(0)                          // monotonic counter, high
        writer.fill(16, with: 0)               // timestamp
        writer.u32(0)                          // key index
        writer.u32(UInt32(nameBytes.count))    // name size, at offset 36
        writer.u32(UInt32(data.count))         // data size, at offset 40
        writer.guid(vendorGuid)                // vendor GUID, at offset 44
        writer.raw(nameBytes)
        writer.raw(data)
        return writer.bytes
    }

    /// A VSS store: the 16-byte header, the variables back to back, and erased
    /// free space after them. `size` defaults to the real size of the store.
    static func vssStore(
        variables: [[UInt8]] = [],
        signature: UInt32 = NVRAM.vssSignature,
        state: UInt8 = 0x01,
        size: UInt32? = nil,
        freeSpace: UInt64 = 0x10
    ) -> [UInt8] {
        var body = BinaryWriter()
        for variable in variables {
            body.raw(variable)
        }
        body.fill(freeSpace, with: 0xFF)
        let storeSize = size ?? UInt32(NVRAM.vssStoreHeaderSize + UInt64(body.count))
        var header = BinaryWriter()
        header.u32(signature)
        header.u32(storeSize)
        header.u8(NVRAM.vssFormatted)   // format
        header.u8(state)
        header.u16(0)                   // reserved
        header.u32(0)                   // reserved1
        return header.bytes + body.bytes
    }

    /// An NVRAM volume: an FV header with the NVRAM file-system GUID, whose
    /// body is the given stores laid out back to back.
    static func nvramVolume(
        stores: [[UInt8]] = [],
        emptyByte: UInt8 = 0xFF,
        length: UInt64? = nil
    ) -> [UInt8] {
        var body = BinaryWriter()
        for store in stores {
            body.raw(store)
        }
        let totalLength = length ?? (0x48 + UInt64(body.count))
        return TestImage.volume(
            fileSystem: nvramVolumeGUID,
            length: totalLength,
            files: [],
            emptyByte: emptyByte,
            trailing: body.bytes
        )
    }

    /// A standard VSS2 variable: the 0xAA55 marker, state, attributes, the name
    /// and data sizes, the vendor GUID, the name, and the data.
    static func vss2Variable(
        name: String,
        data: [UInt8] = [0x01, 0x02],
        vendorGuid: EFIGUID = TestImage.driverGUID,
        state: UInt8 = NVRAM.vssVariableValid,
        attributes: UInt32 = 0x0000_0003
    ) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u8(NVRAM.variableMarkerFirst)   // 0xAA
        writer.u8(NVRAM.variableMarkerLast)    // 0x55
        writer.u8(state)
        writer.u8(0)                           // reserved
        writer.u32(attributes)
        let nameBytes = ucs2(name)
        writer.u32(UInt32(nameBytes.count))    // len_name
        writer.u32(UInt32(data.count))         // len_data
        writer.guid(vendorGuid)
        writer.raw(nameBytes)
        writer.raw(data)
        return writer.bytes
    }

    /// A VSS2 store: the 28-byte header led by the store GUID, the variables
    /// back to back with 4-byte alignment padding, and erased free space after
    /// them. `size` defaults to the real size of the store.
    static func vss2Store(
        variables: [[UInt8]] = [],
        signature: EFIGUID = NvramGuids.nvramVss2StoreGuid,
        state: UInt8 = 0x01,
        size: UInt32? = nil,
        freeSpace: UInt64 = 0x10
    ) -> [UInt8] {
        var body = BinaryWriter()
        for variable in variables {
            body.raw(variable)
            // 4-byte alignment padding after each variable, from its own start.
            let used = variable.count
            let aligned = ((used + 3) / 4) * 4
            if aligned > used {
                body.fill(UInt64(aligned - used), with: 0xFF)
            }
        }
        body.fill(freeSpace, with: 0xFF)
        let storeSize = size ?? UInt32(NVRAM.vss2StoreHeaderSize + UInt64(body.count))
        var header = BinaryWriter()
        header.guid(signature)
        header.u32(storeSize)
        header.u8(NVRAM.vssFormatted)   // format
        header.u8(state)
        header.u16(0)                   // reserved
        header.u32(0)                   // reserved1
        return header.bytes + body.bytes
    }

    /// An FTW working block: the 28-byte header led by the signature GUID, with
    /// a header CRC32 over itself (CRC and state blanked to the erase byte), and
    /// an opaque write queue after it. `crc` overrides the stored CRC to break
    /// the check.
    static func ftwStore(
        signature: EFIGUID = NvramGuids.edkiiWorkingBlockSignatureGuid,
        state: UInt8 = 0x01,
        writeQueue: [UInt8] = [],
        emptyByte: UInt8 = 0xFF,
        crc: UInt32? = nil
    ) -> [UInt8] {
        // The write queue size's low nibble must be 4 for a 32-bit queue.
        var queue = writeQueue
        while queue.count % 0x10 != 4 {
            queue.append(emptyByte)
        }

        var header = BinaryWriter()
        header.guid(signature)
        header.u32(0)                              // crc placeholder
        header.u8(state)
        header.u8(0); header.u8(0); header.u8(0)   // reserved
        header.u32(UInt32(queue.count))            // len_write_queue_32

        // The header CRC32 is over the header with the CRC and state fields
        // blanked to the erase value.
        var headerBytes = header.bytes
        headerBytes[16] = emptyByte; headerBytes[17] = emptyByte
        headerBytes[18] = emptyByte; headerBytes[19] = emptyByte
        headerBytes[20] = emptyByte
        let finalCrc = crc ?? Checksums.crc32(headerBytes)
        headerBytes[16] = UInt8(truncatingIfNeeded: finalCrc)
        headerBytes[17] = UInt8(truncatingIfNeeded: finalCrc >> 8)
        headerBytes[18] = UInt8(truncatingIfNeeded: finalCrc >> 16)
        headerBytes[19] = UInt8(truncatingIfNeeded: finalCrc >> 24)

        return headerBytes + queue
    }

    /// An Insyde FDC store: `_FDC`, a size, a volume header and two block map
    /// entries (0x50 bytes of header), then the store body the reference parser
    /// reads as an NVRAM volume body of its own. `stores` are laid out back to
    /// back in that body. `size` defaults to the real size of the store.
    static func fdcStore(
        stores: [[UInt8]] = [],
        signature: UInt32 = NVRAM.insydeFdcSignature,
        size: UInt32? = nil,
        freeSpace: UInt64 = 0x10
    ) -> [UInt8] {
        var body = BinaryWriter()
        for store in stores {
            body.raw(store)
        }
        body.fill(freeSpace, with: 0xFF)
        let storeSize = size ?? UInt32(NVRAM.fdcStoreHeaderSize + UInt64(body.count))
        var header = BinaryWriter()
        header.u32(signature)
        header.u32(storeSize)
        header.fill(NVRAM.fdcStoreHeaderSize - 8, with: 0xFF)
        return header.bytes + body.bytes
    }

    // MARK: - Apple SysF / Diag

    /// A SysF variable: a name-length byte (the length in its low seven bits,
    /// the invalid flag on top), the ASCII name, a data length and the data.
    static func sysfVariable(
        name: String,
        data: [UInt8] = [],
        invalid: Bool = false
    ) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        let flags = UInt8(nameBytes.count) | (invalid ? NVRAM.sysfInvalidFlag : 0)
        var writer = BinaryWriter()
        writer.u8(flags)
        writer.raw(nameBytes)
        writer.u16(UInt16(data.count))
        writer.raw(data)
        return writer.bytes
    }

    /// The chunk that ends a SysF store: a name-length byte, `EOF`, and no
    /// data after it. The parser reads nothing past an EOF chunk.
    static func sysfEofChunk() -> [UInt8] {
        [3] + Array("EOF".utf8)
    }

    /// An Apple SysF/Diag store: the 11-byte header (signature, an unknown byte
    /// and word, and the 16-bit size), the variables, an EOF chunk, zero free
    /// space, and the CRC32 in the last four bytes. `size` defaults to the real
    /// size of the store; a larger one makes a store that overruns its body.
    static func sysfStore(
        variables: [[UInt8]] = [],
        signature: UInt32 = NVRAM.appleSysfSignature,
        size: UInt16? = nil,
        freeSpace: UInt64 = 0x10
    ) -> [UInt8] {
        var content = BinaryWriter()
        for variable in variables {
            content.raw(variable)
        }
        content.raw(sysfEofChunk())
        content.fill(freeSpace, with: 0x00)
        let storeSize = size ?? UInt16(NVRAM.sysfStoreHeaderSize + UInt64(content.count) + NVRAM.sysfStoreCrcSize)
        var header = BinaryWriter()
        header.u32(signature)
        header.u8(0)                          // unknown
        header.u32(0)                         // unknown1
        header.u16(storeSize)
        var writer = BinaryWriter()
        writer.raw(header.bytes + content.bytes)
        writer.u32(Checksums.crc32(writer.bytes)) // CRC32 over the store itself
        return writer.bytes
    }

    // MARK: - Phoenix SCT flash map

    /// A Phoenix SCT flash map entry: a region GUID, its data and entry types,
    /// physical address, size and offset — one fixed 36-byte record.
    static func flashMapEntry(
        guid: EFIGUID,
        dataType: UInt16,
        entryType: UInt16 = 0,
        address: UInt64 = 0,
        size: UInt32 = 0,
        offset: UInt32 = 0
    ) -> [UInt8] {
        var writer = BinaryWriter()
        writer.guid(guid)
        writer.u16(dataType)
        writer.u16(entryType)
        writer.u64(address)
        writer.u32(size)
        writer.u32(offset)
        return writer.bytes
    }

    /// A Phoenix SCT flash map: the 16-byte header and one 36-byte entry per
    /// region. `entryCount` overrides the count implied by the entries, to make
    /// a map that overruns its body.
    static func flashMapStore(
        entries: [[UInt8]] = [],
        entryCount: UInt16? = nil
    ) -> [UInt8] {
        var writer = BinaryWriter()
        writer.raw(NVRAM.phoenixFlashMapSignature) // _FLASH_MAP
        writer.u16(entryCount ?? UInt16(entries.count))
        writer.u32(0)                              // reserved
        for entry in entries {
            writer.raw(entry)
        }
        return writer.bytes
    }

    // MARK: - Phoenix EVSA

    /// A Phoenix EVSA GUID entry: a type byte, a checksum, a size word, an id
    /// word and the 16-byte GUID the id names.
    static func evsaGuidEntry(
        guid: EFIGUID,
        id: UInt16,
        type: UInt8 = NVRAM.evsaEntryTypeGuid1
    ) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u8(type)
        writer.u8(0)                   // checksum
        writer.u16(22)
        writer.u16(id)
        writer.guid(guid)
        return writer.bytes
    }

    /// A Phoenix EVSA name entry: a type byte, a checksum, a size word, an id
    /// word and the UCS-2 name the id gives a variable.
    static func evsaNameEntry(
        name: String,
        id: UInt16,
        type: UInt8 = NVRAM.evsaEntryTypeName1
    ) -> [UInt8] {
        let nameBytes = ucs2(name)
        var writer = BinaryWriter()
        writer.u8(type)
        writer.u8(0)                   // checksum
        writer.u16(UInt16(6 + nameBytes.count))
        writer.u16(id)
        writer.raw(nameBytes)
        return writer.bytes
    }

    /// A Phoenix EVSA data entry: a type byte, a checksum, a size word, the
    /// GuidId and VarId words, an attributes word and the data. `attributes`
    /// may set the extended-header bit, which inserts a data-size word before
    /// the data.
    static func evsaDataEntry(
        type: UInt8 = NVRAM.evsaEntryTypeData1,
        guidId: UInt16,
        varId: UInt16,
        data: [UInt8],
        attributes: UInt32 = 0x0000_0007
    ) -> [UInt8] {
        let extended = attributes & NVRAM.evsaExtendedHeaderBit != 0
        var writer = BinaryWriter()
        writer.u8(type)
        writer.u8(0)                   // checksum
        writer.u16(extended ? UInt16(16 + data.count) : UInt16(12 + data.count))
        writer.u16(guidId)
        writer.u16(varId)
        writer.u32(attributes)
        if extended {
            writer.u32(UInt32(data.count))
        }
        writer.raw(data)
        return writer.bytes
    }

    /// A Phoenix EVSA store: the 20-byte header (an entry of type 0xEC whose
    /// signature is `EVSA`), the entries back to back, and erased free space
    /// after them. `size` defaults to the real size of the store; a larger one
    /// makes a store that overruns its body.
    static func evsaStore(
        entries: [[UInt8]] = [],
        signature: UInt32 = NVRAM.evsaSignature,
        freeSpace: UInt64 = 0x10,
        size: UInt32? = nil
    ) -> [UInt8] {
        var body = BinaryWriter()
        for entry in entries {
            body.raw(entry)
        }
        body.fill(freeSpace, with: 0xFF)
        let storeSize = size ?? UInt32(NVRAM.evsaStoreHeaderSize + UInt64(body.count))
        var header = BinaryWriter()
        header.u8(NVRAM.evsaEntryTypeStore)          // 0xEC
        header.u8(0)                                 // checksum
        header.u16(UInt16(NVRAM.evsaStoreHeaderSize))
        header.u32(signature)
        header.u32(0)                                // attributes
        header.u32(storeSize)
        header.u32(0)                                // reserved
        return header.bytes + body.bytes
    }

    // MARK: - Phoenix CMDB, SLIC

    /// A Phoenix CMDB store: a 0x100-byte region led by the signature and the
    /// two sizes.
    static func cmdbStore(totalSize: UInt32 = 0x10) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u32(NVRAM.cmdbSignature)
        writer.u32(0x10)              // header size
        writer.u32(totalSize)
        writer.fill(NVRAM.cmdbStoreSize - 12, with: 0xFF)
        return writer.bytes
    }

    /// A Microsoft SLIC public key: a fixed 0x9C-byte activation record.
    static func slicPubkey() -> [UInt8] {
        var writer = BinaryWriter()
        writer.u32(NVRAM.slicPubkeyType)
        writer.u32(UInt32(NVRAM.slicPubkeySize))
        writer.u8(0x01)               // key type
        writer.u8(0x01)               // version
        writer.u16(0)                 // reserved
        writer.u32(0x01)              // algorithm
        writer.u32(NVRAM.slicPubkeyMagic) // RSA1
        writer.u32(0x400)             // bit length
        writer.u32(0x10001)           // exponent
        writer.fill(128, with: 0xCD)  // modulus
        return writer.bytes
    }

    /// A Microsoft SLIC marker: a fixed 0xB6-byte activation record.
    static func slicMarker() -> [UInt8] {
        var writer = BinaryWriter()
        writer.u32(NVRAM.slicMarkerType)
        writer.u32(UInt32(NVRAM.slicMarkerSize))
        writer.u32(0x01)              // version
        writer.raw(Array("TESTCO".utf8))      // OEM id
        writer.raw(Array("TABLID01".utf8))    // OEM table id
        writer.u64(NVRAM.slicMarkerWindowsFlag)
        writer.u32(0x01)              // SLIC version
        writer.fill(16, with: 0)      // reserved
        writer.fill(128, with: 0xEE)  // signature
        return writer.bytes
    }
}
