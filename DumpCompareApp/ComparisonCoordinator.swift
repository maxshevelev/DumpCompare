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
        index = nil
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
        index = nil
        currentLeft = nil
        currentRight = nil
        pendingEdits = []
        queuedEdits = []
        applying = false
        isBuilding = false
        endBuildOperation()
        Task { await builder.cancel() }
    }

    /// Cancels the in-flight build without starting a new one (the operation's
    /// × button). The index stays nil until the next `start()`/`rebuild()`; the
    /// generation guard drops the cancelled build's result when it surfaces.
    func cancelBuild() {
        generation += 1
        isBuilding = false
        endBuildOperation()
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
        let edits = queuedEdits
        queuedEdits.removeAll()
        Task {
            var working = base
            do {
                for edit in edits {
                    working = try await self.builder.apply(edit, to: working, left: left, right: right)
                }
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
            self.index = working
            self.applying = false
            if !self.queuedEdits.isEmpty {
                self.drainQueue()
            } else {
                self.onIndexChanged?(working)
            }
        }
    }

    // MARK: - Navigation (§10.3)

    /// Finds the next/previous block of `kind` from `offset`, matching
    /// `DiffBlockIndex` semantics (forward: `lowerBound > offset`; backward:
    /// `upperBound <= offset`). Requires the built index: while the index is
    /// still building (`index == nil`) it returns nil, so navigation reports
    /// "not found" instead of racing the build with a scan (§10.3).
    func findBlock(
        kind: DiffBlock.Kind,
        direction: SearchDirection,
        from offset: UInt64
    ) -> DiffBlock? {
        guard let index else { return nil }
        switch (kind, direction) {
        case (.different, .forward): return index.nextDifference(from: offset)
        case (.different, .backward): return index.previousDifference(from: offset)
        case (.same, .forward): return index.nextSame(from: offset)
        case (.same, .backward): return index.previousSame(from: offset)
        }
    }

    // MARK: - Internals

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
            progressTask.cancel()
            // A stale build (superseded by start/rebuild/cancel) belongs to an
            // operation this coordinator no longer owns — leave it untouched.
            guard gen == self.generation else { return }
            self.index = built
            self.isBuilding = false
            self.endBuildOperation()
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
        } catch {
            progressTask.cancel()
            guard gen == self.generation else { return }
            self.isBuilding = false
            self.endBuildOperation()
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
