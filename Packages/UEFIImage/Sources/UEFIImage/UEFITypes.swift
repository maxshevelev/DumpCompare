import Foundation

// GENERATED from `common/types.h` and `common/types.cpp` of
// github.com/LongSoft/UEFITool, branch `new_engine`.
//
// Regenerate with the `update-uefi-types` skill, which re-fetches those two
// files and rewrites this one. Do not edit the tables by hand: the next
// regeneration overwrites them, and a hand edit is a fork from the
// classification the rest of the tool reads from.
//
// What this holds, and why it is a file of its own: the Type and Subtype the
// structure tree shows for a node are UEFITool's, not ours — `Types::ItemTypes`
// and the `*ToUString` lookups — so the tree reads the way UEFITool's does.
// The tables are baked into the build rather than fetched at run time: they
// are small, they are the classification the whole panel leans on, and a
// firmware bench should not need the network to say what a BIOS region is.

/// UEFITool's classification of an image element, mirroring
/// `Types::ItemTypes` and the `itemTypeToUString` / `itemSubtypeToUString` /
/// `regionTypeToUString` lookups in `common/types.cpp`.
public enum UEFITypes {
    // MARK: - `Types::ItemTypes` (types.h)

    /// The item-type codes, `Root = 0x3C` and counting.
    public enum Item: UInt8 {
        case root = 0x3C
        case capsule = 0x3D
        case image = 0x3E
        case region = 0x3F
        case padding = 0x40
        case volume = 0x41
        case file = 0x42
        case section = 0x43
        case freeSpace = 0x44
        case vssStore = 0x45
        case vss2Store = 0x46
        case ftwStore = 0x47
        case fdcStore = 0x48
        case sysFStore = 0x49
        case evsaStore = 0x4A
        case phoenixFlashMapStore = 0x4B
        case insydeFlashDeviceMapStore = 0x4C
        case dellDvarStore = 0x4D
        case cmdbStore = 0x4E
        case nvarGuidStore = 0x4F
        case nvarEntry = 0x50
        case vssEntry = 0x51
        case sysFEntry = 0x52
        case evsaEntry = 0x53
        case phoenixFlashMapEntry = 0x54
        case insydeFlashDeviceMapEntry = 0x55
        case dellDvarEntry = 0x56
        case intelMicrocode = 0x57
        case slicData = 0x58
        case ifwiHeader = 0x59
        case ifwiPartition = 0x5A
        case fptStore = 0x5B
        case fptEntry = 0x5C
        case fptPartition = 0x5D
        case bpdtStore = 0x5E
        case bpdtEntry = 0x5F
        case bpdtPartition = 0x60
        case cpdStore = 0x61
        case cpdEntry = 0x62
        case cpdPartition = 0x63
        case cpdExtension = 0x64
        case cpdSpiEntry = 0x65
        case startupApDataEntry = 0x66
        case directoryTable = 0x67
        case directoryTableEntry = 0x68
        case amdMicrocode = 0x69
    }

    // MARK: - `Subtypes::*` (types.h)

    /// The subtype codes, grouped by the item type that gives them a meaning.
    public enum Sub {
        /// `CapsuleSubtypes`.
        public static let aptioSignedCapsule: UInt8 = 0x64
        public static let aptioUnsignedCapsule: UInt8 = 0x65
        public static let uefiCapsule: UInt8 = 0x66
        public static let toshibaCapsule: UInt8 = 0x67
        /// `CpdPartitionSubtypes`.
        public static let manifestCpdPartition: UInt8 = 0xF0
        public static let metadataCpdPartition: UInt8 = 0xF1
        public static let keyCpdPartition: UInt8 = 0xF2
        public static let codeCpdPartition: UInt8 = 0xF3
        /// `DirectorySubtypes`.
        public static let pspDirectory: UInt8 = 0x9B
        public static let comboDirectory: UInt8 = 0x9C
        public static let biosDirectory: UInt8 = 0x9D
        public static let ishDirectory: UInt8 = 0x9E
        public static let anyDirectory: UInt8 = 0x9F
        /// `DvarEntrySubtypes`.
        public static let invalidDvarEntry: UInt8 = 0xB4
        public static let namespaceGuidDvarEntry: UInt8 = 0xB5
        public static let nameIdDvarEntry: UInt8 = 0xB6
        public static let unknownDvarEntry: UInt8 = 0xB7
        /// `EvsaEntrySubtypes`.
        public static let invalidEvsaEntry: UInt8 = 0xA0
        public static let unknownEvsaEntry: UInt8 = 0xA1
        public static let guidEvsaEntry: UInt8 = 0xA2
        public static let nameEvsaEntry: UInt8 = 0xA3
        public static let dataEvsaEntry: UInt8 = 0xA4
        /// `FlashMapEntrySubtypes`.
        public static let volumeFlashMapEntry: UInt8 = 0xAA
        public static let dataFlashMapEntry: UInt8 = 0xAB
        public static let unknownFlashMapEntry: UInt8 = 0xAC
        /// `FptEntrySubtypes`.
        public static let validFptEntry: UInt8 = 0xDC
        public static let invalidFptEntry: UInt8 = 0xDD
        /// `FptPartitionSubtypes`.
        public static let codeFptPartition: UInt8 = 0xE6
        public static let dataFptPartition: UInt8 = 0xE7
        public static let glutFptPartition: UInt8 = 0xE8
        /// `IfwiPartitionSubtypes`.
        public static let dataIfwiPartition: UInt8 = 0xD2
        public static let bootIfwiPartition: UInt8 = 0xD3
        /// `ImageSubtypes`.
        public static let intelImage: UInt8 = 0x5A
        public static let uefiImage: UInt8 = 0x5B
        public static let amdImage: UInt8 = 0x5C
        /// `MicrocodeSubtypes`.
        public static let intelMicrocode: UInt8 = 0xBE
        public static let amdMicrocode: UInt8 = 0xBF
        /// `NvarEntrySubtypes`.
        public static let invalidNvarEntry: UInt8 = 0x82
        public static let invalidLinkNvarEntry: UInt8 = 0x83
        public static let linkNvarEntry: UInt8 = 0x84
        public static let dataNvarEntry: UInt8 = 0x85
        public static let fullNvarEntry: UInt8 = 0x86
        /// `PaddingSubtypes`.
        public static let zeroPadding: UInt8 = 0x78
        public static let onePadding: UInt8 = 0x79
        public static let dataPadding: UInt8 = 0x7A
        /// `RegionSubtypes`.
        public static let descriptorRegion: UInt8 = 0x00
        public static let biosRegion: UInt8 = 0x01
        public static let meRegion: UInt8 = 0x02
        public static let gbeRegion: UInt8 = 0x03
        public static let pdrRegion: UInt8 = 0x04
        public static let devExp1Region: UInt8 = 0x05
        public static let bios2Region: UInt8 = 0x06
        public static let microcodeRegion: UInt8 = 0x07
        public static let ecRegion: UInt8 = 0x08
        public static let devExp2Region: UInt8 = 0x09
        public static let ieRegion: UInt8 = 0x0A
        public static let tgbe1Region: UInt8 = 0x0B
        public static let tgbe2Region: UInt8 = 0x0C
        public static let reserved1Region: UInt8 = 0x0D
        public static let reserved2Region: UInt8 = 0x0E
        public static let pttRegion: UInt8 = 0x0F
        public static let pspL1DirectoryRegion: UInt8 = 0x10
        public static let pspL2DirectoryRegion: UInt8 = 0x11
        public static let pspDirectoryFile: UInt8 = 0x12
        /// `SlicDataSubtypes`.
        public static let pubkeySlicData: UInt8 = 0xC8
        public static let markerSlicData: UInt8 = 0xC9
        /// `StartupApDataEntrySubtypes`.
        public static let x86128kStartupApDataEntry: UInt8 = 0xFA
        /// `SysFEntrySubtypes`.
        public static let invalidSysFEntry: UInt8 = 0x96
        public static let normalSysFEntry: UInt8 = 0x97
        /// `VolumeSubtypes`.
        public static let unknownVolume: UInt8 = 0x6E
        public static let ffs2Volume: UInt8 = 0x6F
        public static let ffs3Volume: UInt8 = 0x70
        public static let nvramVolume: UInt8 = 0x71
        public static let appleMicrocodeVolume: UInt8 = 0x72
        /// `VssEntrySubtypes`.
        public static let invalidVssEntry: UInt8 = 0x8C
        public static let standardVssEntry: UInt8 = 0x8D
        public static let appleVssEntry: UInt8 = 0x8E
        public static let authVssEntry: UInt8 = 0x8F
        public static let intelVssEntry: UInt8 = 0x90
    }

    // MARK: - Lookups

    /// The word for an item-type code. An unknown code keeps its number.
    public static func typeName(_ type: UInt8) -> String {
        typeNames[Int(type)] ?? String(format: "Unknown %02Xh", type)
    }

    /// The word for a flash-descriptor region type. Unknown keeps its number.
    public static func regionName(_ type: UInt8) -> String {
        regionNames[Int(type)] ?? String(format: "Unknown %02Xh", type)
    }

    /// The word for a subtype, given the item type that owns it. Nil where
    /// the type has no named subtypes — `File` and `Section` delegate to the
    /// FFS and section type tables, which a caller names itself.
    public static func subtypeName(type: UInt8, _ subtype: UInt8) -> String? {
        subtypeNames[Int(type)]?[Int(subtype)]
    }

    // MARK: - The tables

    /// `itemTypeToUString`, transcribed.
    private static let typeNames: [Int: String] =
        [
        0x3C: "Root",
        0x3D: "Capsule",
        0x3E: "Image",
        0x3F: "Region",
        0x40: "Padding",
        0x41: "Volume",
        0x42: "File",
        0x43: "Section",
        0x44: "Free space",
        0x45: "VSS store",
        0x46: "VSS2 store",
        0x47: "FTW store",
        0x48: "FDC store",
        0x49: "SysF store",
        0x4A: "EVSA store",
        0x4B: "FlashMap store",
        0x4C: "FlashDeviceMap store",
        0x4D: "DVAR store",
        0x4E: "CMDB store",
        0x4F: "NVAR GUID store",
        0x50: "NVAR entry",
        0x51: "VSS entry",
        0x52: "SysF entry",
        0x53: "EVSA entry",
        0x54: "FlashMap entry",
        0x55: "FlashDeviceMap entry",
        0x56: "DVAR entry",
        0x57: "Intel microcode",
        0x58: "SLIC data",
        0x59: "IFWI header",
        0x5A: "IFWI partition",
        0x5B: "FPT store",
        0x5C: "FPT entry",
        0x5D: "FPT partition",
        0x5E: "BPDT store",
        0x5F: "BPDT entry",
        0x60: "BPDT partition",
        0x61: "CPD store",
        0x62: "CPD entry",
        0x63: "CPD partition",
        0x64: "CPD extension",
        0x65: "CPD SPI entry",
        0x66: "Startup AP data",
        0x67: "Table",
        0x68: "Table entry",
        0x69: "AMD microcode",
    ]

    /// `regionTypeToUString`, transcribed: the flash-descriptor region type.
    private static let regionNames: [Int: String] =
        [
        0x00: "Descriptor",
        0x01: "BIOS",
        0x02: "ME",
        0x03: "GbE",
        0x04: "PDR",
        0x05: "DevExp1",
        0x06: "BIOS2",
        0x07: "Microcode",
        0x08: "EC",
        0x09: "DevExp2",
        0x0A: "IE",
        0x0B: "10GbE1",
        0x0C: "10GbE2",
        0x0D: "Reserved1",
        0x0E: "Reserved2",
        0x0F: "PTT",
        0x10: "PSP directory",
        0x11: "PSP L2 directory",
        0x12: "PSP file",
    ]

    /// `itemSubtypeToUString`, transcribed and keyed by item type. Region is
    /// folded in from `regionTypeToUString`; File and Section are absent on
    /// purpose, named by the FFS and section type tables at run time.
    private static let subtypeNames: [Int: [Int: String]] =
        [
        0x3D: [0x64: "Aptio signed", 0x65: "Aptio unsigned", 0x66: "UEFI 2.0", 0x67: "Toshiba"],
        0x3E: [0x5A: "Intel", 0x5B: "UEFI", 0x5C: "AMD"],
        0x3F: [0x00: "Descriptor", 0x01: "BIOS", 0x02: "ME", 0x03: "GbE", 0x04: "PDR", 0x05: "DevExp1", 0x06: "BIOS2", 0x07: "Microcode", 0x08: "EC", 0x09: "DevExp2", 0x0A: "IE", 0x0B: "10GbE1", 0x0C: "10GbE2", 0x0D: "Reserved1", 0x0E: "Reserved2", 0x0F: "PTT", 0x10: "PSP directory", 0x11: "PSP L2 directory", 0x12: "PSP file"],
        0x40: [0x78: "Empty (00h)", 0x79: "Empty (FFh)", 0x7A: "Non-empty"],
        0x41: [0x6E: "Unknown", 0x6F: "FFSv2", 0x70: "FFSv3", 0x71: "NVRAM", 0x72: "Apple microcode"],
        0x50: [0x82: "Invalid", 0x83: "Invalid link", 0x84: "Link", 0x85: "Data", 0x86: "Full"],
        0x51: [0x8C: "Invalid", 0x8D: "Standard", 0x8E: "Apple", 0x8F: "Auth", 0x90: "Intel"],
        0x52: [0x96: "Invalid", 0x97: "Normal"],
        0x53: [0xA0: "Invalid", 0xA1: "Unknown", 0xA2: "GUID", 0xA3: "Name", 0xA4: "Data"],
        0x54: [0xAA: "Volume", 0xAB: "Data", 0xAC: "Unknown"],
        0x56: [0xB4: "Invalid", 0xB5: "NamespaceGuid", 0xB6: "NameId", 0xB7: "Unknown"],
        0x5A: [0xD2: "Data", 0xD3: "Boot"],
        0x5C: [0xDC: "Valid", 0xDD: "Invalid"],
        0x5D: [0xE6: "Code", 0xE7: "Data", 0xE8: "GLUT"],
        0x63: [0xF0: "Manifest", 0xF1: "Metadata", 0xF2: "Key", 0xF3: "Code"],
        0x66: [0xFA: "X86 128K"],
        0x67: [0x9B: "PSP table", 0x9C: "Combo table", 0x9D: "BIOS table", 0x9E: "ISH table"],
        0x68: [0x9B: "PSP directory", 0x9C: "Combo directory", 0x9D: "BIOS directory"],
    ]
}
