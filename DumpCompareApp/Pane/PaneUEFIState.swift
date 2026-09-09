import Foundation
import UEFIImage
import MEFirmware
import DumpCompareCore

/// The one shared, lazily-materialized UEFI parse for this pane's open file,
/// plus MEA's own whole-region analysis cache — created on first request by
/// whichever tool-module asks first, torn down whenever the pane's content is
/// replaced wholesale.
///
/// Owned by `PaneViewModel` (`let uefiState = PaneUEFIState()`) so it lives
/// exactly as long as the file does — unlike `PaneToolHost`, which
/// `ToolController` tears down and rebuilds on every tool-module activation.
/// A `PaneToolHost` reaches this through its (weak) `pane` reference, which
/// is what lets a fresh host on every activation still hand a tool-module the
/// same tree/cache an earlier session already built.
///
/// `invalidate(_:)` is called from `PaneViewModel.signalEdit`, the one place
/// every edit already passes through — not from `ToolController`, which only
/// hears about edits while some tool-module session is bound to this pane.
/// The tree and cache have to survive the tool panel being on None, so their
/// invalidation cannot depend on one being open.
@MainActor final class PaneUEFIState {
    private(set) var tree: LazyUEFITree?
    private var cachedAnalysis: FirmwareAnalysis?
    /// The byte range `cachedAnalysis` was computed for — an edit landing
    /// inside it is what drops the cache; one outside it leaves the analysis
    /// exactly as valid as it was.
    private var cachedAnalysisRegion: Range<UInt64>?

    /// The tree, building it against `makeSource()` the first time anything
    /// asks. `makeSource` produces a *live* `ByteSource` — one that reads
    /// through to the document's actual storage rather than a frozen
    /// snapshot — so nothing here ever needs to hand the tree fresher bytes;
    /// `invalidate` only ever needs to say which memoized subtrees to forget.
    func tree(makeSource: () -> any ByteSource) -> LazyUEFITree? {
        if let tree { return tree }
        let newTree = LazyUEFITree(makeSource())
        tree = newTree
        return newTree
    }

    func cachedMEAnalysis() -> FirmwareAnalysis? {
        cachedAnalysis
    }

    func setCachedMEAnalysis(_ analysis: FirmwareAnalysis?, meRegion: Range<UInt64>?) {
        cachedAnalysis = analysis
        cachedAnalysisRegion = meRegion
    }

    /// Narrows the tree's own stale subtrees, and drops the cached analysis
    /// when the edit falls inside (or, for a size-changing edit, at or after)
    /// the region it was computed for.
    func invalidate(_ edit: DiffEdit) {
        let range: Range<UInt64>
        let sizeDelta: Int64
        switch edit {
        case .overwrite(let editedRange):
            range = editedRange
            sizeDelta = 0
        case .insert(let at, let length):
            range = at..<(at &+ length)
            sizeDelta = Int64(length)
        case .delete(let editedRange):
            range = editedRange.lowerBound..<editedRange.lowerBound
            sizeDelta = -Int64(editedRange.count)
        }

        tree?.invalidate(editedRange: range, sizeDelta: sizeDelta)

        if let cachedAnalysisRegion {
            let stillValid = sizeDelta == 0
                ? !cachedAnalysisRegion.overlaps(range)
                : cachedAnalysisRegion.upperBound <= range.lowerBound
            if !stillValid {
                cachedAnalysis = nil
                self.cachedAnalysisRegion = nil
            }
        }
    }

    /// Drops the tree and the cached analysis entirely — a new file opened
    /// into this pane, a revert, a close: nothing about the old content is
    /// worth keeping.
    func reset() {
        tree = nil
        cachedAnalysis = nil
        cachedAnalysisRegion = nil
    }
}
