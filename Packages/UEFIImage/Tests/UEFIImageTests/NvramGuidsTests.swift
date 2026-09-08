import XCTest
@testable import UEFIImage

/// The NVRAM GUID classifier the volume parser reads. These pin the generated
/// table: a GUID that stops matching its canonical string is a regeneration that
/// drifted from `common/nvram.cpp`, and a classifier that answers wrong routes a
/// store to the wrong parser.
final class NvramGuidsTests: XCTestCase {
    private func guid(_ string: String) -> EFIGUID {
        // Every string here is a well-formed GUID; a failure is a test bug, not
        // an image condition.
        EFIGUID(string)!
    }

    /// Every constant equals the canonical GUID string in `common/nvram.h`. This
    /// is the whole of the drift guard: a byte that changes upstream changes the
    /// string, and the test fails.
    func testEveryConstantMatchesItsCanonicalGuid() {
        XCTAssertEqual(NvramGuids.edkiiWorkingBlockSignatureGuid, guid("9E58292B-7C68-497D-0ACE-6500FD9F1B95"))
        XCTAssertEqual(NvramGuids.ffsPhoenixRawSectionEvsaGuid, guid("DAB78572-E8D1-4C3F-9A1E-F27E9CAF686D"))
        XCTAssertEqual(NvramGuids.nvramAdditionalStoreVolumeGuid, guid("00504624-8A59-4EEB-BD0F-6B36E96128E0"))
        XCTAssertEqual(NvramGuids.nvramFdcStoreGuid, guid("DDCF3616-3275-4164-98B6-FE85707FFE7D"))
        XCTAssertEqual(NvramGuids.nvramMainStoreVolumeGuid, guid("FFF12B8D-7696-4C8B-A985-2747075B4F50"))
        XCTAssertEqual(NvramGuids.nvramNvarBbDefaultsFileGuid, guid("AF516361-B4C5-436E-A7E3-A149A31B1461"))
        XCTAssertEqual(NvramGuids.nvramNvarExternalDefaultsFileGuid, guid("9221315B-30BB-46B5-813E-1B1BF4712BD3"))
        XCTAssertEqual(NvramGuids.nvramNvarPeiExternalDefaultsFileGuid, guid("77D3DC50-D42B-4916-AC80-8F469035D150"))
        XCTAssertEqual(NvramGuids.nvramNvarStoreFileGuid, guid("CEF5B9A3-476D-497F-9FDC-E98143E0422C"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapCmdbGuid, guid("46310243-7B03-4132-BE44-2243FACA7CDD"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapEvsa1Guid, guid("FACFB110-7BFD-4EFB-873E-88B6B23B97EA"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapEvsa2Guid, guid("E68DC11A-A5F4-4AC3-AA2E-29E298BFF645"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapEvsa3Guid, guid("4B3828AE-0ACE-45B6-8CDB-DAFC28BBF8C5"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapEvsa4Guid, guid("C22E6B8A-8159-49A3-B353-E84B79DF19C0"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapEvsa5Guid, guid("B6B5FAB9-75C4-4AAE-8314-7FFFA7156EAA"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapEvsa6Guid, guid("919B9699-8DD0-4376-AA0B-0E54CCA47D8F"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapEvsa7Guid, guid("58A90A52-929F-44F8-AC35-A7E1AB18AC91"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapMarker1Guid, guid("127C1C4E-9135-46E3-B006-F9808B0559A5"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapMarker2Guid, guid("071A3DBE-CFF4-4B73-83F0-598C13DCFDD5"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapMicrocodesGuid, guid("FD3F690E-B4B0-4D68-89DB-19A1A3318F90"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapPubkey1Guid, guid("1B2C4952-D778-4B64-BDA1-15A36F5FA545"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapPubkey2Guid, guid("7CE75114-8272-45AF-B536-761BD38852CE"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapSelfGuid, guid("8CB71915-531F-4AF5-82BF-A09140817BAA"))
        XCTAssertEqual(NvramGuids.nvramPhoenixFlashMapVolumeHeader, guid("B091E7D2-05A0-4198-94F0-74B7B8C55459"))
        XCTAssertEqual(NvramGuids.nvramVss2AuthVarKeyDatabaseGuid, guid("AAF32C78-947B-439A-A180-2E144EC37792"))
        XCTAssertEqual(NvramGuids.nvramVss2StoreGuid, guid("DDCF3617-3275-4164-98B6-FE85707FFE7D"))
        XCTAssertEqual(NvramGuids.vss2WorkingBlockSignatureGuid, guid("9E58292B-7C68-497D-A0CE-6500FD9F1B95"))
    }

    /// The table holds exactly the 27 GUIDs the source names — a count that
    /// drifts means a GUID was added, dropped, or mis-parsed.
    func testTheTableHoldsEveryNamedGuid() {
        XCTAssertEqual(NvramGuids.names.count, 27)
    }

    /// The two file-system GUIDs whose volume body is an NVRAM store.
    func testIsStoreVolumeAnswersForTheTwoStoreGuids() {
        XCTAssertTrue(NvramGuids.isStoreVolume(NvramGuids.nvramMainStoreVolumeGuid))
        XCTAssertTrue(NvramGuids.isStoreVolume(NvramGuids.nvramAdditionalStoreVolumeGuid))
        // A VSS2 store GUID is not a file-system GUID; it opens a store inside one.
        XCTAssertFalse(NvramGuids.isStoreVolume(NvramGuids.nvramVss2StoreGuid))
        XCTAssertFalse(NvramGuids.isStoreVolume(guid("11111111-2222-3333-4444-555555555555")))
    }

    /// A VSS2 store is opened by its store GUID, the FDC variant, or the auth
    /// key database.
    func testIsVss2StoreAnswersForTheVss2Guids() {
        XCTAssertTrue(NvramGuids.isVss2Store(NvramGuids.nvramVss2StoreGuid))
        XCTAssertTrue(NvramGuids.isVss2Store(NvramGuids.nvramFdcStoreGuid))
        XCTAssertTrue(NvramGuids.isVss2Store(NvramGuids.nvramVss2AuthVarKeyDatabaseGuid))
        XCTAssertFalse(NvramGuids.isVss2Store(NvramGuids.nvramMainStoreVolumeGuid))
    }

    /// An FTW working block is opened by the EDKII or VSS2 signature GUID — or
    /// by the main store's own GUID, which doubles as the signature of the
    /// block that protects it.
    func testIsFtwStoreAnswersForTheWorkingBlockGuids() {
        XCTAssertTrue(NvramGuids.isFtwStore(NvramGuids.edkiiWorkingBlockSignatureGuid))
        XCTAssertTrue(NvramGuids.isFtwStore(NvramGuids.vss2WorkingBlockSignatureGuid))
        XCTAssertTrue(NvramGuids.isFtwStore(NvramGuids.nvramMainStoreVolumeGuid))
        XCTAssertFalse(NvramGuids.isFtwStore(NvramGuids.nvramVss2StoreGuid))
    }

    /// The word a GUID-identity NVRAM node shows while the catalogue has no name.
    func testNameAnswersForAGuidAndNilForOneItDoesNotKnow() {
        XCTAssertEqual(NvramGuids.name(of: NvramGuids.nvramMainStoreVolumeGuid), "NVRAM main store volume")
        XCTAssertEqual(NvramGuids.name(of: NvramGuids.nvramVss2StoreGuid), "NVRAM VSS2 store")
        XCTAssertNil(NvramGuids.name(of: guid("11111111-2222-3333-4444-555555555555")))
    }
}
