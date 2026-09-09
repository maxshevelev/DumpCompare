import Foundation

/// CSE EFS (Extended File System) + FITC ("OEM Configuration") on-flash
/// partition decode — upstream `efs_anl` (MEA.py 8621) and `fitc_anl`
/// (MEA.py 8572). These are *raw* FPT partitions ("EFS" / "FITC") on the newer
/// (CSME 15) whole-flash layout, not contents of a Huffman module body.
///
/// Only the byte-derived structural decode is ported. EFS *file* naming and
/// per-file integrity, and FITC *config records*, are assembled from the
/// external `FileTable.dat` EFST/FTBL rows — a parked DB-naming increment — so
/// both parsers stop at the on-flash facts. Verified byte-for-byte on the CSME
/// 15.0.30 dump's EFS @0x267000 and FITC @0x1F2000.
enum EFSParser {

    static let pageSize = 0x1000          // EFS page size (upstream page_size)
    static let pageHeaderSize = 0x10      // EFS_Page_Header
    static let pageFooterSize = 0x08      // EFS_Page_Footer
    static let crcLength = 0x04
    static let indexPaddingLength = 0x08

    /// Decode the EFS volume occupying `region[offset ..< offset+size]`.
    /// `absoluteOffset` is the volume's position in the analyzed image (reported
    /// as `EFSVolume.offset`); `mfsDictionary` is the owning MFS volume's File
    /// Table Dictionary id (nil when no MFS decodes alongside), used to check
    /// the System page's Dictionary matches.
    ///
    /// Returns nil when the area does not open with a System page — upstream's
    /// "unrecognizable format" skip (MEA.py 8643). Its fixed 21-byte format
    /// regex is, byte for byte, just the System-page identity: a u16 Dictionary
    /// id in neither 0x0000 nor 0xFFFF followed by the page's own bootstrap
    /// counter. Gate on the page classification directly is equivalent and
    /// documents that intent.
    static func parse(in region: Data, offset: Int, size: Int,
                      absoluteOffset: Int, mfsDictionary: Int?) -> EFSVolume? {
        guard offset >= 0, size >= pageSize, offset + size <= region.count else { return nil }
        let buffer = region.subdata(in: offset..<(offset + size))
        let pageCount = buffer.count / pageSize
        guard pageCount >= 1 else { return nil }

        // The volume must open with a System page (Dictionary ∉ {0x0000, 0xFFFF}).
        guard let firstDict = EFSParser.u16(buffer, at: 0x02),
              firstDict != 0x0000, firstDict != 0xFFFF else { return nil }

        // ——— Page inventory: classify by header. System pages carry a File
        // Table Dictionary id; Data pages a Dictionary of 0x0000/0xFFFF with a
        // non-erased Unknown0; everything else is a Scratch/empty page (0xFF).
        var systemPages: [Int] = []       // page bases (index * pageSize)
        var dataPages: [Int] = []
        var scratchBytes = 0              // Scratch pages accumulate for an all-FF check
        var scratchIsAllFF = true
        for page in 0..<pageCount {
            let base = page * pageSize
            let dictionary = EFSParser.u16(buffer, at: base + 0x02) ?? 0
            let unknown0 = EFSParser.u16(buffer, at: base + 0x00) ?? 0xFFFF
            if dictionary != 0x0000 && dictionary != 0xFFFF {
                systemPages.append(base)
            } else if unknown0 != 0xFFFF {
                dataPages.append(base)
            } else {
                for i in 0..<pageSize where buffer[base + i] != 0xFF {
                    scratchIsAllFF = false
                }
                scratchBytes += pageSize
            }
        }
        let systemPageCount = systemPages.count
        let dataPageCount = dataPages.count
        let scratchPageCount = scratchBytes / pageSize

        // ——— System Page facts. First classified page is the (single) System
        // page the volume actually boots from (page 0, given the gate above).
        let systemBase = systemPages[0]
        let dictionary = EFSParser.u16(buffer, at: systemBase + 0x02) ?? 0
        let revision = EFSParser.u32(buffer, at: systemBase + 0x04) ?? 0
        let unknown1 = buffer[systemBase + 0x08]
        let dataPagesCommitted = buffer[systemBase + 0x09]
        let dataPagesReserved = buffer[systemBase + 0x0A]
        let dictionaryRevision = buffer[systemBase + 0x0B]

        // System Page Header CRC-32: over header bytes [0x00:0x0C]
        // (Unknown0 … DictRevision), IV 0 raw register.
        let sysHeaderSpan = buffer[systemBase..<(systemBase + 0x0C)]
        let sysHeaderCRCStored = EFSParser.u32(buffer, at: systemBase + 0x0C) ?? 0
        let systemHeaderCRCValid =
            CRC32.crc32IV0Raw(sysHeaderSpan) == sysHeaderCRCStored

        // Total Data Pages as reported by the System header, and the System
        // Index Area geometry that follows it. Each index area on the System
        // page is [sys_dat_count index bytes][8 zero padding][4 CRC].
        let sysDataCount = Int(dataPagesCommitted) + Int(dataPagesReserved)
        let dataPageCountMatchesSystem = dataPageCount == sysDataCount
        let indexAreaSize = sysDataCount + indexPaddingLength + crcLength

        // 1st Index Area padding: the 8 bytes right after the first index
        // area's count of index bytes (immediately after the header) are zero.
        let firstPaddingStart = pageHeaderSize + sysDataCount
        var firstIndexPaddingEmpty = true
        if firstPaddingStart + indexPaddingLength <= pageSize {
            for i in 0..<indexPaddingLength
            where buffer[systemBase + firstPaddingStart + i] != 0x00 {
                firstIndexPaddingEmpty = false
            }
        } else {
            firstIndexPaddingEmpty = false
        }

        // Locate the System page's current index area: the last area written
        // sits immediately before the page's first run of free (0xFF) space big
        // enough for one area. Upstream searches the whole page for that run and
        // steps back `indexAreaSize` (MEA.py 8734).
        var indexOffset = -1
        if indexAreaSize <= pageSize - pageHeaderSize {
            search: for probe in (pageHeaderSize...(pageSize - indexAreaSize)) {
                var allFF = true
                for i in 0..<indexAreaSize where buffer[systemBase + probe + i] != 0xFF {
                    allFF = false
                    break
                }
                if allFF { indexOffset = probe - indexAreaSize; break search }
            }
        }

        // The current index area: `sysDataCount` index bytes (a permutation into
        // the physically-classified Data pages) + 8 zero padding + 4 CRC.
        var dataPageOrder: [UInt8] = []
        var indexesCRCValid = false
        if indexOffset >= 0 {
            var valid = true
            for i in 0..<sysDataCount {
                guard indexOffset + i < buffer.count - systemBase else { valid = false; break }
                dataPageOrder.append(buffer[systemBase + indexOffset + i])
            }
            if valid {
                let indexSpanStart = systemBase + indexOffset
                let indexSpanEnd = indexSpanStart + sysDataCount + indexPaddingLength
                let indexCRCRegion = buffer[indexSpanStart..<indexSpanEnd]
                let indexCRCStored = EFSParser.u32(buffer, at: indexSpanEnd) ?? 0
                indexesCRCValid = CRC32.crc32IV0Raw(indexCRCRegion) == indexCRCStored
            }
        }

        // ——— Data Page header/footer CRC-32 validation, in System index order.
        // A reserved/empty Data page is skipped when its content region is all
        // 0xFF and its stored footer CRC is 0xFFFFFFFF (upstream dat_ftr_crc32_skip).
        var dataPageHeaderCRCsValid = true
        var dataPageFooterCRCsValid = true
        let orderValid = dataPageOrder.count == dataPageCount
            && dataPageOrder.allSatisfy { Int($0) < dataPageCount }
        if orderValid {
            for value in dataPageOrder {
                let base = dataPages[Int(value)]
                // Header CRC-32 over [0x00:0x0C].
                let headerCRCStored = EFSParser.u32(buffer, at: base + 0x0C) ?? 0
                if CRC32.crc32IV0Raw(buffer[base..<(base + 0x0C)]) != headerCRCStored {
                    dataPageHeaderCRCsValid = false
                }
                // Footer CRC-32 over the page from the header end to the footer
                // CRC itself: [0x10 : pageSize-4].
                let body = buffer[(base + pageHeaderSize)..<(base + pageSize - crcLength)]
                let footerCRCStored = EFSParser.u32(buffer, at: base + pageSize - crcLength) ?? 0
                var bodyAllFF = true
                for byte in body where byte != 0xFF { bodyAllFF = false; break }
                let skip = bodyAllFF && footerCRCStored == 0xFFFF_FFFF
                if !skip && CRC32.crc32IV0Raw(body) != footerCRCStored {
                    dataPageFooterCRCsValid = false
                }
            }
        } else {
            dataPageHeaderCRCsValid = dataPageCount == 0
            dataPageFooterCRCsValid = dataPageCount == 0
        }

        return EFSVolume(
            offset: absoluteOffset,
            pageSize: pageSize,
            systemPageCount: systemPageCount,
            dataPageCount: dataPageCount,
            scratchPageCount: scratchPageCount,
            scratchPagesEmpty: scratchIsAllFF,
            dataPageCountMatchesSystem: dataPageCountMatchesSystem,
            dictionary: dictionary,
            revision: revision,
            unknown1: unknown1,
            dictionaryRevision: dictionaryRevision,
            dataPagesCommitted: dataPagesCommitted,
            dataPagesReserved: dataPagesReserved,
            systemHeaderCRCValid: systemHeaderCRCValid,
            indexesCRCValid: indexesCRCValid,
            firstIndexPaddingEmpty: firstIndexPaddingEmpty,
            dataPageOrder: dataPageOrder,
            dataPageHeaderCRCsValid: dataPageHeaderCRCsValid,
            dataPageFooterCRCsValid: dataPageFooterCRCsValid,
            matchesMFSDictionary: mfsDictionary.map { Int(dictionary) == $0 })
    }

    // MARK: - little-endian reads (bounds-checked, nil when out of range)

    private static func u16(_ data: Data, at index: Int) -> UInt16? {
        guard index >= 0, index + 2 <= data.count else { return nil }
        return UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }

    private static func u32(_ data: Data, at index: Int) -> UInt32? {
        guard index >= 0, index + 4 <= data.count else { return nil }
        return UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }
}

/// FITC header + content integrity decode (upstream `fitc_anl`, MEA.py 8572 —
/// the structural half; the MFS config-record walk it then runs is a parked
/// FileTable.dat increment). A revision-1 volume carries, in its 0x10-byte
/// `FITC_Header`, two plain CRC-32s: the header's own (over bytes [0x00:0x04]
/// + zeroed [0x04:0x08] + [0x08:0x0C]) and the config data's (over bytes
/// [0x10 : 0x10+DataLength]). Any other revision (CSME 15 TGP alpha layout)
/// carries no checksums: config length comes from the first u32 at +0x04 and
/// the tail past it must be 0xFF padding. Both branches are byte-derived; the
/// config data itself is only named/parsed with FileTable.dat, so it is not
/// decoded here.
enum FITCParser {
    static let headerSize = 0x10         // FITC_Header

    /// Decode the FITC partition occupying `region[offset ..< offset+size]`.
    /// Returns nil when the area is too small to hold a header.
    static func parse(in region: Data, offset: Int, size: Int,
                      absoluteOffset: Int) -> OEMConfiguration? {
        guard offset >= 0, size >= headerSize, offset + size <= region.count else { return nil }
        let buffer = region.subdata(in: offset..<(offset + size))

        var result = OEMConfiguration(
            offset: absoluteOffset,
            headerRevision: FITCParser.u32(buffer, at: 0x00) ?? 0,
            dataLength: nil, headerCRCStored: nil, headerCRCValid: nil,
            dataCRCStored: nil, dataCRCValid: nil,
            configLength: nil, paddingAllFF: nil)

        if result.headerRevision == 1 {
            // Header CRC-32 span is the first 0x0C bytes with HeaderChecksum
            // zeroed (upstream fitc_hdr_data); data CRC over the config payload.
            let dataLength = Int(FITCParser.u32(buffer, at: 0x08) ?? 0)
            result.dataLength = dataLength
            result.headerCRCStored = FITCParser.u32(buffer, at: 0x04)

            var headerSpan = Data()
            headerSpan.append(buffer[0x00..<0x04])
            headerSpan.append(Data(repeating: 0, count: 4))
            headerSpan.append(buffer[0x08..<0x0C])
            if let stored = result.headerCRCStored {
                result.headerCRCValid = CRC32.crc32(headerSpan) == stored
            }

            if dataLength >= 0, headerSize + dataLength <= buffer.count {
                result.dataCRCStored = FITCParser.u32(buffer, at: 0x0C)
                let payload = buffer[headerSize..<(headerSize + dataLength)]
                if let stored = result.dataCRCStored {
                    result.dataCRCValid = CRC32.crc32(payload) == stored
                }
            }
        } else {
            // Non-revision-1: config length at +0x00, config at +0x04, and the
            // region past the config is padding that must be all 0xFF.
            let configLength = Int(FITCParser.u32(buffer, at: 0x00) ?? 0)
            result.configLength = configLength
            if configLength >= 0, 0x04 + configLength <= buffer.count {
                let padding = buffer[(0x04 + configLength)...]
                var allFF = true
                for byte in padding where byte != 0xFF { allFF = false; break }
                result.paddingAllFF = allFF
            }
        }
        return result
    }

    private static func u32(_ data: Data, at index: Int) -> UInt32? {
        guard index >= 0, index + 4 <= data.count else { return nil }
        return UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }
}
