import Foundation

/// What `MEAToolSession` reaches to get at the pane's own whole-region cache
/// of the last `FirmwareAnalysis`, without depending on the app that owns it.
///
/// Distinct from `UEFIImage.UEFITreeProviding` (defined in `UEFIImage`, not
/// here, since that type belongs to the UEFI tree): MEFirmware's own engine
/// has no partial/lazy re-scan of its own — a byte changed anywhere inside
/// the ME region invalidates the whole analysis, so the cache this protocol
/// reaches is whole-region granularity, not a tree of subtrees.
@MainActor
public protocol MEAAnalysisProviding: AnyObject {
    /// The pane's cached analysis, or nil if there is none (never analyzed
    /// yet, or invalidated by an edit inside the region it was computed for).
    func cachedMEAnalysis() -> FirmwareAnalysis?

    /// Records the result of a fresh analysis and the byte range it covered,
    /// so a later edit inside that range can drop it again.
    func setCachedMEAnalysis(_ analysis: FirmwareAnalysis?, meRegion: Range<UInt64>?)
}
