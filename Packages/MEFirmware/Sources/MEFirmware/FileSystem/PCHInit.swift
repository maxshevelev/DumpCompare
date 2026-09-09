import Foundation

/// Chipset Initialization Table decode of a legacy MFS volume's Intel
/// Configuration (low-level file 6), upstream `mphytbl` (MEA.py 8956) +
/// `pch_init_anl` (MEA.py 9097).
///
/// A file-6 Configuration stream (`MFS_Config_Record_0x1C`) lists *file*
/// records whose names begin `mphytbl`. Each such record's content — sliced
/// out of the file-6 bytes by the record's own offset/size, exactly as upstream
/// passes `buffer[rec_offset:rec_offset+rec_size]` — is a chipset init table:
/// its first bytes name the chipset platform, a stepping nibble and an init
/// table revision. Which stepping rule decodes the nibble is chosen by the
/// engine identity (`variant`/`major`/`minor`/`build`) and the manifest date,
/// so this decode runs only after identification. `pch_dict` (MEA.py 10839)
/// and the `pch_stp_val` letter table are compile-time constants.
///
/// Only the *legacy* (non-FTBL) config layout is in scope: upstream calls
/// mphytbl from both the 0x1C and the 0xC (FileTable.dat) config branches, and
/// the latter — like all FTBL naming — is a later increment. A `usesFTBL`
/// volume therefore never decodes here.
enum PCHInitDecoder {

    /// `pch_dict`, MEA.py 10839–10856: chipset-ID byte/nibble → platform label.
    static let platformLabels: [Int: String] = [
        0x0: "LBG-H", 0x3: "ICP-LP", 0x4: "ICP-N", 0x5: "ICP-H",
        0x6: "TGP-LP", 0x7: "TGP/EBG-H", 0x8: "SPT/KBP-LP", 0x9: "SPT-H",
        0xB: "KBP/BSF/GCF-H", 0xC: "CNP/CMP-LP", 0xD: "CNP/CMP-H",
        0xE: "LKF-LP", 0xF: "MCC-LP", 0x10: "JSP-N", 0x11: "EBG-H",
        0x12: "ADP-LP",
    ]

    /// `pch_stp_val`, MEA.py 8957: stepping nibble 0–15 → letter A–P.
    private static let steppingLetters = Array("ABCDEFGHIJKLMNOP").map(String.init)

    /// Decode a volume's Intel Configuration into the Chipset Initialization
    /// Table facts. Returns nil when the volume carries no mphytbl* file
    /// records (upstream's `pch_init_info` stays empty and mphytbl never
    /// fires). `files`/`configurations` are the volume's parsed low-level files
    /// and legacy config decodes; the decoder uses the owning-file-6 config's
    /// file records and slices their content from file 6's own bytes.
    static func decode(files: [MFSLowLevelFile],
                       configurations: [MFSConfigDecode],
                       variant: String, major: Int, minor: Int, build: Int,
                       year: Int, month: Int, day: Int) -> MFSPCHInit? {
        guard let intel = files.first(where: { $0.index == 6 }),
              let config = configurations.first(where: { $0.owningFile == 6 })
        else { return nil }

        var records: [MFSPCHInitRecord] = []
        for record in config.records {
            guard !record.isFolder,
                  record.name.hasPrefix("mphytbl"),
                  record.size > 0, record.offset >= 0,
                  record.offset + record.size <= intel.content.count
            else { continue }
            let table = intel.content.subdata(in: record.offset..<(record.offset + record.size))
            guard let decoded = Self.decodeTable(table, variant: variant,
                                                 major: major, minor: minor,
                                                 build: build, year: year,
                                                 month: month, day: day)
            else { continue }
            records.append(decoded)
        }
        guard !records.isEmpty else { return nil }

        return MFSPCHInit(records: records,
                          chipsets: Self.aggregate(records))
    }

    /// One mphytbl* table → its chipset platform, stepping letters and init
    /// table revision (upstream `mphytbl` MEA.py 8956–9024). Returns nil when
    /// the blob is too short to hold the layout marker and stepping nibble.
    static func decodeTable(_ data: Data, variant: String, major: Int,
                            minor: Int, build: Int, year: Int, month: Int,
                            day: Int) -> MFSPCHInitRecord? {
        // New layout marker: bytes [4:6] both 0xFF (rec_data[0x4:0x6] == FF*2).
        let newLayout = data.count >= 6 && data[4] == 0xFF && data[5] == 0xFF

        // Chipset ID byte/nibble → platform; stepping nibble; table revision.
        let chipsetID: Int
        let rawStep: Int
        let revision: Int
        if newLayout {
            guard data.count >= 9 else { return nil }
            chipsetID = Int(data[7])
            rawStep = Int(data[8]) >> 4
            revision = Int(data[6])
        } else {
            guard data.count >= 4 else { return nil }
            chipsetID = Int(data[3]) >> 4
            rawStep = Int(data[3]) & 0xF
            revision = Int(data[2])
        }

        var chipset = platformLabels[chipsetID] ?? "Unknown"
        var stepping = ""

        // Detect Actual Chipset Stepping(s) — upstream elif order preserved
        // (MEA.py 8969–9021). Absolute letters decode `pch_stp_val[raw]`; the
        // bitfield spells set high→low bits as D,C,B,A (0000 → "A").
        if (variant, major, minor) == ("CSSPS", 4, 4) {
            stepping = Self.absolute(rawStep)
            chipset = "WTL"                       // LBG-H → LBG-R rename
        } else if (variant, major) == ("CSME", 11) || (variant, major) == ("CSSPS", 4) {
            if Self.date(year, month, day) >= Self.date(2015, 5, 19) {
                stepping = Self.absolute(rawStep) // ≥ 11.0.0.1140 @ 2015-05-19
            }
            // else unreliable (always 80 → SPT/KBP-LP A): stays empty
        } else if (variant, major) == ("CSME", 12) || (variant, major) == ("CSSPS", 5) {
            if Self.date(year, month, day) >= Self.date(2018, 1, 25) {
                stepping = Self.bitfield(rawStep) // ≥ 12.0.0.1058 @ 2018-01-25
            } else {
                stepping = Self.absolute(rawStep)
            }
        } else if (variant, major, minor) == ("CSME", 15, 40) {
            if (1000..<7000).contains(build) {
                stepping = Self.steppingLetters[(build / 1000) - 1]
            } else {
                stepping = Self.absolute(rawStep) // fallback
            }
        } else if (variant, major) == ("CSME", 13) || (variant, major) == ("CSME", 15)
                    || (variant, major) == ("CSME", 16) || (variant, major) == ("CSSPS", 6) {
            stepping = newLayout ? Self.absolute(rawStep) : Self.bitfield(rawStep)
        } else if (variant, major, minor) == ("CSME", 14, 5) {
            stepping = Self.absolute(rawStep)
            chipset = "CMP-V"                     // KBP/BSF/GCF-H rename
        } else if (variant, major) == ("CSME", 14) {
            stepping = Self.bitfield(rawStep)
        }

        return MFSPCHInitRecord(chipset: chipset, stepping: stepping,
                                revision: revision)
    }

    /// `pch_init_anl` (MEA.py 9097–9131), minus the trailing display-only total
    /// cell: dedupe chipsets in first-appearance order, concatenate each
    /// chipset's stepping letters across its tables, then sort unique letters
    /// in reverse (e.g. "A"+"CB" → "CBA"). Empty when no table decoded a
    /// stepping (upstream's early return on an empty first row).
    static func aggregate(_ records: [MFSPCHInitRecord]) -> [MFSPCHInitChipset] {
        guard let first = records.first, !first.stepping.isEmpty else { return [] }
        var chipsets: [MFSPCHInitChipset] = []
        var lettersByChipset: [String: String] = [:]
        for record in records {
            if lettersByChipset[record.chipset] == nil {
                chipsets.append(MFSPCHInitChipset(chipset: record.chipset, steppings: ""))
            }
            lettersByChipset[record.chipset, default: ""] += record.stepping
        }
        for index in chipsets.indices {
            let all = lettersByChipset[chipsets[index].chipset] ?? ""
            chipsets[index] = MFSPCHInitChipset(
                chipset: chipsets[index].chipset,
                steppings: String(Set(all).sorted(by: >)))
        }
        return chipsets
    }

    // MARK: - stepping helpers

    private static func absolute(_ rawStep: Int) -> String {
        steppingLetters[rawStep & 0xF]
    }

    private static func bitfield(_ rawStep: Int) -> String {
        var result = ""
        for i in 0..<4 where rawStep & (1 << (3 - i)) != 0 {
            result.append("DCBA"[String.Index(utf16Offset: i, in: "DCBA")])
        }
        return result.isEmpty ? "A" : result
    }

    /// An absolute calendar date as a comparable value (day/month/year are
    /// already decimal BCD-decoded calendar ints; a plain tuple comparison is
    /// chronological, matching upstream's BCD-byte comparison of the header).
    private static func date(_ year: Int, _ month: Int, _ day: Int) -> (Int, Int, Int) {
        (year, month, day)
    }
}
