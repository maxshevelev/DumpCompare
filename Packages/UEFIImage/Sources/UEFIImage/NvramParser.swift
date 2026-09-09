import Foundation

/// The NVRAM volume body: a run of stores, each recognisable by a signature
/// that is not a byte the tree can read back (§9).
///
/// The reference parser walks the body byte by byte, trying the store
/// recognisers in a fixed order — first match wins — and calls everything in
/// between padding. The order matters: VSS before VSS2, because a GUID whose
/// first dword happens to read `$VSS` would otherwise misroute.
enum NVRAM {
    // VSS store signatures.
    static let vssSignature: UInt32 = 0x5353_5624      // $VSS
    static let appleSvsSignature: UInt32 = 0x5356_5324 // $SVS
    static let appleNssSignature: UInt32 = 0x5353_4E24 // $NSS
    /// The only store format the parser reads.
    static let vssFormatted: UInt8 = 0x5a
    /// The store header, signature through reserved1.
    static let vssStoreHeaderSize: UInt64 = 16
    /// A variable opens with the two-byte marker 0x55AA.
    static let variableMarkerFirst: UInt8 = 0xAA
    static let variableMarkerLast: UInt8 = 0x55
    // Variable header sizes (the Kaitai struct's `len_*_header` instances).
    static let vssStandardHeaderSize: UInt64 = 32
    static let vssAppleHeaderSize: UInt64 = 36
    static let vssAuthHeaderSize: UInt64 = 60
    static let vssIntelLegacyHeaderSize: UInt64 = 28
    // Variable states.
    static let vssVariableValid: UInt8 = 0x7f
    static let vssVariableAdded: UInt8 = 0x3f
    static let vssVariableIntelValid: UInt8 = 0xfc
    static let vssVariableIntelInvalid: UInt8 = 0xf8
    // Attribute bits that decide which header a variable carries.
    static let vssAttributeAuthWrite: UInt32 = 0x0000_0010
    static let vssAttributeTimeBasedAuth: UInt32 = 0x0000_0020
    static let vssAttributeAppendWrite: UInt32 = 0x0000_0040
    static let vssAttributeAppleDataChecksum: UInt32 = 0x8000_0000
    // VSS2 store header: signature (16) + size + format + state + reserved +
    // reserved1, seven dwords.
    static let vss2StoreHeaderSize: UInt64 = 28
    // FTW working block headers, 32-bit and 64-bit write queue forms.
    static let ftwStoreHeaderSize32: UInt64 = 28
    static let ftwStoreHeaderSize64: UInt64 = 32
    // An Insyde FDC store opens `_FDC`, a size, a volume header and two block
    // map entries before the store itself. The header is 0x50 bytes: 4 + 4 for
    // the signature and size, 0x38 for the volume header, 2 * 8 for the map.
    static let insydeFdcSignature: UInt32 = 0x4344_465F // _FDC
    static let fdcStoreHeaderSize: UInt64 = 0x50
    // Apple SysF / Diag store: a signature, an unknown byte and word, and a
    // 16-bit size. The store is 11 bytes of header, a run of variables, and a
    // CRC32 over everything before it, which lives in the last four bytes.
    static let appleSysfSignature: UInt32 = 0x7379_7346 // Fsys
    static let appleDiagSignature: UInt32 = 0x6469_6147 // Gaid
    static let sysfStoreHeaderSize: UInt64 = 11
    /// The last four bytes of a SysF store are its CRC32, not store.
    static let sysfStoreCrcSize: UInt64 = 4
    /// A SysF variable is a name-length byte whose low seven bits are the name
    /// length and whose top bit is the invalid flag, then the name, then the
    /// data length and data. A chunk named `EOF` with no data ends the store.
    static let sysfInvalidFlag: UInt8 = 0x80
    static let sysfNameLengthMask: UInt8 = 0x7F
    /// The name of the chunk that ends a SysF store, with no data after it.
    static let sysfEofName: [UInt8] = Array("EOF".utf8)
    // Phoenix SCT flash map: a 10-byte `_FLASH_MAP` signature, an entry count, a
    // reserved dword, then fixed 36-byte entries.
    static let phoenixFlashMapSignature: [UInt8] = Array("_FLASH_MAP".utf8)
    static let phoenixFlashMapHeaderSize: UInt64 = 16
    static let phoenixFlashMapEntrySize: UInt64 = 36
    static let phoenixFlashMapMaxEntries: UInt16 = 113
    // Phoenix EVSA entry types: the store itself and the entries inside it. A
    // store is type 0xEC; the recognized entries are the guid, name and data
    // kinds below, and anything else ends the store.
    static let evsaSignature: UInt32 = 0x4156_5345 // EVSA
    static let evsaStoreHeaderSize: UInt64 = 20
    static let evsaEntryTypeStore: UInt8 = 0xEC
    static let evsaEntryTypeGuid1: UInt8 = 0xED
    static let evsaEntryTypeGuid2: UInt8 = 0xE1
    static let evsaEntryTypeName1: UInt8 = 0xEE
    static let evsaEntryTypeName2: UInt8 = 0xE2
    static let evsaEntryTypeData1: UInt8 = 0xEF
    static let evsaEntryTypeData2: UInt8 = 0xE3
    static let evsaEntryTypeDataInvalid: UInt8 = 0x83
    /// A data entry whose attributes set the extended-header bit (28) carries
    /// a data-size word before its data.
    static let evsaExtendedHeaderBit: UInt32 = 0x1000_0000
    static let evsaGuidEntryHeaderSize: UInt64 = 6
    static let evsaNameEntryHeaderSize: UInt64 = 6
    static let evsaDataEntryHeaderSize: UInt64 = 12
    static let evsaExtendedDataEntryHeaderSize: UInt64 = 16

    static func isEvsaEntryType(_ type: UInt8) -> Bool {
        switch type {
        case evsaEntryTypeGuid1, evsaEntryTypeGuid2,
             evsaEntryTypeName1, evsaEntryTypeName2,
             evsaEntryTypeData1, evsaEntryTypeData2, evsaEntryTypeDataInvalid:
            return true
        default:
            return false
        }
    }
    // Phoenix CMDB, a store long past use: the parser reads its header and
    // keeps the rest whole.
    static let cmdbSignature: UInt32 = 0x4244_4D43 // CMDB
    static let cmdbStoreSize: UInt64 = 0x100
    // Microsoft SLIC pubkey and marker: two fixed-size activation records,
    // each a whole store with no body of its own.
    static let slicPubkeySize: UInt64 = 0x9C
    static let slicPubkeyType: UInt32 = 0
    static let slicPubkeyMagic: UInt32 = 0x3141_5352 // RSA1
    static let slicMarkerSize: UInt64 = 0xB6
    static let slicMarkerType: UInt32 = 1
    /// The WindowsFlag field, the eight bytes "WINDOWS " read little-endian.
    static let slicMarkerWindowsFlag: UInt64 = 0x2053_574F_444E_4957
    static let slicMarkerReservedByte: UInt8 = 0
}

extension Parser {
    /// The NVRAM volume body, walked store by store (§9). `body` is the
    /// volume's body range (absolute); `emptyByte` is its erase polarity, which
    /// decides what an unwritten byte between stores reads as.
    func walkNvramVolumeBody(
        _ body: Range<UInt64>,
        emptyByte: UInt8,
        depth: Int,
        fdcStoreSizeOverride: UInt64? = nil
    ) -> [UEFINode] {
        // The recursion budget is the parser's own. An FDC store wraps another
        // volume body, which can wrap another, so the walk guards its depth the
        // way the volume and section parsers do. The bound is inclusive because
        // the volume parser already spends the level below `maxDepth` on this
        // body; one more level here must be refused.
        guard depth <= limits.maxDepth else {
            note(.recursionLimit, at: body.lowerBound)
            return []
        }
        var nodes: [UEFINode] = []
        var paddingStart = body.lowerBound
        var storeOffset = body.lowerBound

        while storeOffset < body.upperBound {
            // Free space is a run of the erase byte, and no store starts with
            // the erase byte, so a whole run is jumped in one step instead of
            // paying a recogniser probe for every erased byte. Real NVRAM
            // volumes end in hundreds of kilobytes of free space; stepping it
            // byte by byte would try all twelve recognisers at each one — and
            // the last (a nested firmware volume) a full volume-header read.
            if reader.uint8(at: storeOffset) == emptyByte {
                storeOffset = reader.firstOffset(
                    in: storeOffset..<body.upperBound, notEqualTo: emptyByte
                ) ?? body.upperBound
                continue
            }
            // The store recognisers, in the order the reference parser tries
            // them: first match wins. VSS before VSS2, because a store GUID
            // whose first dword reads `$VSS` would otherwise misroute. SysF,
            // flash map, EVSA, CMDB and SLIC are the stores of Apple and
            // Phoenix firmware. The last two hand the bytes to parsers of
            // their own: a microcode image, or a firmware volume nested whole
            // inside the NVRAM area. Each recogniser is its own statement: a
            // single `??` chain over all of them is beyond the type checker.
            var store: UEFINode? = parseVssStore(
                at: storeOffset, body: body, emptyByte: emptyByte,
                depth: depth, fdcStoreSizeOverride: fdcStoreSizeOverride)
            if store == nil {
                store = parseVss2Store(at: storeOffset, body: body, emptyByte: emptyByte, depth: depth)
            }
            if store == nil {
                store = parseFtwStore(at: storeOffset, body: body, emptyByte: emptyByte, depth: depth)
            }
            if store == nil {
                store = parseFdcStore(at: storeOffset, body: body, emptyByte: emptyByte, depth: depth)
            }
            if store == nil {
                store = parseSysFStore(at: storeOffset, body: body)
            }
            if store == nil {
                store = parsePhoenixFlashMapStore(at: storeOffset, body: body)
            }
            if store == nil {
                store = parsePhoenixEvsaStore(at: storeOffset, body: body, emptyByte: emptyByte)
            }
            if store == nil {
                store = parsePhoenixCmdbStore(at: storeOffset, body: body)
            }
            if store == nil {
                store = parseSlicPublicKey(at: storeOffset, body: body)
            }
            if store == nil {
                store = parseSlicMarker(at: storeOffset, body: body)
            }
            if store == nil {
                store = microcodeStore(at: storeOffset, body: body)
            }
            if store == nil {
                store = volumeStore(at: storeOffset, body: body, depth: depth)
            }
            if let store {
                nodes += nvramPadding(from: paddingStart, to: store.range.lowerBound, emptyByte: emptyByte)
                nodes.append(store)
                paddingStart = store.range.upperBound
                storeOffset = store.range.upperBound
                continue
            }
            // No store here: the byte belongs to the padding run that starts
            // where the last store ended (or at the body's start).
            storeOffset += 1
        }
        nodes += nvramPadding(from: paddingStart, to: body.upperBound, emptyByte: emptyByte)
        return nodes
    }

    /// A run of bytes between NVRAM stores. All the erase byte is free space;
    /// anything in it is padding somebody put there.
    private func nvramPadding(from start: UInt64, to end: UInt64, emptyByte: UInt8) -> [UEFINode] {
        guard start < end else { return [] }
        let range = start..<end
        if reader.isFilled(range, with: emptyByte) {
            return [UEFINode(kind: .freeSpace, name: "Free space", range: range, isErased: true)]
        }
        return [UEFINode(kind: .padding, name: "Padding", range: range, isErased: false)]
    }

    /// A VSS variable store, or nil when the bytes at `offset` are not one.
    ///
    /// A candidate that fails leaves no diagnostic: a false `$VSS` inside data
    /// is padding, not a defect (§9). Inside an Insyde FDC body a plain `$VSS`
    /// store may carry the "no size" marker instead of its size; the FDC parse
    /// passes its body's length down so such a store still spans it.
    func parseVssStore(
        at offset: UInt64,
        body: Range<UInt64>,
        emptyByte: UInt8,
        depth: Int,
        fdcStoreSizeOverride: UInt64? = nil
    ) -> UEFINode? {
        // The whole header must be in the body.
        guard body.upperBound - offset >= NVRAM.vssStoreHeaderSize,
              let signature = reader.uint32(at: offset),
              var storeSize = reader.uint32(at: offset + 4),
              let format = reader.uint8(at: offset + 8)
        else { return nil }

        // The signature and the format are the sanity check.
        guard signature == NVRAM.vssSignature
                || signature == NVRAM.appleSvsSignature
                || signature == NVRAM.appleNssSignature,
              format == NVRAM.vssFormatted
        else { return nil }

        // A `$VSS` store inside an Insyde FDC body carries the "no size" marker
        // (0xFFFFFFFF) where its size should be; it means the store is the whole
        // FDC body, whose length the FDC parse hands down. Only a plain `$VSS`
        // gets this — an Apple `$SVS` or `$NSS` store with the marker is
        // refused, the way the reference parser refuses it.
        if storeSize == 0xFFFF_FFFF, let override = fdcStoreSizeOverride, override < 0xFFFF_FFFF, signature == NVRAM.vssSignature {
            storeSize = UInt32(override)
        }

        // The reference parser refuses a size that is not strictly between the
        // header and 0xFFFFFFFF: too small to hold a variable, or the "no
        // size" marker an FDC store leaves behind.
        guard storeSize > NVRAM.vssStoreHeaderSize, storeSize < 0xFFFF_FFFF else { return nil }

        // The store may not run past the end of the body.
        let size = min(UInt64(storeSize), body.upperBound - offset)
        let storeEnd = offset + size
        let headerEnd = offset + NVRAM.vssStoreHeaderSize

        let name: String
        switch signature {
        case NVRAM.appleSvsSignature: name = "Apple SVS store"
        case NVRAM.appleNssSignature: name = "Apple NSS store"
        default: name = "VSS store"
        }

        let entries = vssVariables(in: headerEnd..<storeEnd, storeEnd: storeEnd, emptyByte: emptyByte)
        return UEFINode(
            kind: .vssStore,
            name: name,
            header: offset..<headerEnd,
            body: headerEnd..<storeEnd,
            isFixed: true,
            children: entries
        )
    }

    /// The variables of a VSS store, walked until the marker stops.
    private func vssVariables(
        in range: Range<UInt64>,
        storeEnd: UInt64,
        emptyByte: UInt8
    ) -> [UEFINode] {
        var entries: [UEFINode] = []
        var offset = range.lowerBound

        while offset < storeEnd {
            guard let marker = reader.uint8(at: offset) else { break }
            // The marker 0x55AA opens a variable; anything else is the
            // terminating entry, and what follows is the store's free space.
            guard marker == NVRAM.variableMarkerFirst else {
                entries += nvramPadding(from: offset, to: storeEnd, emptyByte: emptyByte)
                break
            }
            guard let entry = vssVariable(at: offset, storeEnd: storeEnd) else { break }
            entries.append(entry)
            offset = entry.range.upperBound
        }
        return entries
    }

    /// One VSS variable, or nil when its header does not check out.
    ///
    /// The header shape is decided by the state and attribute bits, the way the
    /// reference parser's Kaitai struct decides it: Intel legacy,
    /// authenticated, Apple (a data CRC), or the plain standard form.
    private func vssVariable(at offset: UInt64, storeEnd: UInt64) -> UEFINode? {
        guard reader.uint8(at: offset + 1) == NVRAM.variableMarkerLast,
              let state = reader.uint8(at: offset + 2),
              let attributes = reader.uint32(at: offset + 4)
        else { return nil }

        let isIntelLegacy = state == NVRAM.vssVariableIntelInvalid
            || state == NVRAM.vssVariableIntelValid

        var headerSize: UInt64
        var nameRange: Range<UInt64>
        var dataRange: Range<UInt64>
        var subtype: UInt8

        if isIntelLegacy {
            // Intel legacy: a total size in place of the name and data sizes,
            // and the name and value run together after the vendor GUID.
            headerSize = NVRAM.vssIntelLegacyHeaderSize
            guard let totalSize = reader.uint32(at: offset + 8) else { return nil }
            let end = min(offset + UInt64(totalSize), storeEnd)
            let nameEnd = min(offset + headerSize + 4, end)
            nameRange = (offset + headerSize)..<nameEnd
            dataRange = nameEnd..<end
            subtype = UEFITypes.Sub.intelVssEntry
        } else {
            // The two size fields are read up front whatever the header turns
            // out to be: for an authenticated variable they are the monotonic
            // counter's two halves. A standard variable always carries a name
            // and data, so two fields that both read zero cannot be that — the
            // variable is authenticated, with a counter that happens to be
            // zero, and its real name and data sizes come after the timestamp
            // and key index. Firmware that never increments the counter writes
            // every variable this way, so the zero check matters as much as the
            // attribute bit (the reference parser's `is_auth` is the same).
            guard let sizeLow = reader.uint32(at: offset + 8),
                  let sizeHigh = reader.uint32(at: offset + 12)
            else { return nil }

            let isAuth = (
                attributes & (NVRAM.vssAttributeAuthWrite
                    | NVRAM.vssAttributeTimeBasedAuth
                    | NVRAM.vssAttributeAppendWrite) != 0
            ) || sizeLow == 0 || sizeHigh == 0

            if isAuth {
                // Authenticated: the name and data sizes come after the
                // timestamp and key index.
                headerSize = NVRAM.vssAuthHeaderSize
                guard let nameSize = reader.uint32(at: offset + 36),
                      let dataSize = reader.uint32(at: offset + 40)
                else { return nil }
                let nameStart = offset + headerSize
                let nameEnd = min(nameStart + UInt64(nameSize), storeEnd)
                let dataEnd = min(nameEnd + UInt64(dataSize), storeEnd)
                nameRange = nameStart..<nameEnd
                dataRange = nameEnd..<dataEnd
                subtype = UEFITypes.Sub.authVssEntry
            } else {
                // Standard, or Apple when the data-checksum bit is set (one
                // extra word after the vendor GUID).
                let apple = attributes & NVRAM.vssAttributeAppleDataChecksum != 0
                headerSize = apple ? NVRAM.vssAppleHeaderSize : NVRAM.vssStandardHeaderSize
                let nameSize = sizeLow
                let dataSize = sizeHigh
                let nameStart = offset + headerSize
                let nameEnd = min(nameStart + UInt64(nameSize), storeEnd)
                let dataEnd = min(nameEnd + UInt64(dataSize), storeEnd)
                nameRange = nameStart..<nameEnd
                dataRange = nameEnd..<dataEnd
                subtype = apple ? UEFITypes.Sub.appleVssEntry : UEFITypes.Sub.standardVssEntry
            }
        }

        // A variable whose state is not one of the valid ones is invalid,
        // whatever it otherwise looked like.
        let isValid = state == NVRAM.vssVariableValid
            || state == NVRAM.vssVariableAdded
            || isIntelLegacy
        if !isValid {
            subtype = UEFITypes.Sub.invalidVssEntry
        }

        // The vendor GUID at offset 16 is the variable's owner — every header
        // shape in a VSS store keeps it there — and the fallback name when the
        // name does not decode. It is read once and set on the node: the
        // details panel shows the common GUID field for every form, and only
        // the parser, which knows the store, can say where a form's GUID sits.
        let vendorGuid = reader.guid(at: offset + 16)

        // The name is the decoded variable name, or the vendor GUID for a
        // variable whose name is not a readable string.
        let name: String
        if isValid, let decoded = ucs2String(in: nameRange), !decoded.isEmpty {
            name = decoded
        } else if let vendorGuid {
            name = vendorGuid.description
        } else {
            name = "Invalid"
        }

        let entryEnd = max(dataRange.upperBound, nameRange.upperBound)
        return UEFINode(
            kind: .vssEntry,
            subtype: subtype,
            name: isValid ? name : "Invalid",
            guid: vendorGuid,
            header: offset..<(offset + headerSize),
            body: (offset + headerSize)..<entryEnd,
            isFixed: true
        )
    }

    /// A VSS2 variable store, or nil when the bytes at `offset` are not one.
    ///
    /// A VSS2 store is led by a 16-byte store GUID (not a four-byte signature)
    /// and is 28 bytes of header; its variables are 4-byte aligned, so the
    /// padding after each one is a node of its own.
    func parseVss2Store(at offset: UInt64, body: Range<UInt64>, emptyByte: UInt8, depth: Int) -> UEFINode? {
        guard body.upperBound - offset >= NVRAM.vss2StoreHeaderSize,
              let signature = reader.guid(at: offset),
              let storeSize = reader.uint32(at: offset + 16),
              let format = reader.uint8(at: offset + 20)
        else { return nil }

        guard NvramGuids.isVss2Store(signature),
              format == NVRAM.vssFormatted
        else { return nil }

        // The reference parser refuses a size that is not strictly between the
        // header and 0xFFFFFFFF.
        guard storeSize > NVRAM.vss2StoreHeaderSize, storeSize < 0xFFFF_FFFF else { return nil }

        let size = min(UInt64(storeSize), body.upperBound - offset)
        let storeEnd = offset + size
        let headerEnd = offset + NVRAM.vss2StoreHeaderSize

        let entries = vss2Variables(in: headerEnd..<storeEnd, storeEnd: storeEnd, emptyByte: emptyByte)
        return UEFINode(
            kind: .vss2Store,
            name: "VSS2 store",
            header: offset..<headerEnd,
            body: headerEnd..<storeEnd,
            isFixed: true,
            children: entries
        )
    }

    /// The variables of a VSS2 store, walked until the marker stops. Each
    /// variable is 4-byte aligned from its own start, so the padding after one
    /// is a node of its own — the way a volume's file walk keeps its gaps.
    private func vss2Variables(
        in range: Range<UInt64>,
        storeEnd: UInt64,
        emptyByte: UInt8
    ) -> [UEFINode] {
        var entries: [UEFINode] = []
        var offset = range.lowerBound

        while offset < storeEnd {
            guard let marker = reader.uint8(at: offset) else { break }
            guard marker == NVRAM.variableMarkerFirst else {
                entries += nvramPadding(from: offset, to: storeEnd, emptyByte: emptyByte)
                break
            }
            guard let entry = vss2Variable(at: offset, storeEnd: storeEnd) else { break }
            entries.append(entry)
            // The alignment padding to the next four-byte boundary, counted
            // from the variable's own start, is a node of its own.
            let used = entry.range.upperBound - offset
            let aligned = alignUp(used, to: 4) ?? used
            if aligned > used {
                let padEnd = min(offset + aligned, storeEnd)
                entries.append(UEFINode(
                    kind: .padding,
                    name: "Padding",
                    range: entry.range.upperBound..<padEnd,
                    isErased: reader.isFilled(entry.range.upperBound..<padEnd, with: emptyByte)
                ))
            }
            offset = min(offset + aligned, storeEnd)
        }
        return entries
    }

    /// One VSS2 variable, or nil when its header does not check out.
    ///
    /// The header shape is decided by the attribute bits and the two size
    /// fields: authenticated (a monotonic counter in place of the sizes, a
    /// timestamp, and a key index) or the plain standard form. There is no
    /// Intel legacy or Apple form in VSS2, and the name sits in the header,
    /// with the data as the body.
    private func vss2Variable(at offset: UInt64, storeEnd: UInt64) -> UEFINode? {
        guard reader.uint8(at: offset + 1) == NVRAM.variableMarkerLast,
              let state = reader.uint8(at: offset + 2),
              let attributes = reader.uint32(at: offset + 4),
              let lenName = reader.uint32(at: offset + 8),
              let lenData = reader.uint32(at: offset + 12)
        else { return nil }

        // VSS2 has no Intel legacy: a variable is authenticated when an auth
        // bit is set, or when either size field is zero (the marker of an auth
        // variable whose real sizes come after the timestamp and key index).
        let isAuth = (
            attributes & (NVRAM.vssAttributeAuthWrite
                | NVRAM.vssAttributeTimeBasedAuth
                | NVRAM.vssAttributeAppendWrite) != 0
        ) || lenName == 0 || lenData == 0

        var headerSize: UInt64
        var nameSize: UInt32
        var dataSize: UInt32
        var subtype: UInt8

        if isAuth {
            headerSize = NVRAM.vssAuthHeaderSize
            guard let nameSizeAuth = reader.uint32(at: offset + 36),
                  let dataSizeAuth = reader.uint32(at: offset + 40)
            else { return nil }
            nameSize = nameSizeAuth
            dataSize = dataSizeAuth
            subtype = UEFITypes.Sub.authVssEntry
        } else {
            headerSize = NVRAM.vssStandardHeaderSize
            nameSize = lenName
            dataSize = lenData
            subtype = UEFITypes.Sub.standardVssEntry
        }

        // The name is in the header; the data is the body.
        let nameStart = offset + headerSize
        let nameEnd = min(nameStart + UInt64(nameSize), storeEnd)
        let dataEnd = min(nameEnd + UInt64(dataSize), storeEnd)

        // A variable whose state is not one of the valid ones is invalid.
        let isValid = state == NVRAM.vssVariableValid || state == NVRAM.vssVariableAdded
        if !isValid {
            subtype = UEFITypes.Sub.invalidVssEntry
        }

        // The vendor GUID is the sixteen bytes just before the name — the same
        // read the fallback name makes — so it is read once and set on the
        // node. The details panel shows the common GUID field for every form,
        // and only the parser, which knows the store, can say where a form's
        // GUID sits.
        let vendorGuid = reader.guid(at: offset + headerSize - 16)

        // The name is the decoded variable name, or the vendor GUID for a
        // variable whose name is not a readable string.
        let name: String
        if isValid, let decoded = ucs2String(in: nameStart..<nameEnd), !decoded.isEmpty {
            name = decoded
        } else if let vendorGuid {
            name = vendorGuid.description
        } else {
            name = "Invalid"
        }

        return UEFINode(
            kind: .vssEntry,
            subtype: subtype,
            name: isValid ? name : "Invalid",
            guid: vendorGuid,
            header: offset..<nameEnd,
            body: nameEnd..<dataEnd,
            isFixed: true
        )
    }

    /// An FTW working block, or nil when the bytes at `offset` are not one.
    ///
    /// An FTW block is led by a 16-byte signature GUID and carries a header
    /// CRC32 over itself with the CRC and state fields blanked to the erase
    /// value. The write queue after the header is opaque: the reference parser
    /// keeps it whole.
    func parseFtwStore(at offset: UInt64, body: Range<UInt64>, emptyByte: UInt8, depth: Int) -> UEFINode? {
        // The 32-bit header must be in the body.
        guard body.upperBound - offset >= NVRAM.ftwStoreHeaderSize32,
              let signature = reader.guid(at: offset),
              let writeQueueSize32 = reader.uint32(at: offset + 24)
        else { return nil }

        guard NvramGuids.isFtwStore(signature) else { return nil }

        // The write queue size's low nibble decides the header form: ending in
        // 4 is a 32-bit queue, ending in 0 a 64-bit one, anything else unknown.
        let headerSize: UInt64
        let writeQueueSize: UInt64
        switch writeQueueSize32 % 0x10 {
        case 4:
            headerSize = NVRAM.ftwStoreHeaderSize32
            writeQueueSize = UInt64(writeQueueSize32)
        case 0:
            guard body.upperBound - offset >= NVRAM.ftwStoreHeaderSize64,
                  let writeQueueSize64 = reader.uint32(at: offset + 28)
            else { return nil }
            headerSize = NVRAM.ftwStoreHeaderSize64
            writeQueueSize = (UInt64(writeQueueSize64) << 32) | UInt64(writeQueueSize32)
        default:
            return nil
        }

        // The block may not run past the end of the body.
        let size = min(headerSize + writeQueueSize, body.upperBound - offset)
        let storeEnd = offset + size
        let headerEnd = offset + headerSize

        // The header CRC32 is over the header with the CRC and state fields
        // blanked to the erase value.
        if var headerBytes = reader.bytes(at: offset, count: headerSize) {
            headerBytes[16] = emptyByte; headerBytes[17] = emptyByte
            headerBytes[18] = emptyByte; headerBytes[19] = emptyByte
            headerBytes[20] = emptyByte
            let stored = reader.uint32(at: offset + 16) ?? 0
            let computed = Checksums.crc32(headerBytes)
            if stored != computed {
                note(
                    .checksumMismatch(.nvramStore, stored: UInt64(stored), computed: UInt64(computed)),
                    at: offset + 16
                )
            }
        }

        return UEFINode(
            kind: .ftwStore,
            name: "FTW store",
            header: offset..<headerEnd,
            body: headerEnd..<storeEnd,
            isFixed: true
        )
    }

    /// An Insyde FDC store, or nil when the bytes at `offset` are not one.
    ///
    /// An FDC store is a working copy of a variable store: `_FDC`, a size, a
    /// volume header and two block map entries, then the store itself. The
    /// reference parser reads what follows as an NVRAM volume body of its own,
    /// handing it the FDC body's length so a `$VSS` store inside that says "no
    /// size" is understood to span the whole body.
    func parseFdcStore(at offset: UInt64, body: Range<UInt64>, emptyByte: UInt8, depth: Int) -> UEFINode? {
        // The whole header must be in the body.
        guard body.upperBound - offset >= NVRAM.fdcStoreHeaderSize,
              let signature = reader.uint32(at: offset),
              let storeSize = reader.uint32(at: offset + 4)
        else { return nil }

        guard signature == NVRAM.insydeFdcSignature else { return nil }

        // The reference parser refuses a size that is not strictly between the
        // header and 0xFFFFFFFF.
        guard storeSize > NVRAM.fdcStoreHeaderSize, storeSize < 0xFFFF_FFFF else { return nil }

        // The store may not run past the end of the body.
        let size = min(UInt64(storeSize), body.upperBound - offset)
        let headerEnd = offset + NVRAM.fdcStoreHeaderSize
        let storeEnd = offset + size
        let fdcBody = headerEnd..<storeEnd

        let children = walkNvramVolumeBody(
            fdcBody,
            emptyByte: emptyByte,
            depth: depth + 1,
            fdcStoreSizeOverride: fdcBody.upperBound - fdcBody.lowerBound
        )
        return UEFINode(
            kind: .fdcStore,
            name: "Insyde FDC store",
            header: offset..<headerEnd,
            body: fdcBody,
            isFixed: true,
            children: children
        )
    }

    /// An Apple SysF or Diag store, or nil when the bytes at `offset` are not
    /// one.
    ///
    /// A SysF store is a signature, a couple of unknown fields and a 16-bit
    /// size, then a run of variables — each a length byte, an ASCII name, and
    /// a data length and data — that ends with a chunk named `EOF`. The last
    /// four bytes are the store's CRC32, which is how the store knows its own
    /// extent; the reference parser reads the variables from everything but
    /// them.
    func parseSysFStore(at offset: UInt64, body: Range<UInt64>) -> UEFINode? {
        guard body.upperBound - offset >= NVRAM.sysfStoreHeaderSize + NVRAM.sysfStoreCrcSize,
              let signature = reader.uint32(at: offset),
              let declaredSize = reader.uint16(at: offset + 9)
        else { return nil }

        guard signature == NVRAM.appleSysfSignature || signature == NVRAM.appleDiagSignature
        else { return nil }

        // A store must hold its header and the CRC32 at its end, and a store
        // that declares more than the body holds is rejected: the reference
        // parser reads the store's fixed-size body whole, so a store cut short
        // by the volume is not one.
        let storeEnd = offset + UInt64(declaredSize)
        guard storeEnd <= body.upperBound,
              storeEnd - offset >= NVRAM.sysfStoreHeaderSize + NVRAM.sysfStoreCrcSize
        else { return nil }

        let headerEnd = offset + NVRAM.sysfStoreHeaderSize
        // The variables live in everything but the final CRC32.
        let regionEnd = storeEnd - NVRAM.sysfStoreCrcSize

        let name: String
        switch signature {
        case NVRAM.appleDiagSignature: name = "Apple Diag store"
        default: name = "Apple SysF store"
        }

        var entries: [UEFINode] = []
        var cursor = headerEnd
        while cursor < regionEnd {
            // A variable is a length byte (the name length in its low seven
            // bits, the invalid flag on top), the ASCII name, then a data
            // length and the data.
            guard let flags = reader.uint8(at: cursor) else { break }
            let invalid = flags & NVRAM.sysfInvalidFlag != 0
            let nameLength = UInt64(flags & NVRAM.sysfNameLengthMask)
            let nameStart = cursor + 1
            guard nameStart + nameLength <= regionEnd,
                  let nameBytes = reader.bytes(at: nameStart, count: nameLength)
            else { return nil }

            let subtype = invalid
                ? UEFITypes.Sub.invalidSysFEntry
                : UEFITypes.Sub.normalSysFEntry

            // A chunk named "EOF" ends the store: four bytes of header and no
            // data, and the reference parser reads nothing after it.
            if nameBytes == NVRAM.sysfEofName {
                entries.append(UEFINode(
                    kind: .sysFEntry,
                    subtype: subtype,
                    name: invalid ? "Invalid" : "EOF",
                    header: cursor..<(cursor + 4),
                    body: (cursor + 4)..<(cursor + 4),
                    isFixed: true
                ))
                cursor += 4
                break
            }

            let dataLengthOffset = nameStart + nameLength
            guard dataLengthOffset + 2 <= regionEnd,
                  let dataLength = reader.uint16(at: dataLengthOffset)
            else { return nil }
            let bodyStart = dataLengthOffset + 2
            let bodyEnd = bodyStart + UInt64(dataLength)
            guard bodyEnd <= regionEnd else { return nil }

            entries.append(UEFINode(
                kind: .sysFEntry,
                subtype: subtype,
                name: invalid ? "Invalid" : asciiName(nameBytes),
                header: cursor..<bodyStart,
                body: bodyStart..<bodyEnd,
                isFixed: true
            ))
            cursor = bodyEnd
        }

        // What follows the last variable is free space when it is zeroes; the
        // CRC32 in the final four bytes is not part of the test.
        if cursor < storeEnd {
            let checkEnd = max(cursor, storeEnd - NVRAM.sysfStoreCrcSize)
            if reader.isFilled(cursor..<checkEnd, with: 0) {
                entries.append(UEFINode(kind: .freeSpace, name: "Free space", range: cursor..<storeEnd))
            } else {
                entries.append(UEFINode(kind: .padding, name: "Padding", range: cursor..<storeEnd))
            }
        }

        return UEFINode(
            kind: .sysFStore,
            name: name,
            header: offset..<headerEnd,
            body: headerEnd..<storeEnd,
            isFixed: true,
            children: entries
        )
    }

    /// The readable prefix of a SysF variable name: its ASCII bytes up to the
    /// first zero, if a stored name carries a terminator.
    private func asciiName(_ bytes: [UInt8]) -> String {
        var prefix: [UInt8] = []
        for byte in bytes {
            if byte == 0 { break }
            prefix.append(byte)
        }
        return String(decoding: prefix, as: UTF8.self)
    }

    /// A Phoenix SCT flash map, or nil when the bytes at `offset` are not one.
    ///
    /// A flash map is a 10-byte `_FLASH_MAP` signature, an entry count and a
    /// reserved dword, then one fixed 36-byte entry per region of the SCT: a
    /// GUID that names the region, its data and entry types, its physical
    /// address, size and offset. The entries carry the GUID as identity, so
    /// the tree names them through the catalogue.
    func parsePhoenixFlashMapStore(at offset: UInt64, body: Range<UInt64>) -> UEFINode? {
        guard body.upperBound - offset >= NVRAM.phoenixFlashMapHeaderSize,
              let signature = reader.bytes(at: offset, count: UInt64(NVRAM.phoenixFlashMapSignature.count)),
              let entryCount = reader.uint16(at: offset + 10)
        else { return nil }

        guard signature == NVRAM.phoenixFlashMapSignature,
              entryCount <= NVRAM.phoenixFlashMapMaxEntries
        else { return nil }

        let storeSize = NVRAM.phoenixFlashMapHeaderSize
            + UInt64(entryCount) * NVRAM.phoenixFlashMapEntrySize
        // The map runs to the length its entry count claims; a map that runs
        // past the body is not one.
        guard storeSize <= body.upperBound - offset else { return nil }

        let storeEnd = offset + storeSize
        let headerEnd = offset + NVRAM.phoenixFlashMapHeaderSize

        var entries: [UEFINode] = []
        var cursor = headerEnd
        while cursor < storeEnd {
            let entryEnd = cursor + NVRAM.phoenixFlashMapEntrySize
            guard entryEnd <= storeEnd, let guid = reader.guid(at: cursor) else { break }
            let dataType = reader.uint16(at: cursor + 16) ?? 0
            let subtype: UInt8
            switch dataType {
            case 0x0000: subtype = UEFITypes.Sub.volumeFlashMapEntry
            case 0x0001: subtype = UEFITypes.Sub.dataFlashMapEntry
            default: subtype = UEFITypes.Sub.unknownFlashMapEntry
            }
            entries.append(UEFINode(
                kind: .flashMapEntry,
                subtype: subtype,
                name: guid.description,
                guid: guid,
                header: cursor..<entryEnd,
                body: entryEnd..<entryEnd,
                isFixed: true
            ))
            cursor = entryEnd
        }

        return UEFINode(
            kind: .flashMapStore,
            name: "Phoenix SCT flash map",
            header: offset..<headerEnd,
            body: headerEnd..<storeEnd,
            isFixed: true,
            children: entries
        )
    }

    /// A Phoenix EVSA store, or nil when the bytes at `offset` are not one.
    ///
    /// An EVSA store is an entry of type 0xEC whose signature is `EVSA`,
    /// holding a run of entries that define variables: GUID entries give a
    /// variable's vendor GUID a numeric GuidId, name entries give a variable a
    /// name and a numeric VarId, and data entries hold a value referenced by
    /// the two ids. An entry type the parser does not know ends the store, and
    /// what follows is free space or padding.
    func parsePhoenixEvsaStore(at offset: UInt64, body: Range<UInt64>, emptyByte: UInt8) -> UEFINode? {
        guard body.upperBound - offset >= NVRAM.evsaStoreHeaderSize,
              let type = reader.uint8(at: offset),
              let headerSize = reader.uint16(at: offset + 2),
              let signature = reader.uint32(at: offset + 4),
              let declaredSize = reader.uint32(at: offset + 12)
        else { return nil }

        guard type == NVRAM.evsaEntryTypeStore,
              headerSize == UInt16(NVRAM.evsaStoreHeaderSize),
              signature == NVRAM.evsaSignature,
              declaredSize > NVRAM.evsaStoreHeaderSize
        else { return nil }

        // A store that declares more than the body holds is rejected: the
        // reference parser reads the store's fixed-size body whole, so a store
        // cut short by the volume is not one.
        let storeEnd = offset + UInt64(declaredSize)
        guard storeEnd <= body.upperBound else { return nil }

        let headerEnd = offset + NVRAM.evsaStoreHeaderSize

        var children: [UEFINode] = []
        var guidMap: [UInt16: EFIGUID] = [:]
        var nameMap: [UInt16: String] = [:]
        var dataVariables: [(index: Int, type: UInt8, guidId: UInt16, varId: UInt16)] = []

        var cursor = headerEnd
        while cursor < storeEnd {
            guard let entryType = reader.uint8(at: cursor) else { break }
            // The reference parser reads entries until the entry type is not
            // one it knows; the rest of the store is free space or padding.
            guard NVRAM.isEvsaEntryType(entryType) else {
                children += nvramPadding(from: cursor, to: storeEnd, emptyByte: emptyByte)
                break
            }
            guard let entrySize = reader.uint16(at: cursor + 2) else { return nil }
            guard cursor + UInt64(entrySize) <= storeEnd else { return nil }
            let entryEnd = cursor + UInt64(entrySize)

            var next = entryEnd
            switch entryType {
            case NVRAM.evsaEntryTypeGuid1, NVRAM.evsaEntryTypeGuid2:
                // A GUID entry is a header, an id word and the 16-byte GUID.
                guard entrySize == 22, let guid = reader.guid(at: cursor + 6) else { return nil }
                let guidId = reader.uint16(at: cursor + 4) ?? 0
                children.append(UEFINode(
                    kind: .evsaEntry,
                    subtype: UEFITypes.Sub.guidEvsaEntry,
                    name: guid.description,
                    guid: guid,
                    header: cursor..<(cursor + 6),
                    body: (cursor + 6)..<entryEnd,
                    isFixed: true
                ))
                guidMap[guidId] = guid
            case NVRAM.evsaEntryTypeName1, NVRAM.evsaEntryTypeName2:
                // A name entry is a header, an id word and a UCS-2 name.
                guard entrySize >= 6 else { return nil }
                let varId = reader.uint16(at: cursor + 4) ?? 0
                let decoded = ucs2String(in: (cursor + 6)..<entryEnd) ?? ""
                children.append(UEFINode(
                    kind: .evsaEntry,
                    subtype: UEFITypes.Sub.nameEvsaEntry,
                    name: decoded,
                    header: cursor..<(cursor + 6),
                    body: (cursor + 6)..<entryEnd,
                    isFixed: true
                ))
                if !decoded.isEmpty { nameMap[varId] = decoded }
            default:
                // A data entry: a GuidId, a VarId, an attributes word, and the
                // data — prefixed by a data-size word when the extended-header
                // bit is set. It is named and typed again once every entry has
                // been read and the id maps are complete.
                guard entrySize >= 12 else { return nil }
                let guidId = reader.uint16(at: cursor + 4) ?? 0
                let varId = reader.uint16(at: cursor + 6) ?? 0
                let attributes = reader.uint32(at: cursor + 8) ?? 0
                let extended = attributes & NVRAM.evsaExtendedHeaderBit != 0
                let headerLength = extended
                    ? NVRAM.evsaExtendedDataEntryHeaderSize
                    : NVRAM.evsaDataEntryHeaderSize
                guard entrySize >= headerLength else { return nil }
                // An extended entry carries its own data size after the
                // attributes; the reference parser steps by that, not by the
                // entry's size field, when the two disagree.
                if extended {
                    guard let dataSize = reader.uint32(at: cursor + 12) else { return nil }
                    next = cursor + headerLength + UInt64(dataSize)
                    guard next <= storeEnd else { return nil }
                }
                let dataIndex = children.count
                children.append(UEFINode(
                    kind: .evsaEntry,
                    subtype: UEFITypes.Sub.dataEvsaEntry,
                    name: "Data",
                    header: cursor..<(cursor + headerLength),
                    body: (cursor + headerLength)..<next,
                    isFixed: true
                ))
                dataVariables.append((index: dataIndex, type: entryType, guidId: guidId, varId: varId))
            }
            cursor = next
        }

        // A data variable needs both of its ids to resolve, to a GUID entry
        // and to a name entry; a data entry marked invalid, or one whose ids
        // resolve to nothing, is invalid.
        for draft in dataVariables {
            let guidResolved = guidMap[draft.guidId] != nil
            let nameResolved = nameMap[draft.varId] != nil
            var node = children[draft.index]
            if draft.type == NVRAM.evsaEntryTypeDataInvalid || !guidResolved || !nameResolved {
                node.name = "Invalid"
                node.subtype = UEFITypes.Sub.invalidEvsaEntry
            } else {
                // The name a person gave the variable is what the tree shows;
                // the vendor GUID stays out of the way the way a VSS
                // variable's does.
                node.name = nameMap[draft.varId] ?? "Invalid"
            }
            children[draft.index] = node
        }

        return UEFINode(
            kind: .evsaStore,
            name: "Phoenix EVSA store",
            header: offset..<headerEnd,
            body: headerEnd..<storeEnd,
            isFixed: true,
            children: children
        )
    }

    /// A Phoenix CMDB store, or nil when the bytes at `offset` is not one.
    ///
    /// CMDB is a store long past use: the parser reads its signature, sizes
    /// its header from the store's own total size, and keeps the rest whole.
    func parsePhoenixCmdbStore(at offset: UInt64, body: Range<UInt64>) -> UEFINode? {
        guard body.upperBound - offset >= NVRAM.cmdbStoreSize,
              let signature = reader.uint32(at: offset),
              let totalSize = reader.uint32(at: offset + 8)
        else { return nil }

        guard signature == NVRAM.cmdbSignature else { return nil }

        let storeEnd = offset + NVRAM.cmdbStoreSize
        // The header reaches to the store's total size — never past the store
        // itself — and what follows it is the body the parser keeps whole.
        let headerEnd = offset + min(UInt64(totalSize), NVRAM.cmdbStoreSize)
        return UEFINode(
            kind: .cmdbStore,
            name: "Phoenix CMDB store",
            header: offset..<headerEnd,
            body: headerEnd..<storeEnd,
            isFixed: true
        )
    }

    /// A SLIC public key, or nil when the bytes at `offset` is not one.
    ///
    /// A pubkey is a fixed 0x9C bytes: type and size, key material, and the
    /// `RSA1` magic. The whole record is the store's header.
    func parseSlicPublicKey(at offset: UInt64, body: Range<UInt64>) -> UEFINode? {
        guard body.upperBound - offset >= NVRAM.slicPubkeySize,
              let type = reader.uint32(at: offset),
              let size = reader.uint32(at: offset + 4),
              let magic = reader.uint32(at: offset + 16)
        else { return nil }

        guard type == NVRAM.slicPubkeyType,
              size == UInt32(NVRAM.slicPubkeySize),
              magic == NVRAM.slicPubkeyMagic
        else { return nil }

        let storeEnd = offset + NVRAM.slicPubkeySize
        return UEFINode(
            kind: .slicData,
            subtype: UEFITypes.Sub.pubkeySlicData,
            name: "SLIC pubkey",
            header: offset..<storeEnd,
            body: storeEnd..<storeEnd,
            isFixed: true
        )
    }

    /// A SLIC marker, or nil when the bytes at `offset` is not one.
    ///
    /// A marker is a fixed 0xB6 bytes: type and size, a version, the OEM's id
    /// and table id, the eight-byte `WINDOWS ` flag, and sixteen reserved
    /// zero bytes. The whole record is the store's header.
    func parseSlicMarker(at offset: UInt64, body: Range<UInt64>) -> UEFINode? {
        guard body.upperBound - offset >= NVRAM.slicMarkerSize,
              let type = reader.uint32(at: offset),
              let size = reader.uint32(at: offset + 4),
              let windowsFlag = reader.uint64(at: offset + 26)
        else { return nil }

        // The reserved bytes after the windows flag must all be zero.
        guard type == NVRAM.slicMarkerType,
              size == UInt32(NVRAM.slicMarkerSize),
              windowsFlag == NVRAM.slicMarkerWindowsFlag,
              reader.isFilled((offset + 38)..<(offset + 54), with: NVRAM.slicMarkerReservedByte)
        else { return nil }

        let storeEnd = offset + NVRAM.slicMarkerSize
        return UEFINode(
            kind: .slicData,
            subtype: UEFITypes.Sub.markerSlicData,
            name: "SLIC marker",
            header: offset..<storeEnd,
            body: storeEnd..<storeEnd,
            isFixed: true
        )
    }

    /// A store that is really an Intel microcode image, or nil when the bytes at
    /// `offset` are not one.
    ///
    /// The microcode parser is the one that knows microcode, so this hands the
    /// bytes to it (§7.1). The reference parser only lets a candidate through
    /// when the whole image fits in what is left of the body: an image that
    /// overruns it is not a store, whatever its header says.
    private func microcodeStore(at offset: UInt64, body: Range<UInt64>) -> UEFINode? {
        guard let header = MicrocodeHeader.read(at: offset, in: reader) else { return nil }
        let imageEnd = offset + UInt64(header.totalSize)
        guard imageEnd <= body.upperBound else { return nil }
        // Limiting the delegate to the image's own extent means it never has to
        // cut the image short; the checksum is then over the whole image.
        return parseMicrocode(at: offset, limit: imageEnd)
    }

    /// A store that is really a firmware volume nested whole inside the NVRAM
    /// area, or nil when the bytes at `offset` are not one.
    ///
    /// The `_FVH` signature is read here before the volume parser is asked: the
    /// walk offers this recogniser a candidate on every byte that is not free
    /// space, and the parser's own header read slices off several fields before
    /// it reaches the signature. One signature read decides most candidates, the
    /// way the reference parser's single comparison does.
    private func volumeStore(at offset: UInt64, body: Range<UInt64>, depth: Int) -> UEFINode? {
        guard reader.uint32(at: offset + FV.signatureOffset) == FV.signature else { return nil }
        return parseVolume(at: offset, limit: body.upperBound, depth: depth + 1)
    }
}
