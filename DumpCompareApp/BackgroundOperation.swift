import Foundation

/// A named, cancellable background operation with progress in [0, 1], shown
/// uniformly in the active pane's status bar as name + progress bar + (×)
/// button (§14.4).
///
/// The operation itself does no work: the owner runs the real task (a search,
/// a diff index build, …), feeds progress via `report(_:)`, and the (×) button
/// calls `cancel()`, which asks the owner's `cancelAction` to stop that work.
/// The same abstraction covers search (§11) and diff indexing (§8.3) today and
/// is the seam a chunked cancellable fill would use later.
///
/// Threading: `report`/`finish` are safe to call from a background thread —
/// they throttle (skipping updates that move the bar by less than ~1%) and hop
/// to the main actor to touch state. `cancel()` runs on main (button target).
final class BackgroundOperation: @unchecked Sendable {
    /// Short present-tense label, e.g. "Searching…" or "Indexing…".
    let name: String
    /// Whether progress is indeterminate (no fraction). Kept as a design seam
    /// for operations without a known size; today everything reports [0, 1].
    let isIndeterminate: Bool

    /// The owner's real cancellation (e.g. `findTask?.cancel()`). The owner
    /// captures itself weakly so the operation never retains it.
    private let cancelAction: () -> Void

    // Main-actor state (touched from main by `report`/`finish` tasks).
    private(set) var isActive = true
    private(set) var progress: Double = 0
    /// Fired on main with each dispatched progress update.
    var onProgress: ((Double) -> Void)?
    /// Fired once on main when the operation completes (`finish`); the status
    /// bar uses it to hide the indicator.
    var onFinish: (() -> Void)?

    /// The last fraction dispatched to main, for the ~1% throttle. Guarded by
    /// `lock` because `report` runs on the operation's background thread.
    private var lastReportedFraction: Double = 0
    private let lock = NSLock()

    init(name: String, indeterminate: Bool = false, onCancel: @escaping () -> Void) {
        self.name = name
        self.isIndeterminate = indeterminate
        self.cancelAction = onCancel
    }

    /// Thread-safe progress update. Clamps `fraction` to [0, 1] and dispatches
    /// to main only when the bar would move by at least ~1% (the final 1 always
    /// dispatches), so a 1-GB scan's thousands of chunks don't flood the main
    /// thread. Indeterminate operations ignore fractions.
    func report(_ fraction: Double) {
        guard !isIndeterminate else { return }
        let clamped = min(max(fraction, 0), 1)
        lock.lock()
        guard clamped - lastReportedFraction >= 0.01 || clamped == 1 else {
            lock.unlock()
            return
        }
        lastReportedFraction = clamped
        lock.unlock()
        Task { @MainActor in
            guard self.isActive else { return }
            self.progress = clamped
            self.onProgress?(clamped)
        }
    }

    /// Idempotently completes the operation: marks it inactive (late
    /// `report`/`finish` calls no-op) and fires `onFinish` so the status bar
    /// hides the indicator. Callable from any thread.
    func finish() {
        Task { @MainActor in
            guard self.isActive else { return }
            self.isActive = false
            self.onFinish?()
        }
    }

    /// The (×) button: ask the owner to cancel the underlying work. The owner
    /// decides how to stop it and calls `finish()` on its cancellation path, so
    /// the indicator hides the same way a normal completion hides it.
    func cancel() {
        cancelAction()
    }
}
