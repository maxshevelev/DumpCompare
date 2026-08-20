import Foundation
import DumpCompareCore

/// Coordinates the background `DiffBlockIndex` lifecycle for comparison mode
/// (§8.3, §10.3).
///
/// Owns a single `DiffIndexBuilder` actor. The lifecycle:
/// - `start()` begins a full-file scan of the two current storages (fetched
///   through `provider`, so reverts that swap the document storage are seen).
///   The scan is surfaced as a `BackgroundOperation` ("Indexing…") via
///   `onOperation`, and `onIndexChanged` fires when the index completes.
/// - Edits reported via `record(edit:)` are buffered while the first build is
///   in flight, then applied in order once it lands; afterwards they are applied
///   incrementally in background batches.
/// - `rebuild()` (undo/redo/revert, or a pane being replaced) cancels the
///   in-flight work and restarts from the current storages.
/// - `stop()` (a pane closed) drops the index and cancels.
/// - `cancelBuild()` (the operation's × button) cancels without restarting;
///   the index stays nil until the next `start()`/`rebuild()`.
///
/// A `generation` counter discards results from superseded builds. Cancelling
/// then resetting the shared builder keeps every background task from a stale
/// generation from mutating current state; actor FIFO guarantees the reset
/// lands after the stale scan's next cancellation check.
///
/// The coordinator itself is MainActor-confined; the heavy lifting runs on
/// `DiffIndexBuilder`'s actor.
@MainActor
final class ComparisonCoordinator {
    /// Supplies the two current storages. Returns nil when comparison should be
    /// idle (a pane closed). Called on every start/rebuild so a document that
    /// replaced its storage on revert is re-read.
    private let provider: () -> (left: ByteStorage, right: ByteStorage)?

    private let builder = DiffIndexBuilder()

    /// Latest completed index, or nil while building/after `stop`.
    private(set) var index: DiffBlockIndex?
    /// The navigation hunks derived from `index` (§10.3.1) — always in step with
    /// it: both are published in the same main-actor step, so a non-nil `index`
    /// implies a non-nil `hunkIndex`.
    private(set) var hunkIndex: DiffHunkIndex?
    /// Bumped on every `index` assignment, so a background hunk pass that lost
    /// the race against a newer index drops its result.
    private var indexVersion = 0
    /// Bumped every time a *fresh* index replaces the old one, as opposed to one
    /// that absorbed a recorded edit. A consumer holding a picture derived from
    /// the index (the minimap's overview, §19.4.2) reads this to tell "patch the
    /// rows I edited" from "everything you derived is stale".
    private(set) var indexBuildCount = 0
    /// True while a full-file index is not yet available.
    private(set) var isBuilding = false

    /// The active build operation ("Indexing…"), or nil when idle. Its
    /// progress is fed from the builder's actor; `finish()` hides the status
    /// bar indicator on every completion path.
    private(set) var operation: BackgroundOperation?

    /// Fired when `index` is replaced (initial build completed, or edits applied).
    var onIndexChanged: ((DiffBlockIndex) -> Void)?
    /// Fired from `start()` with the new build operation; the view presents it
    /// in the active pane's status bar.
    var onOperation: ((BackgroundOperation) -> Void)?
    /// Fired whenever the availability of the index changes — build starts,
    /// completes, is cancelled, stops, or edits are applied — so consumers can
    /// re-evaluate whether diff navigation is possible (§10.3). A single hook
    /// covers transitions that `onIndexChanged`/`onOperation` don't (cancel,
    /// stop, build failure).
    var onStateChanged: (() -> Void)?

    /// How far apart differing bytes may sit and still count as one change for
    /// navigation (§10.3.1). Seeded from the Comparison settings tab; the view
    /// controller assigns the new value when the setting changes, and the hunks
    /// are re-derived from the existing index — the byte-exact comparison is
    /// unaffected, so no rescan is needed.
    var groupingGap: UInt64 = ComparisonSettings.groupingGap {
        didSet {
            guard groupingGap != oldValue else { return }
            regroup()
        }
    }

    /// Bumped on every start/rebuild/stop so stale background results are dropped.
    private var generation = 0
    /// Edits that arrived while the first build was in flight.
    private var pendingEdits: [DiffEdit] = []
    /// Edits queued for incremental application after the index is ready.
    private var queuedEdits: [DiffEdit] = []
    /// Whether an incremental apply batch is running on the builder actor.
    private var applying = false
    private var currentLeft: ByteStorage?
    private var currentRight: ByteStorage?

    init(provider: @escaping () -> (left: ByteStorage, right: ByteStorage)?) {
        self.provider = provider
    }

    // MARK: - Lifecycle

    /// Begins (or restarts) the comparison for the current storages.
    func start() {
        guard let (left, right) = provider() else { return }
        currentLeft = left
        currentRight = right
        generation += 1
        setIndex(nil)
        pendingEdits = []
        queuedEdits = []
        applying = false
        isBuilding = true
        endBuildOperation()
        let op = BackgroundOperation(name: "Indexing…") { [weak self] in
            self?.cancelBuild()
        }
        operation = op
        onOperation?(op)
        onStateChanged?()

        let gen = generation
        Task {
            // Stop the previous scan, clear the flag, then start fresh. Actor
            // ordering guarantees reset() runs after the old scan throws.
            await builder.cancel()
            await builder.reset()
            await runInitialBuild(left: left, right: right, generation: gen, operation: op)
        }
    }

    /// Full rebuild — used after an edit that isn't represented as a `DiffEdit`
    /// (undo/redo/revert replace the document storage wholesale).
    func rebuild() {
        start()
    }

    /// Stops comparison entirely (a pane closed). Drops the index and cancels
    /// any in-flight scan.
    func stop() {
        generation += 1
        setIndex(nil)
        currentLeft = nil
        currentRight = nil
        pendingEdits = []
        queuedEdits = []
        applying = false
        isBuilding = false
        endBuildOperation()
        onStateChanged?()
        Task { await builder.cancel() }
    }

    /// Cancels the in-flight build without starting a new one (the operation's
    /// × button). The index stays nil until the next `start()`/`rebuild()`; the
    /// generation guard drops the cancelled build's result when it surfaces.
    func cancelBuild() {
        generation += 1
        isBuilding = false
        endBuildOperation()
        onStateChanged?()
        Task { await builder.cancel() }
    }

    // MARK: - Edits (§8.3)

    /// Records an edit from one pane. `.overwrite` invalidates only the
    /// overwritten range; `.insert`/`.delete` invalidate from the earliest
    /// affected offset onward — `DiffEngine.apply` handles both, so all we do
    /// is schedule a rebuild of the affected region against current bytes.
    func record(edit: DiffEdit) {
        guard isBuilding || index != nil else { return }  // stopped
        if isBuilding {
            pendingEdits.append(edit)
        } else {
            queuedEdits.append(edit)
            drainQueue()
        }
    }

    /// Applies queued edits to the index in background batches, publishing each
    /// result so navigation always sees the freshest blocks.
    private func drainQueue() {
        guard !applying, let left = currentLeft, let right = currentRight, let base = index else { return }
        applying = true
        let gen = generation
        // A batch is collapsed before it is applied: `apply` rescans against
        // current bytes, so a shifting edit already covers every edit at or
        // after its offset. Ten inserted bytes were ten rescans of the file's
        // tail; now they are one (§8.3).
        let edits = DiffEdit.collapse(queuedEdits)
        queuedEdits.removeAll()
        let gap = groupingGap
        Task {
            var working = base
            let hunks: DiffHunkIndex
            do {
                for edit in edits {
                    working = try await self.builder.apply(edit, to: working, left: left, right: right)
                }
                hunks = await self.builder.hunks(for: working, gap: gap)
            } catch {
                // Cancellation (superseded build) or a storage failure. A stale
                // generation is handled by the caller restarting; otherwise put
                // the batch back and retry.
                guard gen == self.generation else { return }
                self.applying = false
                self.queuedEdits = edits + self.queuedEdits
                return
            }
            guard gen == self.generation else { return }
            self.setIndex(working, hunks: hunks)
            self.applying = false
            self.onStateChanged?()
            if !self.queuedEdits.isEmpty {
                self.drainQueue()
            } else {
                self.onIndexChanged?(working)
            }
        }
    }

    // MARK: - Navigation (§10.3)

    /// Finds the next/previous block of `kind` from `offset` (forward:
    /// `lowerBound > offset`; backward: `upperBound <= offset`).
    ///
    /// The unit is a navigation hunk, not a byte-exact block (§10.3.1): nearby
    /// differences are one target, so a dump whose differing bytes alternate
    /// with matching ones takes one press per change instead of one per byte.
    /// Requires the derived hunks: while the index is still building they are
    /// nil, so navigation reports "not found" instead of racing the build with a
    /// scan (§10.3).
    func findBlock(
        kind: DiffBlock.Kind,
        direction: SearchDirection,
        from offset: UInt64
    ) -> DiffBlock? {
        guard let hunkIndex else { return nil }
        let range: Range<UInt64>?
        switch (kind, direction) {
        case (.different, .forward): range = hunkIndex.nextDifference(from: offset)
        case (.different, .backward): range = hunkIndex.previousDifference(from: offset)
        case (.same, .forward): range = hunkIndex.nextSame(from: offset)
        case (.same, .backward): range = hunkIndex.previousSame(from: offset)
        }
        return range.map { DiffBlock(kind: kind, range: $0) }
    }

    // MARK: - Internals

    /// Publishes an index together with the hunks derived from it, so navigation
    /// never reads hunks that belong to an older set of blocks (§10.3.1).
    private func setIndex(_ newIndex: DiffBlockIndex?, hunks: DiffHunkIndex? = nil) {
        index = newIndex
        hunkIndex = newIndex == nil ? nil : hunks
        indexVersion += 1
    }

    /// Re-derives the hunks after `groupingGap` changed. The blocks are already
    /// correct — only their grouping moved — so this never rescans the files.
    private func regroup() {
        guard let index else { return }
        let gen = generation
        let version = indexVersion
        let gap = groupingGap
        Task {
            let hunks = await self.builder.hunks(for: index, gap: gap)
            // A newer index (an applied edit, a restart) has already published
            // hunks for the current gap; this pass is stale.
            guard gen == self.generation, version == self.indexVersion else { return }
            self.hunkIndex = hunks
            self.onStateChanged?()
        }
    }

    private func runInitialBuild(left: ByteStorage, right: ByteStorage, generation gen: Int, operation op: BackgroundOperation) async {
        // Poll the actor's progress so the status bar's operation indicator
        // advances as the scan covers the file. Report to THIS build's op (not
        // `self.operation`, which a newer start/cancel may have replaced): a
        // stale poll then no-ops against a finished op instead of leaking a
        // stale value into the new build's bar.
        let progressTask = Task {
            while self.isBuilding && gen == self.generation {
                let p = await self.builder.progress
                op.report(p)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        do {
            let built = try await builder.build(left: left, right: right)
            let hunks = await builder.hunks(for: built, gap: groupingGap)
            progressTask.cancel()
            // A stale build (superseded by start/rebuild/cancel) belongs to an
            // operation this coordinator no longer owns — leave it untouched.
            guard gen == self.generation else { return }
            self.setIndex(built, hunks: hunks)
            self.indexBuildCount += 1
            self.isBuilding = false
            self.endBuildOperation()
            self.onStateChanged?()
            if !self.pendingEdits.isEmpty {
                self.queuedEdits = self.pendingEdits + self.queuedEdits
                self.pendingEdits.removeAll()
                self.drainQueue()
            } else {
                self.onIndexChanged?(built)
            }
        } catch is CancellationError {
            progressTask.cancel()
            guard gen == self.generation else { return }
            self.isBuilding = false
            self.endBuildOperation()
            self.onStateChanged?()
        } catch {
            progressTask.cancel()
            guard gen == self.generation else { return }
            self.isBuilding = false
            self.endBuildOperation()
            self.onStateChanged?()
            self.onError?(error)
        }
    }

    /// Finishes the active build operation (if any) and clears it. Only called
    /// on paths where the coordinator still owns the operation — a stale build
    /// that lost the generation race returns before reaching here, so it never
    /// hides a newer build's indicator.
    private func endBuildOperation() {
        operation?.finish()
        operation = nil
    }

    /// Surface for build failures (e.g. a storage read error mid-scan).
    var onError: ((Error) -> Void)?
}
