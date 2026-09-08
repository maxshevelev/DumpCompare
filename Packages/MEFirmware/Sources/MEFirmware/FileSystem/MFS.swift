import Foundation

/// CSE MFS (CSME "Management"/Flash File System) — a faithful structural port of
/// upstream `mfs_anl` (MEA.py 7499): the page inventory, the system-area chunk
/// assembly (CRC-16/14 reverse de-obfuscation), the volume header + FAT read and
/// the low-level *file* walk that follows them.
///
/// An MFS volume is a paged flash area: `pageSize`-byte pages, each starting
/// with a `MFS_Page_Header` (tag `0xAA557887` = bytes `87 78 55 AA`). Pages whose
/// `FirstChunkIndex == 0` are *System* pages, the rest *Data* pages; their 0x40-
/// byte payload chunks (plus a 2-byte CRC-16) are scattered for wear levelling.
/// The System pages' chunk indexes are stored obfuscated and must be recovered
/// with the reverse `Crc16_14` transform; the *logical* volume header lives in
/// assembled System chunk index 0 (signature `0x724F6201`). A raw `MFS` region
/// is present in both real dumps — CSME 12.0.3 (`DATMAAMBAC0.BIN` @0x7000: 49
/// pages, 512 file records, 210 used, FTBL dict 1/0/0 → `usesFTBL` false) and
/// CSME 15.0.30 (`1.bin`: 49 pages, 1024 records, 136 used, dict 0x0A/0x04 →
/// `usesFTBL` true) — both byte-verified.
///
/// The **low-level file walk** (upstream 7849–7884) reads the FAT as two u16
/// arrays over the assembled System area: the first `FileRecordCount` values are
/// the file records (0x0000 unused / 0xFFFE erased / 0xFFFF used-but-empty), each
/// used record holding the *first data-FAT slot* of its file; the values that
/// follow chain chunk to chunk (data-FAT slot `f` ≥ `FileRecordCount` maps to
/// data chunk `SystemChunkCount + f − FileRecordCount`) until a small value
/// `1…0x40` marks EOF and gives the final chunk's used byte count. Each present
/// file is therefore its chain of raw data chunks, assembled in order. The
/// reserved roles upstream prints by index (0–9: Anti-Replay, SVN Migration,
/// Quota Storage, Intel/OEM Configuration, Manifest Backup — `mfs_dict`, MEA.py
/// 10859) select the decode over that content: the legacy (non-FTBL) Intel/OEM
/// Configuration record streams (`mfs_cfg_anl` / `MFS_Config_Record_0x1C`) are
/// decoded here; the FTBL 0xC naming (FileTable.dat), the file-8 Home Directory
/// records and the per-file Integrity tables are later increments.
struct MFSVolumeInfo {
    var pageSize: Int
    var systemPageCount: Int
    var dataPageCount: Int
    var volumeSignatureValid: Bool
    var volumeSize: Int                 // declared VolumeSize (system + data)
    var computedVolumeSize: Int         // system+data chunk payload area
    var fileRecordCount: Int
    var usedFileCount: Int              // FAT: file records whose 1st-chunk ≠ unused
    var ftblDictionary: Int             // 1 when FTBL/EFST unused (the "Revision" case)
    var ftblPlatform: Int
    var ftblReserved: Int
    var usesFTBL: Bool                  // not (dict,plat,reserved) == (1,0,0)
    var files: [MFSLowLevelFile]        // present (non-empty) records, by index
    var fileChainsIntact: Bool          // every used chain hit a clean EOF marker
    var configurations: [MFSConfigDecode]  // legacy MFS only: decoded low-level
                                           // files 6/7 (Intel/OEM Configuration)
}

/// One present low-level MFS file (upstream 7849–7877): the raw bytes of its
/// FAT chain. `content` is nil for unused/erased/empty records — those are not
/// listed in `MFSVolumeInfo.files`.
struct MFSLowLevelFile {
    var index: Int
    var content: Data
}

/// A decoded legacy MFS Configuration stream (upstream `mfs_cfg_anl` MEA.py
/// 8467 over `MFS_Config_Record_0x1C`, MEA.py 1319). A config low-level file
/// (6 = Intel Configuration, 7 = OEM Configuration) begins with a u32 record
/// count then that many 0x1C records — a flat, ordered list whose *folder*
/// entries nest by name and pop back out on a ".." entry. File entries carry a
/// size and an offset into the owning low-level file where their content lives.
struct MFSConfigDecode {
    var owningFile: Int        // 6 = Intel Configuration, 7 = OEM Configuration
    var records: [MFSRawConfigRecord]
}

/// One decoded `MFS_Config_Record_0x1C`. (Distinct from the public Codable
/// `MFSConfigRecord` the analyzer maps this into.)
struct MFSRawConfigRecord {
    var name: String             // FileName (folders may be "..")
    var isFolder: Bool           // AccessMode.RecordType: 0 File, 1 Folder
    var size: Int                // FileSize (0 for folder entries)
    var offset: Int              // FileOffset into the owning low-level file
    var unixRights: Int          // AccessMode.UnixRights (9-bit)
    var integrity: Bool          // AccessMode.Integrity
    var encryption: Bool         // AccessMode.Encryption
    var antiReplay: Bool         // AccessMode.AntiReplay
    var oemConfigurable: Bool    // DeployOptions bit0
    var mcaConfigurable: Bool    // DeployOptions bit1
    var reserved: Int            // Reserved
    var ownerUserID: Int
    var ownerGroupID: Int
}

enum MFSParser {
    static let pageSize = 0x2000
    static let pageHeaderSize = 0x12
    static let chunkAllSize = 0x42
    static let chunkRawSize = 0x40
    static let systemIndexSize = 2
    static let dataIndexSize = 1
    static let volumeHeaderSize = 0xE
    static let pageTag: UInt32 = 0xAA55_7887          // MFS Page Header signature
    static let volumeTag: UInt32 = 0x724F_6201        // assembled System chunk 0

    /// Parse the MFS volume occupying `region[offset ..< offset+size]`. Returns
    /// nil when the area carries no MFS pages at all (upstream's "unrecognizable
    /// format" skip). A volume whose page tag is present but whose assembled
    /// System chunk 0 is not the expected volume header is reported with
    /// `volumeSignatureValid == false` rather than failing.
    static func parse(in region: Data, offset: Int, size: Int) -> MFSVolumeInfo? {
        guard offset >= 0, size >= pageSize, offset + size <= region.count else { return nil }
        let buffer = region.subdata(in: offset..<(offset + size))

        let pageCount = buffer.count / pageSize
        guard pageCount >= 1 else { return nil }

        // ——— Page inventory: collect System pages (by logical PageNumber) and
        // Data pages (by FirstChunkIndex). Other tags are Scratch pages.
        var systemPages: [(page: Int, number: Int)] = []
        var dataPages: [(page: Int, firstChunk: Int)] = []
        var systemChunkCountTarget = 0xFFFF  // first Data chunk index ⇒ System area size
        for page in 0..<pageCount {
            let base = page * pageSize
            let tag = readUInt32(buffer, at: base)
            guard tag == pageTag else { continue }          // Scratch / erased page
            let firstChunk = Int(readUInt16(buffer, at: base + 0x0E))
            let pageNumber = Int(readUInt32(buffer, at: base + 0x04))
            if firstChunk == 0 {
                systemPages.append((page, pageNumber))
            } else {
                dataPages.append((page, firstChunk))
                systemChunkCountTarget = min(systemChunkCountTarget, firstChunk)
            }
        }
        guard !systemPages.isEmpty || !dataPages.isEmpty else { return nil }

        systemPages.sort { $0.number < $1.number }
        dataPages.sort { $0.firstChunk < $1.firstChunk }

        // ——— Assemble the System chunk area. Indexes are 14-bit de-obfuscated
        // per System page (upstream resets the running value each page).
        let systemChunkCount = (pageSize - pageHeaderSize - systemIndexSize)
            / (systemIndexSize + chunkAllSize)
        let systemIndexSizeTotal = systemChunkCount * systemIndexSize + systemIndexSize
        var chunks: [Int: Data] = [:]
        for (page, _) in systemPages {
            let base = page * pageSize
            var running: UInt16 = 0
            var used: [Int] = []
            for i in 0...systemChunkCount {          // chunk_count + 1 index entries
                let value = readUInt16(buffer, at: base + pageHeaderSize + i * systemIndexSize)
                if value & 0xC000 != 0 { break }     // unused entry
                running = CRC16_14.transform(running) ^ value
                used.append(Int(running))
            }
            let chunkStart = pageHeaderSize + systemIndexSizeTotal
            for (slot, index) in used.enumerated() {
                let at = base + chunkStart + slot * chunkAllSize
                guard at + chunkRawSize <= base + pageSize else { break }
                chunks[index] = buffer.subdata(in: at..<(at + chunkRawSize))
            }
        }

        // ——— Data pages contribute the file payload chunks (a 1-byte index:
        // 0x00 used, 0xFF unused), but the volume facts below only need the
        // System area; still fill so sizes are honest.
        let dataChunkCount = (pageSize - pageHeaderSize) / (dataIndexSize + chunkAllSize)
        let dataIndexSizeTotal = dataChunkCount * dataIndexSize
        for (page, firstChunk) in dataPages {
            let base = page * pageSize
            let chunkStart = pageHeaderSize + dataIndexSizeTotal
            for slot in 0..<dataChunkCount {
                let indexByte = buffer[base + pageHeaderSize + slot]
                guard indexByte == 0 else { continue }
                let at = base + chunkStart + slot * chunkAllSize
                guard at + chunkRawSize <= base + pageSize else { break }
                chunks[firstChunk + slot] = buffer.subdata(in: at..<(at + chunkRawSize))
            }
        }

        // The logical System area is System chunk 0..<systemChunkCount laid
        // contiguously (unused chunks are all-zero); the volume header is chunk
        // 0. Its declared size bounds the FAT read below.
        let maxDataChunks = dataPages.count * dataChunkCount
        var effectiveSystemChunkCount = systemChunkCountTarget
        if effectiveSystemChunkCount == 0xFFFF {
            effectiveSystemChunkCount = (chunks.keys.max() ?? -1) + 1   // no Data page
        }
        let systemAreaSize = effectiveSystemChunkCount * chunkRawSize

        var info = MFSVolumeInfo(pageSize: pageSize,
                                 systemPageCount: systemPages.count,
                                 dataPageCount: dataPages.count,
                                 volumeSignatureValid: false,
                                 volumeSize: 0,
                                 computedVolumeSize: systemAreaSize + maxDataChunks * chunkRawSize,
                                 fileRecordCount: 0,
                                 usedFileCount: 0,
                                 ftblDictionary: 0,
                                 ftblPlatform: 0,
                                 ftblReserved: 0,
                                 usesFTBL: false,
                                 files: [],
                                 fileChainsIntact: true,
                                 configurations: [])

        guard let volume = chunks[0], volume.count >= volumeHeaderSize else {
            return info                       // no System chunk 0 ⇒ signature invalid
        }
        let signature = readUInt32(volume, at: 0)
        info.volumeSignatureValid = signature == volumeTag
        guard info.volumeSignatureValid else { return info }

        info.ftblDictionary = Int(volume[4])
        info.ftblPlatform = Int(volume[5])
        info.ftblReserved = Int(readUInt16(volume, at: 6))
        info.usesFTBL = !(info.ftblDictionary == 1 && info.ftblPlatform == 0
            && info.ftblReserved == 0)
        info.volumeSize = Int(readUInt32(volume, at: 8))
        info.fileRecordCount = Int(readUInt16(volume, at: 12))

        // ——— File Allocation Table: `fileRecordCount` volume entries (each a
        // low-level file's first Data-FAT slot, or an empty marker) follow the
        // volume header inside the System area, two bytes each, then one slot
        // per Data chunk of the whole volume. Read through the sparse chunk
        // map (a byte at System-area offset `f` lives in chunk f / 0x40 at
        // f % 0x40; absent chunks read as 0x00).
        if info.fileRecordCount > 0,
           volumeHeaderSize + info.fileRecordCount * 2 <= systemAreaSize {
            var used = 0
            for record in 0..<info.fileRecordCount {
                let areaOffset = volumeHeaderSize + record * 2
                let value = readSystemAreaUInt16(chunks, at: areaOffset)
                if value != 0x0000, value != 0xFFFE, value != 0xFFFF { used += 1 }
            }
            info.usedFileCount = used
        }

        // ——— Low-level file walk (upstream 7849–7884): every *used* file record
        // holds the first Data-FAT slot of its file; the slots that follow chain
        // chunk to chunk (Data slot `f` ≥ FileRecordCount maps to Data chunk
        // `SystemChunkCount + f − FileRecordCount`) until a small value 1…0x40
        // marks EOF and gives the final chunk's used byte count. Assembled in
        // order, that is the file's raw content. A chain that runs out of the
        // FAT / chunk area (corrupt volume) ends with what it has and clears
        // `fileChainsIntact`, mirroring upstream's error-and-continue.
        if info.fileRecordCount > 0 {
            let dataPageEstimate = max(0, pageCount - pageCount / 12 - 1)
            let maxDataChunks = dataPageEstimate * dataChunkCount
            func fatValue(_ slot: Int) -> UInt16 {
                guard slot >= 0 else { return 0 }
                let areaOffset = volumeHeaderSize + slot * 2
                guard areaOffset + 2 <= systemAreaSize else { return 0 }
                return readSystemAreaUInt16(chunks, at: areaOffset)
            }
            var files: [MFSLowLevelFile] = []
            var intact = true
            for record in 0..<info.fileRecordCount {
                var value = fatValue(record)
                if value == 0x0000 || value == 0xFFFE || value == 0xFFFF { continue }
                var body = Data()
                var steps = 0
                while true {
                    // A file chain can never visit more distinct Data chunks than
                    // exist, so bound the walk (a cyclic/corrupt FAT upstream would
                    // spin on; the engine must not).
                    steps += 1
                    if steps > maxDataChunks + 1 {
                        intact = false
                        break
                    }
                    if value < info.fileRecordCount {   // points back into the records
                        intact = false
                        break
                    }
                    let dataSlot = Int(value) - info.fileRecordCount
                    guard dataSlot >= 0, dataSlot < maxDataChunks else {
                        intact = false
                        break
                    }
                    let chunkIndex = effectiveSystemChunkCount + dataSlot
                    guard let chunk = chunks[chunkIndex] else {   // missing chunk
                        intact = false
                        break
                    }
                    value = fatValue(Int(value))                  // next slot in the chain
                    if value >= 1 && value <= UInt16(chunkRawSize) {   // EOF marker
                        body.append(chunk.prefix(Int(value)))
                        break
                    }
                    body.append(chunk)
                }
                files.append(MFSLowLevelFile(index: record, content: body))
            }
            info.files = files
            info.fileChainsIntact = intact
        }

        // ——— Legacy Configuration record decode. Only the old-style MFS
        // (usesFTBL == false, CSME ≤ 12) lays out Intel/OEM Configuration
        // (low-level files 6/7) as `MFS_Config_Record_0x1C` streams; the FTBL
        // layout's 0xC records name their files through FileTable.dat (the
        // DB/FileTable increment). Decode whichever of 6/7 the volume carries.
        if !info.usesFTBL {
            var configs: [MFSConfigDecode] = []
            for owner in [6, 7] {
                guard let file = info.files.first(where: { $0.index == owner }),
                      !file.content.isEmpty else { continue }
                if let records = Self.decodeConfigRecords(file.content) {
                    configs.append(MFSConfigDecode(owningFile: owner, records: records))
                }
            }
            info.configurations = configs
        }
        return info
    }

    /// Decode a legacy Configuration record stream: a u32 record count then
    /// that many 0x1C `MFS_Config_Record_0x1C` entries. The count bounds the
    /// walk; a stream shorter than the declared table decodes the complete
    /// records that fit and stops (mirroring upstream error-and-continue).
    static func decodeConfigRecords(_ content: Data) -> [MFSRawConfigRecord]? {
        guard content.count >= 4 else { return nil }
        let count = Int(readUInt32(content, at: 0))
        var records: [MFSRawConfigRecord] = []
        for i in 0..<count {
            let base = 4 + i * 0x1C
            guard base + 0x1C <= content.count else { break }
            let nameBytes = content.subdata(in: base..<(base + 12))
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            let accessMode = readUInt16(content, at: base + 0x0E)
            let deployOptions = readUInt16(content, at: base + 0x10)
            records.append(MFSRawConfigRecord(
                name: name,
                isFolder: accessMode & (1 << 12) != 0,      // RecordType
                size: Int(readUInt16(content, at: base + 0x12)),
                offset: Int(readUInt32(content, at: base + 0x18)),
                unixRights: Int(accessMode & 0x1FF),
                integrity: accessMode & (1 << 9) != 0,
                encryption: accessMode & (1 << 10) != 0,
                antiReplay: accessMode & (1 << 11) != 0,
                oemConfigurable: deployOptions & 1 != 0,
                mcaConfigurable: deployOptions & (1 << 1) != 0,
                reserved: Int(readUInt16(content, at: base + 0x0C)),
                ownerUserID: Int(readUInt16(content, at: base + 0x14)),
                ownerGroupID: Int(readUInt16(content, at: base + 0x16))))
        }
        return records
    }

    /// A little-endian UInt16 at logical System-area offset `areaOffset`,
    /// resolved through the sparse chunk map.
    private static func readSystemAreaUInt16(_ chunks: [Int: Data],
                                             at areaOffset: Int) -> UInt16 {
        var value: UInt16 = 0
        for byteSlot in 0..<2 {
            let offset = areaOffset + byteSlot
            let chunkIndex = offset / chunkRawSize
            let inChunk = offset % chunkRawSize
            let byte: UInt8
            if let chunk = chunks[chunkIndex], inChunk < chunk.count {
                byte = chunk[inChunk]
            } else {
                byte = 0
            }
            value |= UInt16(byte) << UInt16(8 * byteSlot)
        }
        return value
    }

    // MARK: - little-endian reads (bounds-checked)

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= data.count else { return 0 }
        return UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }

    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= data.count else { return 0 }
        return UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }
}
