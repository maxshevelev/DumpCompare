import Foundation

// GENERATED from `common/nvram.h` and `common/nvram.cpp` of
// github.com/LongSoft/UEFITool, branch `new_engine`.
//
// Regenerate with the `update-nvram-guids` skill, which re-fetches those two
// files and rewrites this one. Do not edit by hand: the next regeneration
// overwrites it.
//
// What this holds, and why it is a file of its own: the NVRAM volume parser
// classifies a store by its GUID — which file-system GUID is an NVRAM store,
// which GUID opens a VSS2 or FTW store — and the structure tree names a
// GUID-identity NVRAM node from here while the downloaded guids.csv has no
// name for it. The bytes are the image-order bytes the C++ source spells out,
// so a GUID that moves upstream follows straight into the parser.

/// The NVRAM GUIDs UEFITool names in `common/nvram.h`, and what they mean.
public enum NvramGuids {

    /// EDKII_WORKING_BLOCK_SIGNATURE_GUID.
    public static let edkiiWorkingBlockSignatureGuid = EFIGUID(bytes: [0x2B, 0x29, 0x58, 0x9E, 0x68, 0x7C, 0x7D, 0x49, 0x0A, 0xCE, 0x65, 0x00, 0xFD, 0x9F, 0x1B, 0x95])

    /// FFS_PHOENIX_RAW_SECTION_EVSA_GUID.
    public static let ffsPhoenixRawSectionEvsaGuid = EFIGUID(bytes: [0x72, 0x85, 0xB7, 0xDA, 0xD1, 0xE8, 0x3F, 0x4C, 0x9A, 0x1E, 0xF2, 0x7E, 0x9C, 0xAF, 0x68, 0x6D])

    /// NVRAM_ADDITIONAL_STORE_VOLUME_GUID.
    public static let nvramAdditionalStoreVolumeGuid = EFIGUID(bytes: [0x24, 0x46, 0x50, 0x00, 0x59, 0x8A, 0xEB, 0x4E, 0xBD, 0x0F, 0x6B, 0x36, 0xE9, 0x61, 0x28, 0xE0])

    /// NVRAM_FDC_STORE_GUID.
    public static let nvramFdcStoreGuid = EFIGUID(bytes: [0x16, 0x36, 0xCF, 0xDD, 0x75, 0x32, 0x64, 0x41, 0x98, 0xB6, 0xFE, 0x85, 0x70, 0x7F, 0xFE, 0x7D])

    /// NVRAM_MAIN_STORE_VOLUME_GUID.
    public static let nvramMainStoreVolumeGuid = EFIGUID(bytes: [0x8D, 0x2B, 0xF1, 0xFF, 0x96, 0x76, 0x8B, 0x4C, 0xA9, 0x85, 0x27, 0x47, 0x07, 0x5B, 0x4F, 0x50])

    /// NVRAM_NVAR_BB_DEFAULTS_FILE_GUID.
    public static let nvramNvarBbDefaultsFileGuid = EFIGUID(bytes: [0x61, 0x63, 0x51, 0xAF, 0xC5, 0xB4, 0x6E, 0x43, 0xA7, 0xE3, 0xA1, 0x49, 0xA3, 0x1B, 0x14, 0x61])

    /// NVRAM_NVAR_EXTERNAL_DEFAULTS_FILE_GUID.
    public static let nvramNvarExternalDefaultsFileGuid = EFIGUID(bytes: [0x5B, 0x31, 0x21, 0x92, 0xBB, 0x30, 0xB5, 0x46, 0x81, 0x3E, 0x1B, 0x1B, 0xF4, 0x71, 0x2B, 0xD3])

    /// NVRAM_NVAR_PEI_EXTERNAL_DEFAULTS_FILE_GUID.
    public static let nvramNvarPeiExternalDefaultsFileGuid = EFIGUID(bytes: [0x50, 0xDC, 0xD3, 0x77, 0x2B, 0xD4, 0x16, 0x49, 0xAC, 0x80, 0x8F, 0x46, 0x90, 0x35, 0xD1, 0x50])

    /// NVRAM_NVAR_STORE_FILE_GUID.
    public static let nvramNvarStoreFileGuid = EFIGUID(bytes: [0xA3, 0xB9, 0xF5, 0xCE, 0x6D, 0x47, 0x7F, 0x49, 0x9F, 0xDC, 0xE9, 0x81, 0x43, 0xE0, 0x42, 0x2C])

    /// NVRAM_PHOENIX_FLASH_MAP_CMDB_GUID.
    public static let nvramPhoenixFlashMapCmdbGuid = EFIGUID(bytes: [0x43, 0x02, 0x31, 0x46, 0x03, 0x7B, 0x32, 0x41, 0xBE, 0x44, 0x22, 0x43, 0xFA, 0xCA, 0x7C, 0xDD])

    /// NVRAM_PHOENIX_FLASH_MAP_EVSA1_GUID.
    public static let nvramPhoenixFlashMapEvsa1Guid = EFIGUID(bytes: [0x10, 0xB1, 0xCF, 0xFA, 0xFD, 0x7B, 0xFB, 0x4E, 0x87, 0x3E, 0x88, 0xB6, 0xB2, 0x3B, 0x97, 0xEA])

    /// NVRAM_PHOENIX_FLASH_MAP_EVSA2_GUID.
    public static let nvramPhoenixFlashMapEvsa2Guid = EFIGUID(bytes: [0x1A, 0xC1, 0x8D, 0xE6, 0xF4, 0xA5, 0xC3, 0x4A, 0xAA, 0x2E, 0x29, 0xE2, 0x98, 0xBF, 0xF6, 0x45])

    /// NVRAM_PHOENIX_FLASH_MAP_EVSA3_GUID.
    public static let nvramPhoenixFlashMapEvsa3Guid = EFIGUID(bytes: [0xAE, 0x28, 0x38, 0x4B, 0xCE, 0x0A, 0xB6, 0x45, 0x8C, 0xDB, 0xDA, 0xFC, 0x28, 0xBB, 0xF8, 0xC5])

    /// NVRAM_PHOENIX_FLASH_MAP_EVSA4_GUID.
    public static let nvramPhoenixFlashMapEvsa4Guid = EFIGUID(bytes: [0x8A, 0x6B, 0x2E, 0xC2, 0x59, 0x81, 0xA3, 0x49, 0xB3, 0x53, 0xE8, 0x4B, 0x79, 0xDF, 0x19, 0xC0])

    /// NVRAM_PHOENIX_FLASH_MAP_EVSA5_GUID.
    public static let nvramPhoenixFlashMapEvsa5Guid = EFIGUID(bytes: [0xB9, 0xFA, 0xB5, 0xB6, 0xC4, 0x75, 0xAE, 0x4A, 0x83, 0x14, 0x7F, 0xFF, 0xA7, 0x15, 0x6E, 0xAA])

    /// NVRAM_PHOENIX_FLASH_MAP_EVSA6_GUID.
    public static let nvramPhoenixFlashMapEvsa6Guid = EFIGUID(bytes: [0x99, 0x96, 0x9B, 0x91, 0xD0, 0x8D, 0x76, 0x43, 0xAA, 0x0B, 0x0E, 0x54, 0xCC, 0xA4, 0x7D, 0x8F])

    /// NVRAM_PHOENIX_FLASH_MAP_EVSA7_GUID.
    public static let nvramPhoenixFlashMapEvsa7Guid = EFIGUID(bytes: [0x52, 0x0A, 0xA9, 0x58, 0x9F, 0x92, 0xF8, 0x44, 0xAC, 0x35, 0xA7, 0xE1, 0xAB, 0x18, 0xAC, 0x91])

    /// NVRAM_PHOENIX_FLASH_MAP_MARKER1_GUID.
    public static let nvramPhoenixFlashMapMarker1Guid = EFIGUID(bytes: [0x4E, 0x1C, 0x7C, 0x12, 0x35, 0x91, 0xE3, 0x46, 0xB0, 0x06, 0xF9, 0x80, 0x8B, 0x05, 0x59, 0xA5])

    /// NVRAM_PHOENIX_FLASH_MAP_MARKER2_GUID.
    public static let nvramPhoenixFlashMapMarker2Guid = EFIGUID(bytes: [0xBE, 0x3D, 0x1A, 0x07, 0xF4, 0xCF, 0x73, 0x4B, 0x83, 0xF0, 0x59, 0x8C, 0x13, 0xDC, 0xFD, 0xD5])

    /// NVRAM_PHOENIX_FLASH_MAP_MICROCODES_GUID.
    public static let nvramPhoenixFlashMapMicrocodesGuid = EFIGUID(bytes: [0x0E, 0x69, 0x3F, 0xFD, 0xB0, 0xB4, 0x68, 0x4D, 0x89, 0xDB, 0x19, 0xA1, 0xA3, 0x31, 0x8F, 0x90])

    /// NVRAM_PHOENIX_FLASH_MAP_PUBKEY1_GUID.
    public static let nvramPhoenixFlashMapPubkey1Guid = EFIGUID(bytes: [0x52, 0x49, 0x2C, 0x1B, 0x78, 0xD7, 0x64, 0x4B, 0xBD, 0xA1, 0x15, 0xA3, 0x6F, 0x5F, 0xA5, 0x45])

    /// NVRAM_PHOENIX_FLASH_MAP_PUBKEY2_GUID.
    public static let nvramPhoenixFlashMapPubkey2Guid = EFIGUID(bytes: [0x14, 0x51, 0xE7, 0x7C, 0x72, 0x82, 0xAF, 0x45, 0xB5, 0x36, 0x76, 0x1B, 0xD3, 0x88, 0x52, 0xCE])

    /// NVRAM_PHOENIX_FLASH_MAP_SELF_GUID.
    public static let nvramPhoenixFlashMapSelfGuid = EFIGUID(bytes: [0x15, 0x19, 0xB7, 0x8C, 0x1F, 0x53, 0xF5, 0x4A, 0x82, 0xBF, 0xA0, 0x91, 0x40, 0x81, 0x7B, 0xAA])

    /// NVRAM_PHOENIX_FLASH_MAP_VOLUME_HEADER.
    public static let nvramPhoenixFlashMapVolumeHeader = EFIGUID(bytes: [0xD2, 0xE7, 0x91, 0xB0, 0xA0, 0x05, 0x98, 0x41, 0x94, 0xF0, 0x74, 0xB7, 0xB8, 0xC5, 0x54, 0x59])

    /// NVRAM_VSS2_AUTH_VAR_KEY_DATABASE_GUID.
    public static let nvramVss2AuthVarKeyDatabaseGuid = EFIGUID(bytes: [0x78, 0x2C, 0xF3, 0xAA, 0x7B, 0x94, 0x9A, 0x43, 0xA1, 0x80, 0x2E, 0x14, 0x4E, 0xC3, 0x77, 0x92])

    /// NVRAM_VSS2_STORE_GUID.
    public static let nvramVss2StoreGuid = EFIGUID(bytes: [0x17, 0x36, 0xCF, 0xDD, 0x75, 0x32, 0x64, 0x41, 0x98, 0xB6, 0xFE, 0x85, 0x70, 0x7F, 0xFE, 0x7D])

    /// VSS2_WORKING_BLOCK_SIGNATURE_GUID.
    public static let vss2WorkingBlockSignatureGuid = EFIGUID(bytes: [0x2B, 0x29, 0x58, 0x9E, 0x68, 0x7C, 0x7D, 0x49, 0xA0, 0xCE, 0x65, 0x00, 0xFD, 0x9F, 0x1B, 0x95])

    /// The word to show for a GUID-identity NVRAM node, when the
    /// downloaded guids.csv catalogue has no name for it.
    public static let names: [EFIGUID: String] =
        [
        edkiiWorkingBlockSignatureGuid: "EDKII working block",
        ffsPhoenixRawSectionEvsaGuid: "FFS PHOENIX raw section EVSA",
        nvramAdditionalStoreVolumeGuid: "NVRAM additional store volume",
        nvramFdcStoreGuid: "NVRAM FDC store",
        nvramMainStoreVolumeGuid: "NVRAM main store volume",
        nvramNvarBbDefaultsFileGuid: "NVRAM NVAR BB defaults file",
        nvramNvarExternalDefaultsFileGuid: "NVRAM NVAR external defaults file",
        nvramNvarPeiExternalDefaultsFileGuid: "NVRAM NVAR PEI external defaults file",
        nvramNvarStoreFileGuid: "NVRAM NVAR store file",
        nvramPhoenixFlashMapCmdbGuid: "NVRAM PHOENIX flash map CMDB",
        nvramPhoenixFlashMapEvsa1Guid: "NVRAM PHOENIX flash map evsa1",
        nvramPhoenixFlashMapEvsa2Guid: "NVRAM PHOENIX flash map evsa2",
        nvramPhoenixFlashMapEvsa3Guid: "NVRAM PHOENIX flash map evsa3",
        nvramPhoenixFlashMapEvsa4Guid: "NVRAM PHOENIX flash map evsa4",
        nvramPhoenixFlashMapEvsa5Guid: "NVRAM PHOENIX flash map evsa5",
        nvramPhoenixFlashMapEvsa6Guid: "NVRAM PHOENIX flash map evsa6",
        nvramPhoenixFlashMapEvsa7Guid: "NVRAM PHOENIX flash map evsa7",
        nvramPhoenixFlashMapMarker1Guid: "NVRAM PHOENIX flash map marker1",
        nvramPhoenixFlashMapMarker2Guid: "NVRAM PHOENIX flash map marker2",
        nvramPhoenixFlashMapMicrocodesGuid: "NVRAM PHOENIX flash map microcodes",
        nvramPhoenixFlashMapPubkey1Guid: "NVRAM PHOENIX flash map pubkey1",
        nvramPhoenixFlashMapPubkey2Guid: "NVRAM PHOENIX flash map pubkey2",
        nvramPhoenixFlashMapSelfGuid: "NVRAM PHOENIX flash map self",
        nvramPhoenixFlashMapVolumeHeader: "NVRAM PHOENIX flash map volume header",
        nvramVss2AuthVarKeyDatabaseGuid: "NVRAM VSS2 auth VAR KEY database",
        nvramVss2StoreGuid: "NVRAM VSS2 store",
        vss2WorkingBlockSignatureGuid: "VSS2 working block",
        ]

    /// The word for a GUID, or nil when it is not one of these.
    public static func name(of guid: EFIGUID) -> String? { names[guid] }

    /// The two file-system GUIDs whose volume body is an NVRAM store.
    public static func isStoreVolume(_ guid: EFIGUID) -> Bool {
        guid == nvramMainStoreVolumeGuid || guid == nvramAdditionalStoreVolumeGuid
    }

    /// A VSS2 store, by the store GUID that leads its 24-byte header.
    public static func isVss2Store(_ guid: EFIGUID) -> Bool {
        guid == nvramVss2StoreGuid || guid == nvramFdcStoreGuid || guid == nvramVss2AuthVarKeyDatabaseGuid
    }

    /// An FTW working block, by the signature GUID that leads its header. The
    /// main store's own GUID doubles as the FTW signature of the block that
    /// protects it.
    public static func isFtwStore(_ guid: EFIGUID) -> Bool {
        guid == nvramMainStoreVolumeGuid
            || guid == edkiiWorkingBlockSignatureGuid
            || guid == vss2WorkingBlockSignatureGuid
    }
}
