import Foundation

/// The tables that turn sixteen bytes into a meaning.
///
/// Half of this format is a lookup: a volume's file system, a file's identity,
/// a section's compression algorithm are all GUIDs, and the same GUID means the
/// same thing in every image on earth. Kept in one file because that is how it
/// stays checkable against `Design/UEFI/UEFI_IMAGE_FORMAT.md` — the tables there
/// are the source, and a GUID in the wrong table is a bug no test of ours would
/// otherwise catch.
public enum KnownGUIDs {
    /// A volume's file system decides how its body is read (§3.4). A volume
    /// whose GUID is not here keeps its body whole.
    public static func ffsVersion(ofFileSystem guid: EFIGUID) -> Int? {
        if guid == ffsV1 { return 1 }
        if ffsV2FileSystems.contains(guid) { return 2 }
        if guid == ffsV3 { return 3 }
        return nil
    }

    public static let ffsV1 = guid("7A9354D9-0468-444A-81CE-0BF617D890DF")
    public static let ffsV2 = guid("8C8CE578-8A3D-4F1C-9935-896185C32DD3")
    public static let ffsV3 = guid("5473C07A-3DCB-4DCA-BD6F-1E9689E7349A")

    /// Every GUID vendors use for what is, byte for byte, an FFSv2 volume.
    public static let ffsV2FileSystems: Set<EFIGUID> = [
        ffsV2,
        guid("04ADEEAD-61FF-4D31-B6BA-64F8BF901F5A"),  // Apple immutable
        guid("BD001B8C-6A71-487B-A14F-0C2A2DCF7A5D"),  // Apple authentication
        guid("AD3FFFFF-D28B-44C4-9F13-9EA98A97F9F0"),  // Intel
        guid("D6A1CD70-4B33-4994-A6EA-375F2CCC5437"),  // Intel 2
        guid("4F494156-AED6-4D64-A537-B8A5557BCEEC"),  // Sony
        guid("372B56DF-CC9F-4817-AB97-0A10A92CEAA5")   // HP
    ]

    /// The Volume Top File, which the second pass cannot do without: the last
    /// byte of the last one is mapped at `0xFFFFFFFF`, and that is the only
    /// thing in an image that ties an offset to an address (§5.7).
    public static let volumeTopFile = guid("1BA0062E-C779-4582-8566-336AE8F78F09")

    /// Names for the volumes, files and sections worth naming. Everything else
    /// is shown by its type, which is more useful than a GUID nobody knows.
    public static func name(of guid: EFIGUID) -> String? { names[guid] }

    private static let names: [EFIGUID: String] = [
        ffsV1: "FFSv1",
        ffsV2: "FFSv2",
        ffsV3: "FFSv3",
        guid("04ADEEAD-61FF-4D31-B6BA-64F8BF901F5A"): "Apple immutable FV",
        guid("BD001B8C-6A71-487B-A14F-0C2A2DCF7A5D"): "Apple authentication FV",
        guid("153D2197-29BD-44DC-AC59-887F70E41A6B"): "Apple microcode FV",
        guid("AD3FFFFF-D28B-44C4-9F13-9EA98A97F9F0"): "Intel FS",
        guid("D6A1CD70-4B33-4994-A6EA-375F2CCC5437"): "Intel FS 2",
        guid("4F494156-AED6-4D64-A537-B8A5557BCEEC"): "Sony FS",
        guid("372B56DF-CC9F-4817-AB97-0A10A92CEAA5"): "HP FS",
        guid("FFF12B8D-7696-4C8B-A985-2747075B4F50"): "NVRAM store",
        guid("00504624-8A59-4EEB-BD0F-6B36E96128E0"): "NVRAM additional store",

        volumeTopFile: "Volume Top File",
        guid("D6A2CB7F-6A18-4E2F-B43B-9920A733700A"): "DXE Core",
        guid("5AE3F37E-4EAE-41AE-8240-35465B5E81EB"): "AMI DXE Core",
        guid("1B45CC0A-156A-428A-AF62-49864DA0E6E6"): "PEI apriori",
        guid("FC510EE7-FFDC-11D4-BD41-0080C73C8881"): "DXE apriori",
        guid("E4536585-7909-4A60-B5C6-ECDEA6EBFB54"): "AMI padding file",
        guid("389CC6F2-1EA8-467B-AB8A-78E769AE2A15"): "Phoenix vendor hash file",
        guid("CBC91F44-A4BC-4A5B-8696-703451D0B053"): "AMI vendor hash file",
        guid("20BC8AC9-94D1-4208-AB28-5D673FD73487"): "AMD compressed raw file",
        guid("DE3E049C-A218-4891-8658-5FC0FA84C788"): "AMD microcode"
    ]

    /// A GUID from a specification, which is a constant and not input: a
    /// mistyped table entry is a programming error worth failing on rather than
    /// a value worth carrying as nil.
    static func guid(_ string: String) -> EFIGUID {
        guard let guid = EFIGUID(string) else {
            preconditionFailure("malformed GUID constant: \(string)")
        }
        return guid
    }
}
