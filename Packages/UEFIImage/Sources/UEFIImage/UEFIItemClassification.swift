import Foundation

/// The UEFITool classification of a node in this tree: which `Types::ItemTypes`
/// it is, and, when the node has one, which subtype.
///
/// This is the bridge between the node model — which carries a `kind`, a
/// one-byte `subtype`, and a `guid` — and UEFITool's classification, which the
/// structure tree's Type and Subtype columns show. The mapping reads what the
/// parser actually stored, so a node and its classification cannot disagree:
/// the same node classifies the same way on every parse.
extension UEFINode {
    /// The `Types::ItemTypes` code this node is.
    public var uefiItemType: UInt8 {
        switch kind {
        case .capsule: return UEFITypes.Item.capsule.rawValue
        case .region, .flashDescriptor: return UEFITypes.Item.region.rawValue
        case .volume: return UEFITypes.Item.volume.rawValue
        case .file: return UEFITypes.Item.file.rawValue
        case .section: return UEFITypes.Item.section.rawValue
        case .microcode: return UEFITypes.Item.intelMicrocode.rawValue
        case .padding: return UEFITypes.Item.padding.rawValue
        case .freeSpace: return UEFITypes.Item.freeSpace.rawValue
        // Data nobody claimed is a run of bytes with a type, not a structure, so
        // it reads as a file the way a raw region does.
        case .nonUEFIData: return UEFITypes.Item.file.rawValue
        }
    }

    /// The subtype code, when the node has one. Nil where there is nothing to
    /// say: free space, and the Intel microcode, which is one kind and no more.
    public var uefiItemSubtype: UInt8? {
        switch kind {
        case .capsule:
            return guid.map(Self.capsuleSubtype)
        case .region:
            // The descriptor's region type, the one the parser read off the table.
            return subtype
        case .flashDescriptor:
            return UEFITypes.Sub.descriptorRegion
        case .volume:
            return Self.volumeSubtype(of: self)
        case .file, .section:
            return subtype
        case .microcode:
            return nil
        case .padding:
            return Self.paddingSubtype(of: self)
        case .freeSpace:
            return nil
        case .nonUEFIData:
            return nil
        }
    }

    // MARK: - The subtypes that are not a byte on the node

    /// Which capsule, by its GUID: the Aptio and Toshiba ones are named, the
    /// rest read as a plain UEFI capsule.
    private static func capsuleSubtype(of guid: EFIGUID) -> UInt8 {
        if guid == KnownGUIDs.guid("4A3CA68B-7723-48FB-803D-578CC1FEC44D") {
            return UEFITypes.Sub.aptioSignedCapsule
        }
        if guid == KnownGUIDs.guid("14EEBB90-890A-43DB-AED1-5D3C4588A418") {
            return UEFITypes.Sub.aptioUnsignedCapsule
        }
        if guid == KnownGUIDs.guid("3BE07062-1D51-45D2-832B-F093257ED461") {
            return UEFITypes.Sub.toshibaCapsule
        }
        return UEFITypes.Sub.uefiCapsule
    }

    /// The file system a volume body is read as, by its file-system GUID.
    ///
    /// FFSv1 and FFSv2 bodies are read the same way here, so both classify as
    /// FFSv2 — the version the tree's volume column has always shown.
    private static func volumeSubtype(of node: UEFINode) -> UInt8 {
        guard let guid = node.guid else { return UEFITypes.Sub.unknownVolume }
        switch KnownGUIDs.ffsVersion(ofFileSystem: guid) {
        case 1, 2: return UEFITypes.Sub.ffs2Volume
        case 3: return UEFITypes.Sub.ffs3Volume
        default: break
        }
        if guid == KnownGUIDs.guid("FFF12B8D-7696-4C8B-A985-2747075B4F50")
            || guid == KnownGUIDs.guid("00504624-8A59-4EEB-BD0F-6B36E96128E0") {
            return UEFITypes.Sub.nvramVolume
        }
        if guid == KnownGUIDs.guid("153D2197-29BD-44DC-AC59-887F70E41A6B") {
            return UEFITypes.Sub.appleMicrocodeVolume
        }
        return UEFITypes.Sub.unknownVolume
    }

    /// What a run of padding is filled with.
    ///
    /// The parser says only whether a run is all the erase byte; which byte that
    /// is depends on the polarity in force, and the node does not carry it. So an
    /// erased run is shown as the polarity's byte — 0xFF, the default outside a
    /// volume — and a live one as data.
    private static func paddingSubtype(of node: UEFINode) -> UInt8 {
        node.isErased ? UEFITypes.Sub.onePadding : UEFITypes.Sub.dataPadding
    }
}
