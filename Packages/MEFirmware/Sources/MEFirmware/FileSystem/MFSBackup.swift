import Foundation

/// CSE MFS *backup* area decode — a faithful structural port of the two MFSB
/// branches of upstream `mfs_anl` (MEA.py 7528–7554). A backup area opens with
/// the "MFSB" signature (`0x4D465342`) where a *normal* MFS region opens with
/// the page tag; it is found in an FPT partition literally named "MFSB"
/// (upstream `mfsb_found`, MEA.py 11764) or when a main "MFS" region's first
/// bytes carry the signature (a hot/corrupt volume). Two header revisions:
///
/// - `.r0` (`MFS_Backup_Header_R0`, MEA.py 1713): a 0x20 header whose Reserved
///   bytes [0x8:0x20] are all 0xFF — that check *is* the R0 dispatch. The whole
///   area after the header is one CRC-32 (IV-0 raw) protected body: a compacted
///   MFS image whose erased 0xFF stretches are stored as 0x01030204-terminated
///   chunks, each marker followed by the big-endian length of the 0xFF it stands
///   for. Reconstructing those chunks yields a normal paged MFS volume; the
///   model reports whether that image re-parses (`reconstructedVolumeParses`).
///   The restored *volume* decode itself is the parked restore/repair-writer
///   increment — this decoder stops at the backup facts.
/// - `.r1` (`MFS_Backup_Header_R1`, MEA.py 1734): a 0x24 header whose plain
///   CRC-32 (HeaderCRC32 zeroed) covers bytes [0x0:0x8] + [0xC:Entry6Offset].
///   It locates three low-level-file blobs — 6 Intel Configuration @+0xC,
///   9 Manifest Backup @+0x14, 7 OEM Configuration @+0x1C — each opened by a
///   0x10 `MFS_Backup_Entry` (Revision 1, EntryCRC32, Size, DataCRC32) followed
///   by the file data; both entry header and data carry a plain CRC-32.
///
/// Naming the low-level-file roles (Intel/OEM Configuration, Manifest Backup) by
/// index is upstream's own fixed `mfs_dict`, not a DB table, so the numeric
/// `fileIndex` facts need no FileTable.dat. No real dump in the engine's oracle
/// set carries an MFSB area (all carry a *normal* MFS partition), so this
/// decoder is exercised by fixtures — `swift test` is its oracle.
enum MFSBackupDecoder {

    static let signature: UInt32 = 0x4D46_5342    // "MFSB"
    static let r0HeaderSize = 0x20
    static let r1HeaderSize = 0x24
    static let pageSize = 0x2000                   // MFS page size (alignment)
    static let chunkMarker = Data([0x01, 0x03, 0x02, 0x04])

    /// Decode the MFS backup area occupying `region[offset ..< offset+size]`.
    /// `absoluteOffset` is the area's position in the analyzed image (reported as
    /// `MFSBackup.offset`). Returns nil when the area does not open with the MFSB
    /// signature (a normal paged MFS volume or an unrecognizable region — both
    /// handled by `MFSParser`), or is too small to hold a backup header.
    static func parse(in region: Data, offset: Int, size: Int,
                      absoluteOffset: Int) -> MFSBackup? {
        guard offset >= 0, size >= r0HeaderSize, offset + size <= region.count else { return nil }
        let buffer = region.subdata(in: offset..<(offset + size))
        guard readUInt32(buffer, at: 0) == signature else { return nil }

        // R0 vs R1 dispatch: the R0 header's Reserved field (6 × u32 @ +0x8) is
        // all 0xFF; any other value means the R1 header (upstream 7525/7528/7554).
        var reservedAllFF = true
        if buffer.count >= 0x20 {
            for i in 0x8..<0x20 where buffer[i] != 0xFF { reservedAllFF = false; break }
        } else {
            reservedAllFF = false
        }

        if reservedAllFF {
            return Self.r0(buffer, absoluteOffset: absoluteOffset)
        }
        return Self.r1(buffer, absoluteOffset: absoluteOffset)
    }

    // MARK: - R0 (`MFS_Backup_Header_R0`)

    private static func r0(_ buffer: Data, absoluteOffset: Int) -> MFSBackup {
        let stored = readUInt32(buffer, at: 0x04) ?? 0
        // Header CRC-32: IV-0 raw register over the whole area after the header
        // (upstream `~Crc32.calc(mfsb_buffer, initvalue=0) & mask` == crc32IV0Raw).
        let body = buffer.subdata(in: r0HeaderSize..<buffer.count)
        let headerCRCValid = CRC32.crc32IV0Raw(body) == stored

        var parses: Bool?
        if body.count >= 4 {
            parses = false
            let reconstructed = Self.reconstructR0Body(body)
            parses = MFSParser.parse(in: reconstructed, offset: 0,
                                     size: reconstructed.count)?.volumeSignatureValid ?? false
        }
        return MFSBackup(offset: absoluteOffset, format: .r0,
                         headerCRCStored: stored, headerCRCValid: headerCRCValid,
                         reservedAllFF: true, reconstructedVolumeParses: parses,
                         headerRevision: nil, headerRevisionValid: nil, entries: [])
    }

    /// Reconstruct the paged MFS image from an R0 backup body (upstream
    /// 7544–7551). Each 0x01030204 chunk ending is followed by a 4-byte
    /// *big-endian* 0xFF padding length whose erased space is reinserted; the
    /// tail past the last marker (or the first 32-byte 0xFF run) is appended
    /// verbatim, then the image is aligned up to the 0x2000 MFS page size.
    static func reconstructR0Body(_ body: Data) -> Data {
        let bodyEnd = Self.firstFFRunStart(in: body, length: 32) ?? body.count
        var out = Data()
        var dataStart = 0
        var cursor = 0
        while let at = Self.firstOccurrence(of: chunkMarker, in: body, from: cursor) {
            var padding = 0
            if at + chunkMarker.count + 4 <= body.count {
                padding = Int(readUInt32BE(body, at: at + chunkMarker.count) ?? 0)
            }
            if at > dataStart {
                out.append(body.subdata(in: dataStart..<at))
            }
            out.append(Data(repeating: 0xFF, count: padding))
            let next = at + chunkMarker.count + 4
            cursor = at + chunkMarker.count      // non-overlapping matches
            dataStart = next
        }
        if dataStart < bodyEnd {
            out.append(body.subdata(in: dataStart..<bodyEnd))
        }
        if !out.isEmpty {
            let remainder = out.count % pageSize
            if remainder != 0 {
                out.append(Data(repeating: 0xFF, count: pageSize - remainder))
            }
        }
        return out
    }

    // MARK: - R1 (`MFS_Backup_Header_R1`)

    private static func r1(_ buffer: Data, absoluteOffset: Int) -> MFSBackup {
        let headerRevision = readUInt32(buffer, at: 0x04) ?? 0
        let headerCRCStored = readUInt32(buffer, at: 0x08) ?? 0

        // Header data length = Entry6Offset; the header CRC-32 covers bytes
        // [0x0:0x8] + zeroed HeaderCRC32 + [0xC:mfsb_len] (upstream 7564–7567).
        var headerLength = Int(readUInt32(buffer, at: 0x0C) ?? 0)
        if headerLength < 0x0C || headerLength > buffer.count { headerLength = buffer.count }
        var headerSpan = Data(buffer[0..<min(0x8, buffer.count)])
        headerSpan.append(Data(repeating: 0, count: 4))
        if headerLength > 0x0C {
            headerSpan.append(buffer[0x0C..<headerLength])
        }
        let headerCRCValid = CRC32.crc32(headerSpan) == headerCRCStored
        let headerRevisionValid = headerRevision == 1

        let entries = [
            Self.entry(buffer, fileIndex: 6, offset: readUInt32(buffer, at: 0x0C),
                       size: readUInt32(buffer, at: 0x10)),
            Self.entry(buffer, fileIndex: 9, offset: readUInt32(buffer, at: 0x14),
                       size: readUInt32(buffer, at: 0x18)),
            Self.entry(buffer, fileIndex: 7, offset: readUInt32(buffer, at: 0x1C),
                       size: readUInt32(buffer, at: 0x20)),
        ]

        return MFSBackup(offset: absoluteOffset, format: .r1,
                         headerCRCStored: headerCRCStored, headerCRCValid: headerCRCValid,
                         reservedAllFF: nil, reconstructedVolumeParses: nil,
                         headerRevision: headerRevision, headerRevisionValid: headerRevisionValid,
                         entries: entries)
    }

    /// Decode one `.r1` blob (`MFS_Backup_Entry` + file data). A blob too short
    /// for the 0x10 entry header, or pointing outside the area, comes back with
    /// every validity flag false rather than failing the whole backup.
    private static func entry(_ buffer: Data, fileIndex: Int,
                              offset o32: UInt32?, size s32: UInt32?) -> MFSBackupEntry {
        let offset = o32.map(Int.init) ?? -1
        let blobSize = s32.map(Int.init) ?? 0
        let hasHeader = offset >= 0 && blobSize >= 0x10
            && offset + 0x10 <= buffer.count

        let revision = hasHeader ? (readUInt32(buffer, at: offset) ?? 0) : 0
        let entryCRCStored = hasHeader ? (readUInt32(buffer, at: offset + 0x04) ?? 0) : 0
        let dataSize = hasHeader ? Int(readUInt32(buffer, at: offset + 0x08) ?? 0) : 0
        let dataCRCStored = hasHeader ? (readUInt32(buffer, at: offset + 0x0C) ?? 0) : 0

        let revisionValid = hasHeader ? revision == 1 : false

        // Entry header CRC-32: Revision + zeroed EntryCRC32 + Size (DataCRC32
        // excluded) — upstream 7594–7597.
        var headerCRCValid = false
        if hasHeader {
            var span = buffer[offset..<(offset + 0x04)]
            span.append(Data(repeating: 0, count: 4))
            span.append(buffer[(offset + 0x08)..<(offset + 0x0C)])
            headerCRCValid = CRC32.crc32(span) == entryCRCStored
        }

        // Entry data CRC-32 over the file data — the bytes past the 0x10 entry
        // header, bounded by the entry's own Size then the blob / area end
        // (upstream file_data = entry_data[0x10 : 0x10 + Size], MEA.py 7605).
        var dataCRCValid = false
        if hasHeader, dataSize >= 0 {
            let available = min(offset + blobSize, buffer.count)
            let dataEnd = min(offset + 0x10 + dataSize, available)
            if dataEnd > offset + 0x10 {
                dataCRCValid = CRC32.crc32(buffer[(offset + 0x10)..<dataEnd]) == dataCRCStored
            }
        }

        return MFSBackupEntry(fileIndex: fileIndex, blobOffset: offset, blobSize: blobSize,
                              revision: revision, revisionValid: revisionValid,
                              headerCRCStored: entryCRCStored, headerCRCValid: headerCRCValid,
                              dataSize: dataSize, dataCRCStored: dataCRCStored,
                              dataCRCValid: dataCRCValid)
    }

    // MARK: - scanning helpers

    /// Start index of the first run of `length` consecutive 0xFF bytes, else nil.
    private static func firstFFRunStart(in data: Data, length: Int) -> Int? {
        guard length > 0 else { return nil }
        var run = 0
        for i in 0..<data.count {
            if data[i] == 0xFF {
                run += 1
                if run >= length { return i - length + 1 }
            } else {
                run = 0
            }
        }
        return nil
    }

    /// Start index of the first occurrence of `needle` in `data` at or after
    /// `from`, else nil.
    private static func firstOccurrence(of needle: Data, in data: Data,
                                        from: Int) -> Int? {
        guard !needle.isEmpty, data.count >= needle.count else { return nil }
        var i = max(0, from)
        while i + needle.count <= data.count {
            var match = true
            for j in 0..<needle.count where data[i + j] != needle[j] {
                match = false
                break
            }
            if match { return i }
            i += 1
        }
        return nil
    }

    // MARK: - endian reads (bounds-checked)

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32? {
        guard index >= 0, index + 4 <= data.count else { return nil }
        return UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }

    private static func readUInt32BE(_ data: Data, at index: Int) -> UInt32? {
        guard index >= 0, index + 4 <= data.count else { return nil }
        return (UInt32(data[index]) << 24)
            | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8)
            | UInt32(data[index + 3])
    }
}
