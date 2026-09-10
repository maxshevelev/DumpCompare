import Foundation
import MEFirmware

/// Deterministic value formatting for the curated tree — the one shared voice
/// behind every label/value pair and hex subtitle. Offsets are bare uppercase
/// hex; sizes carry their decimal byte count; flags/CRCs are width-padded.
enum MEAText {
    // MARK: Hex

    /// `0x`-prefixed, no padding — for offsets and small counts.
    static func hex(_ v: Int) -> String { String(format: "0x%X", v) }
    /// Width-padded to one byte, e.g. an extension tag.
    static func hexByte(_ v: Int) -> String { String(format: "0x%02X", v) }
    /// Width-padded to two bytes, e.g. a BPDT partition type.
    static func hex16(_ v: Int) -> String { String(format: "0x%04X", v) }
    /// Width-padded to four bytes, e.g. a region's flags word.
    static func hex32(_ v: UInt32) -> String { String(format: "0x%08X", v) }

    // MARK: Ranges and sizes

    /// The detail value for a byte offset.
    static func offset(_ v: Int) -> String { hex(v) }
    /// The detail value for a byte count: hex plus the decimal bytes.
    static func size(_ v: Int) -> String { String(format: "0x%X (%d bytes)", v, v) }
    /// The compact row subtitle `0x… · 0x…` (offset · size).
    static func range(_ offset: Int, _ size: Int) -> String {
        "\(hex(offset)) · \(hex(size))"
    }
    /// The file range a row stands for; nil when the size is empty or negative.
    static func rangeValue(_ offset: Int, _ size: Int) -> Range<UInt64>? {
        guard offset >= 0, size > 0 else { return nil }
        return UInt64(offset)..<UInt64(offset + size)
    }
    static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    // MARK: Words

    static func yesNo(_ b: Bool) -> String { b ? "Yes" : "No" }
    static func family(_ f: FirmwareFamily) -> String {
        switch f {
        case .me: return "ME"
        case .csme: return "CSME"
        case .txe: return "TXE"
        case .cstxe: return "CSTXE"
        case .sps: return "SPS"
        case .cssps: return "CSSPS"
        case .gsc: return "GSC"
        case .pmc: return "PMC"
        case .pchc: return "PCHC"
        case .phy: return "PHY"
        case .orom: return "OROM"
        case .unknown: return "Unknown"
        }
    }
    static func manifestFormat(_ f: ManifestFormat) -> String {
        switch f {
        case .r0: return "R0"
        case .r1: return "R1"
        case .r2: return "R2"
        case .unknown: return "Unknown"
        }
    }
    /// First-letter capitalization for one-word enum raw values, with the few
    /// camelCase/uppercase raw values mapped by hand.
    static func title(_ s: String) -> String {
        switch s {
        case "production": return "Production"
        case "preProduction": return "Pre-production"
        case "romBypass": return "ROM Bypass"
        default:
            return s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    // MARK: Structured

    static func version(_ major: Int, _ minor: Int, _ hotfix: Int,
                        _ build: Int) -> String {
        "\(major).\(minor).\(hotfix).\(build)"
    }
    /// The Flash Image Tool (FITC) version a firmware was built with — upstream
    /// `get_fw_ver` (MEA.py 10094), keyed by family. Only the families that
    /// carry a real row-19 FIT on an IFWI image reach this helper: the CSE/TXE/
    /// GSC families format plain `major.minor.hotfix.build`, SPS/CSSPS pad to
    /// `xx.xx.xx.xxx`. The zero-padded PMC/PCHC/PHY *variant*-prefix branches
    /// upstream keys off are not replicated — those families produce no FIT.
    static func firmwareImageTool(family: FirmwareFamily, major: Int, minor: Int,
                                  hotfix: Int, build: Int) -> String {
        switch family {
        case .sps, .cssps:
            return String(format: "%02d.%02d.%02d.%03d", major, minor, hotfix, build)
        default:
            return "\(major).\(minor).\(hotfix).\(build)"
        }
    }
    /// The Manifest Extension Utility version of a manifest's MEU block (row
    /// 20, upstream `mn2_meu_ver`, MEA.py 12229): the build is padded to four
    /// digits, so a `1.4.0.14` MEU reads "1.4.0.0014" exactly as the console
    /// prints it.
    static func manifestExtensionUtility(major: Int, minor: Int, hotfix: Int,
                                         build: Int) -> String {
        String(format: "%d.%d.%d.%04d", major, minor, hotfix, build)
    }
    /// The Chipset Stepping row's letters (row 6c, upstream
    /// `', '.join(list(sku_stp))`): each letter of a stepping record read as
    /// its own stepping, so a firmware recorded as "BA" supports steppings B
    /// and A.
    static func chipsetStepping(_ letters: String) -> String {
        letters.map(String.init).joined(separator: ", ")
    }
    /// The Power Down Mitigation row (row 12a, upstream `pdm_status`). The
    /// unknown answers are the database's own — it recorded that it does not
    /// know — and upstream prints them as they are.
    static func powerDownMitigation(_ value: PowerDownMitigation) -> String {
        switch value {
        case .yes: return "Yes"
        case .no: return "No"
        case .unknown: return "Unknown"
        case .unknown1: return "Unknown 1"
        case .unknown2: return "Unknown 2"
        }
    }
    /// A Downgrade Blacklist row (row 21, upstream `me7_blist_1`/`_2`): the
    /// newest firmware of that ME 7 line the image refuses to be downgraded
    /// to, written as upstream writes it — `<= 7.1.2.1000`. The label of the
    /// row names the line, so the major is always the 7.
    static func downgradeBlacklist(_ entry: Version3) -> String {
        "<= 7.\(entry.minor).\(entry.hotfix).\(entry.build)"
    }
    /// The NVM Compatibility label of the raw two-bit field (row 7, upstream
    /// `ext15_nvm_type`, MEA.py 10536): 0 Undefined, 1 UFS, 2 SPI. The
    /// reserved value keeps upstream's own wording for a number outside the
    /// map, so a future revision's third medium reads as unknown rather than
    /// as one of these two.
    static func nvmCompatibility(_ raw: Int) -> String {
        switch raw {
        case 0: return "Undefined"
        case 1: return "UFS"
        case 2: return "SPI"
        default: return "Unknown (\(raw))"
        }
    }
    static func date(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
    static func date(_ d: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return date(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }
}

extension Version {
    /// The full MEU version (`meMajor.meMinor.meHotfix.meBuild`) when the whole
    /// block is present — nil on a firmware whose version fields are absent.
    var meText: String? {
        guard let meMajor, let meMinor, let meHotfix, let meBuild else { return nil }
        return "\(meMajor).\(meMinor).\(meHotfix).\(meBuild)"
    }
}

/// A field-by-field dump of an *opaque* model structure the curator chose not
/// to hand-map (extension payloads, EFS/OEM fact groups, `$MME` rows): walks
/// the value's stored properties with `Mirror`, flattening nested structs into
/// `label.path` rows and skipping nil / empty values. Leaf formatting reuses
/// `MEAText`, with byte offsets and size-like integers shown as hex/bytes and
/// everything else decimal — the small generic seam of an otherwise curated
/// tree, and the depth where hand-mapping every sub-structure stops paying.
enum MEAValueText {
    /// The dumped rows of `value` (an optional struct or enum), root labels
    /// unprefixed. Empty when the value is nil or carries no leaf fields.
    static func fields(of value: Any) -> [MEAField] {
        var out: [MEAField] = []
        walk(value, path: "", into: &out)
        return out
    }

    private static func walk(_ value: Any, path: String,
                             into out: inout [MEAField]) {
        var subject: Any = value
        var mirror = Mirror(reflecting: subject)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first else { return }
            subject = wrapped.value
            mirror = Mirror(reflecting: subject)
        }

        // Leaves, newest-probed first.
        if let b = subject as? Bool {
            if !path.isEmpty { out.append(MEAField(path, MEAText.yesNo(b))) }
            return
        }
        if let s = subject as? String {
            if !s.isEmpty && !path.isEmpty { out.append(MEAField(path, s)) }
            return
        }
        if let d = subject as? Date {
            if !path.isEmpty { out.append(MEAField(path, MEAText.date(d))) }
            return
        }
        if let n = asInt(subject) {
            if !path.isEmpty { out.append(MEAField(path, numberText(n, path: path))) }
            return
        }

        // Aggregates stop at a count: sub-tables of opaque payloads surface as
        // "N entries" rather than flooding the detail pane (see the curator doc).
        if mirror.displayStyle == .collection || mirror.displayStyle == .set {
            if !path.isEmpty {
                out.append(MEAField(path, "\(mirror.children.count) entries"))
            }
            return
        }

        if mirror.displayStyle == .struct || mirror.displayStyle == .class {
            for child in mirror.children {
                guard let label = child.label else { continue }
                let next = path.isEmpty ? label : "\(path).\(label)"
                walk(child.value, path: next, into: &out)
            }
            return
        }

        // An enum or anything else with a display string (e.g. String-raw
        // enums, whose case names equal their raw values across this model).
        if !path.isEmpty { out.append(MEAField(path, String(describing: subject))) }
    }

    private static func numberText(_ value: Int64, path: String) -> String {
        let l = path.lowercased()
        let isCode = l.contains("offset")
            || l.contains("address")
            || l.contains("crc")
            || l.contains("checksum")
            || l.contains("tag")
            || l.contains("mask")
            || l.hasSuffix("flags")
            || l.hasSuffix(".type") || l == "type"
            || l.contains("deviceid") || l.contains("vendorid")
        if isCode {
            return "0x" + String(value, radix: 16, uppercase: true)
        }
        return String(value)
    }

    private static func asInt(_ value: Any) -> Int64? {
        if let v = value as? Int { return Int64(v) }
        if let v = value as? Int8 { return Int64(v) }
        if let v = value as? Int16 { return Int64(v) }
        if let v = value as? Int32 { return Int64(v) }
        if let v = value as? Int64 { return v }
        if let v = value as? UInt8 { return Int64(v) }
        if let v = value as? UInt16 { return Int64(v) }
        if let v = value as? UInt32 { return Int64(v) }
        if let v = value as? UInt { return Int64(v) }
        if let v = value as? UInt64 { return v <= Int64.max ? Int64(v) : nil }
        return nil
    }
}
