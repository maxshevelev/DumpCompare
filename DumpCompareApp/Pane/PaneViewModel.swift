import Foundation
import DumpCompareCore

/// The visual state of a single byte in the hex grid (§6).
///
/// `isEOF` marks a placeholder cell past the file's end (muted rendering);
/// `isModified` means the byte differs from the last saved file on disk (red
/// foreground); `isDifferent` is the comparison state (background, Milestone 5).
struct HexByteState: Equatable {
    var byte: UInt8 = 0
    var isModified = false
    var isDifferent = false
    var isEOF = false
}

/// Which interactive region the hex caret lives in (§7): hex digits are typed
/// in the hex area, ASCII characters in the ASCII area. Clicking a region moves
/// the caret there.
enum HexInputRegion {
    case hex
    case ascii
}

/// One piece as the status bar reads it (§21.3): the label the bar shows and
/// the range it renders.
struct SegmentReadout: Equatable {
    /// Positional label: "S0", "S1", …
    let label: String
    /// The piece's half-open byte range.
    let range: Range<UInt64>
}

/// Read-only snapshot of the pane's status-bar fields (§15).
struct PaneStatus: Equatable {
    var fileName = ""
    var fileSize: UInt64 = 0
    /// The caret's offset, raw — the view renders it as bare hex (§21.3).
    var cursorOffset: UInt64 = 0
    var selectionLength: UInt64 = 0
    var isDirty = false
    var isReadOnly = false
    /// True for an untitled in-memory document (File > New File) that has never
    /// been saved — the header shows "Untitled" with a plus-badge glyph.
    var isUntitled = false
    var canUndo = false
    var canRedo = false
    /// The typing mode this pane is in (§7.6) — the status bar shows it as
    /// INS/OVR.
    var isInsertMode = false
    /// The piece the caret is in, for the status bar's readout (§21.3). Nil when
    /// the pane is a single piece: the readout appearing at all is the signal
    /// that the dump is partitioned.
    var segment: SegmentReadout?
}

/// Pane-level save error: an untitled document has no file yet, so it needs a
/// Save As location before it can be written to disk. The view controller
/// routes untitled panes to Save As before calling `save()`.
enum PaneSaveError: Error {
    case requiresSaveAs
}

/// View-model for one file pane (single-file mode; comparison lands in M5).
///
/// Owns the `BinaryDocument`, the hex-typing caret (byte offset + nibble), and
/// the selection. All mutations go through here so the pane can:
/// - record edits via the document (undo/redo, dirty state);
/// - report which bytes are modified relative to the last saved file (red
///   foreground) by comparing against a fresh `FileBackedStorage` of the URL;
/// - notify the view (`onChange`) so it redraws and updates the status bar.
///
/// `PaneViewModel` is `MainActor`-confined (UI on MainActor). It contains no
/// AppKit, keeping the editing rules unit-testable.
@MainActor
final class PaneViewModel: HexViewDataSource {
    private(set) var document: BinaryDocument?
    /// Disk bytes as of the last open/save/revert — the "saved" reference for
    /// modified-byte detection. Recreated whenever the on-disk content is known
    /// to have changed (save, save as, revert) so a stale chunk cache can't
    /// misreport. Readable because the minimap's overview compares against the
    /// same reference the panes do when it marks modified cells (§19.4).
    private(set) var savedStorage: FileBackedStorage?
    /// True while the pane holds an untitled in-memory document (File > New
    /// File) that has never been saved to disk. Such a document has no URL to
    /// watch and no on-disk reference for modified-byte detection; the header
    /// shows "Untitled" with a plus-badge glyph until it is saved.
    private(set) var isUntitled = false

    /// Hex caret: 0 = high nibble, 1 = low nibble of the current byte.
    private(set) var nibble = 0
    /// The interactive region the caret currently targets (§7).
    private(set) var inputRegion: HexInputRegion = .hex
    /// Typing mode: `true` inserts a byte at the caret (the file grows), `false`
    /// overwrites the byte under the caret. Set by the controller for both panes
    /// at once (a session-global mode, never persisted). The `didSet` repaints
    /// just the caret's row so the caret instantly changes colour/shape when the
    /// mode flips — without scrolling, because the caret did not move (a scroll
    /// would yank the view away from where the user was reading).
    var isInsertMode = false {
        didSet { if document != nil { onCaretAppearanceChanged?() } }
    }
    /// Presenter for the one-time "inserting shifts the file" warning, injected
    /// by the controller. Nil under pure unit tests, where typing proceeds
    /// without asking. Returns `true` to proceed, `false` to swallow the key.
    var confirmInsertModeWarning: (() -> Bool)?
    /// Whether this file has already been warned about insert-mode shifting.
    /// Shown once per opened file; reset on open/close (see `resetEditingState`
    /// callers) so a new file re-arms it.
    private var hasWarnedInsertShift = false
    /// When typing over a selection, the selection being consumed (§7.4).
    private var overwriteSelection: SelectionModel?
    /// Anchor for shift-extended selections.
    private var selectionAnchor: UInt64?
    /// Whether a hex-byte edit group is open (the two nibbles of a byte coalesce
    /// into a single undo step; see `beginTypingGroup`/`endTypingGroup`).
    private var typingGroupOpen = false
    /// The offset of a byte whose high nibble was just inserted in insert mode
    /// (the low nibble is still pending, the edit group still open). `nil` once
    /// the byte is completed or the caret leaves it. Distinguishes a genuine
    /// half-typed insert (Backspace rolls it back) from a mid-byte caret a click
    /// placed (Backspace behaves normally).
    private var pendingInsertOffset: UInt64?

    /// Time injection so tests can drive the series-break and fast-undo
    /// windows deterministically (the pattern of `MainViewController.minimapDefaults`).
    static var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// A pause between typed bytes longer than this breaks the typing series.
    static let seriesBreakThreshold: TimeInterval = 0.7
    /// A repeat undo within this window of a series-byte undo removes the rest
    /// of the series in one step (the fast-undo window).
    static let fastUndoWindow: TimeInterval = 0.5

    /// Whether a typing series is open (bytes recorded under one series id).
    private var typingSeriesOpen = false
    /// Monotonic id handed to `BinaryDocument.beginSeries` for each new series.
    private var seriesCounter: UInt64 = 0
    /// When the last typed nibble/character landed; the interval to the next
    /// byte is measured from the last event, so a type-pair never breaks.
    private var lastTypingTime: TimeInterval = 0
    /// The input region the open series was typed in; a region change breaks it.
    private var lastTypingMode: HexInputRegion?
    /// When the last undo ran (the fast-undo window); nil until the first undo.
    private var lastUndoTime: TimeInterval?

    /// The other pane in comparison mode. Selections are independent per pane
    /// (§3.3): this pane reads the companion's selection only to mirror it with
    /// frames, and tells the companion when its own selection changed so the
    /// mirror redraws. Nil in single-file mode. Weak to avoid a retain cycle.
    weak var companion: PaneViewModel?

    /// The window's shared bookmark list (§20): one instance on the
    /// `WindowViewModel`, reached by both panes, so a marked row shows at the
    /// same height in both panes of a comparison. Strong — the store holds no
    /// pane, so there is no cycle — and nil on a bare pane (unit tests) that
    /// has no window behind it.
    /// A stable identity for this pane, for as long as it exists.
    ///
    /// The pane's own, not its document's: a pane keeps it when it moves into
    /// another window, for the same reason it keeps its undo history — what
    /// moves is the pane. It exists so a drag can name a pane on the pasteboard
    /// without putting anything about the file there
    /// (`Design/PANE_DRAG_PLAN.md`).
    let dragID = UUID()

    var bookmarkStore: BookmarkStore?

    /// The pane's segment partition (§21): one per pane, beside `document` —
    /// segments describe one file's make-up, not the window's (the opposite of
    /// `bookmarkStore`, which is the window's). Created once per pane; reset on
    /// open, close, and revert.
    private(set) var segmentStore: SegmentStore

    /// Fired when the pane's segment partition changes — the Segments form
    /// follows it this way (§21.4), the way the Go To form follows the window's
    /// bookmark store (§20.5). Set by the form while it is open; the pane's own
    /// repaint runs through the content-change channel, not here.
    var onSegmentsChanged: (() -> Void)?

    /// The snapshot stack parallel to the document's undo stack (§21.2): each
    /// entry is the segment state *before* the transaction it sits under, so
    /// undo restores by snapshot rather than by inverse edit (a delete that
    /// swallowed a cut cannot be undone from the edit alone).
    private var segmentUndoStack: [SegmentStore.Snapshot] = []
    /// The redo side of the snapshot stack; dropped on every divergent edit.
    private var segmentRedoStack: [SegmentStore.Snapshot] = []
    /// The pre-edit segment snapshot captured at the start of the current edit
    /// gesture, pushed to `segmentUndoStack` when the gesture's transaction
    /// commits. Nil when no gesture is in flight.
    private var pendingSegmentSnapshot: SegmentStore.Snapshot?

    /// Fired after a byte-mutating edit with the `DiffEdit` describing the
    /// affected region, so the `ComparisonCoordinator` can update the index
    /// (§8.3). Not fired for selection-only changes or undo/redo/revert (those
    /// use `onFullInvalidation`).
    var onEdit: ((DiffEdit) -> Void)?

    /// Fired after an edit that the coordinator cannot represent as a
    /// `DiffEdit` (undo/redo/revert replace the storage wholesale) so it can
    /// rebuild the whole index.
    var onFullInvalidation: (() -> Void)?

    /// Fired whenever the on-disk reference moves (open, save, save as, revert),
    /// which changes what counts as modified without any byte changing. The
    /// panes need nothing — they re-read `hexByteStates` on every draw — but the
    /// minimap has no such trigger of its own, so without this a save left its
    /// red cells on screen (§19).
    var onSavedStateChanged: (() -> Void)?

    /// Fired when the companion's selection changed, so this pane can redraw
    /// the frames mirroring it (§3.3). A hex-view redraw only — this pane's own
    /// content, status, and scroll are untouched. Set by `FilePaneView.bind`.
    var onMirroredSelectionChanged: (() -> Void)?

    /// Called after any change so the view can redraw and refresh the status bar.
    /// Carries the caret-reveal mode (§10.4): `true` when a navigation command
    /// jumped the caret (centre it if it landed off-screen), `false` for an
    /// incremental move (the minimum scroll that keeps it on screen).
    var onChange: ((Bool) -> Void)?

    /// Fired when only the caret/selection moved (no bytes changed), so the
    /// view can redraw just the rows the selection now covers differently — the
    /// hot path for mouse-drag selection, where a full redraw on every event
    /// lags the cursor (§3.3). Carries the same caret-reveal mode as `onChange`
    /// (§10.4).
    /// What a selection change asks the view to do about scrolling (§10.4).
    enum SelectionReveal {
        /// Follow the active edge with the minimum scroll that keeps it on
        /// screen — an arrow, a drag, a click.
        case follow
        /// Centre the active edge: a navigation command jumped the caret, and
        /// it landed off screen.
        case center
        /// Do not scroll at all. A selection installed wholesale is not a
        /// navigation command: Select All must leave the viewport where the
        /// user was reading, and Find and Select Block scroll themselves, to
        /// the block's START mid-pane (§10.2, §11) — a reveal from here would
        /// first drag the view to the block's far end and be scrolled back.
        case stay
    }

    var onSelectionChanged: ((SelectionReveal) -> Void)?

    /// Fired after a content change — bytes overwritten in this pane, or its
    /// text decoder rebuilt — carrying the affected region, so the view can
    /// redraw only the affected rows/columns instead of the whole pane (§3.3
    /// extension). It carries no caret-reveal mode: a content change never
    /// moves the caret, so it must not scroll — revealing the caret is the
    /// selection and full channels' job (§10.4). Not fired for length-changing
    /// edits (insert/delete, paste insert, undo/redo/revert, open/save) — those
    /// still use `onChange`.
    var onContentChanged: ((HexViewChange) -> Void)?

    /// Fired when the *companion* pane's bytes changed, so this pane can redraw
    /// the rows the comparison-difference background now covers differently. A
    /// hex-view redraw only — this pane's own content, status, and scroll are
    /// untouched (the companion's own chrome refreshes via its
    /// `onContentChanged`). Mirror of `onMirroredSelectionChanged`.
    var onCompanionContentChanged: ((HexViewChange) -> Void)?

    /// Fired from `notify()` on every caret/selection change (and on edits too,
    /// since most move the caret). The navigation-enablement logic observes it
    /// to re-check whether a next/previous block still exists from the new
    /// position (§10.3).
    var onCaretChanged: (() -> Void)?

    /// Fired when the caret's *appearance* changes without its position moving —
    /// the typing-mode flip (overwrite ↔ insert) recolors and reshapes the caret
    /// in place. The view redraws just the caret's row; it must NOT scroll,
    /// because the caret did not move (a scroll would yank the view away from
    /// where the user was reading). Set by `FilePaneView.bind`.
    var onCaretAppearanceChanged: (() -> Void)?

    /// Fired when the shared bookmark list changes, carrying the affected
    /// row's start offset (§20). The view redraws just that row — the mark
    /// appeared or disappeared there — without scrolling. The list is shared,
    /// so the same row redraws in both panes of a comparison. Set by
    /// `FilePaneView.bind`.
    var onBookmarksChanged: ((UInt64) -> Void)?

    // MARK: - Find highlighting (§11)

    /// Where every occurrence of the active search pattern is: the set one scan
    /// produced, read by the dump's greys, the find indicator, the count in the
    /// Find bar, the results panel and both minimap modes
    /// (`Design/FIND_HIGHLIGHT_PLAN.md`). Nil until a search has been run, and
    /// again once one is invalidated — but *not* when its highlighting merely
    /// ended: a completed search survives `Done` so the results panel can go on
    /// listing it (§11, `highlightsMatches`).
    ///
    /// It belongs to the pane that was searched, and to no other: greys in a
    /// file nobody searched would be a plain lie in comparison mode.
    private(set) var matchSet: MatchSet?

    /// The match the user is standing on — what the find indicator draws in
    /// yellow, and the "3" in "3 of 128". Nil between activating a search and
    /// the first Find Next, whenever the caret has left the matches behind, and
    /// once the highlighting has ended.
    private(set) var currentMatchIndex: Int?

    /// Whether the set is being *shown*: greys in the dump, marks on the map,
    /// a count in the bar. A completed search outlives its highlighting —
    /// `Done`, Escape and a pattern being retyped end the showing and keep the
    /// set, which is what lets the results panel go on listing a search the
    /// dump has stopped advertising (§11). Only an invalidation drops the set
    /// itself.
    private(set) var highlightsMatches = false

    /// Fired when the set or the current match changed, so the dump repaints,
    /// the map re-reads, the results panel re-reads and the Find bar's count
    /// refreshes. Not a content channel: no byte moved, and nothing here may
    /// scroll.
    var onMatchesChanged: (() -> Void)?

    /// The set as far as everything that *draws* it is concerned: nil once the
    /// highlighting ended, even though the set is still there for the results
    /// panel to list (§11).
    var highlightedMatchSet: MatchSet? { highlightsMatches ? matchSet : nil }

    /// Installs a scan's result, and shows it: a search was just activated.
    /// `current` is clamped to the set, so a stale ordinal from a previous
    /// pattern can never point past the new one.
    func setMatches(_ set: MatchSet?, current: Int? = nil) {
        matchSet = set
        currentMatchIndex = Self.clamped(current, to: set)
        highlightsMatches = set != nil
        onMatchesChanged?()
    }

    /// Shows the set the pane already holds — the greys and the plate come
    /// back, on `current` when one is named (a row picked out of the results
    /// panel names one; a step through the set computes its own).
    ///
    /// Unconditionally announced, unlike `setCurrentMatch`: the same match can
    /// be picked twice, and the second pick is the one that has to turn the
    /// highlighting back on.
    func highlightMatches(current index: Int? = nil) {
        guard matchSet != nil else { return }
        highlightsMatches = true
        currentMatchIndex = Self.clamped(index ?? currentMatchIndex, to: matchSet)
        onMatchesChanged?()
    }

    /// Ends the showing and keeps the set (§11): the dump, the map and the
    /// count go quiet, while the results panel keeps listing the search that
    /// was actually run. The indicator's ordinal goes with the greys — nothing
    /// remembers it, because every way back in (a step, a picked row) says
    /// which match it wants.
    func endMatchHighlighting() {
        guard highlightsMatches || currentMatchIndex != nil else { return }
        highlightsMatches = false
        currentMatchIndex = nil
        onMatchesChanged?()
    }

    /// Moves the find indicator. Out-of-range indices clear it rather than
    /// throwing: navigation asks for "the next one", and past the end there is
    /// no next one.
    func setCurrentMatch(_ index: Int?) {
        let clamped = Self.clamped(index, to: matchSet)
        guard clamped != currentMatchIndex else { return }
        currentMatchIndex = clamped
        onMatchesChanged?()
    }

    /// Drops the set itself: no matches, no greys, no indicator, nothing left
    /// for the results panel to list. This is invalidation — the offsets
    /// stopped being true — not the end of a session (§11).
    func clearMatches() {
        guard matchSet != nil || currentMatchIndex != nil || highlightsMatches else { return }
        matchSet = nil
        currentMatchIndex = nil
        highlightsMatches = false
        onMatchesChanged?()
    }

    /// The find indicator's byte range, or nil when the caret is not on a match.
    var currentMatchRange: Range<UInt64>? {
        guard let index = currentMatchIndex else { return nil }
        return matchSet?.range(at: index)
    }

    /// The matches overlapping `range` — what the dump asks for per row range,
    /// and the map for its window. Empty when there is no session, and when the
    /// set is too large to hold positions for (the greys are withheld then, and
    /// the Find bar says why).
    func matchRanges(intersecting range: Range<UInt64>) -> [Range<UInt64>] {
        guard let matchSet = highlightedMatchSet, matchSet.isHighlightable else { return [] }
        return matchSet.matches(intersecting: range)
    }

    /// Whether this pane's set answers for `pattern` under `folding` — the test
    /// for "the same search", which decides whether a press of Find Next is an
    /// index step or a new scan.
    func hasMatches(for pattern: SearchPattern, folding: CaseFolding) -> Bool {
        guard let matchSet else { return false }
        return matchSet.pattern == pattern && matchSet.folding == folding
    }

    private static func clamped(_ index: Int?, to set: MatchSet?) -> Int? {
        guard let index, let set, index >= 0, index < set.total else { return nil }
        return index
    }

    /// The active text decoder, rebuilt whenever decoding settings change.
    private(set) var textDecoder: any TextDecoder

    private var textDecodingObserver: NSObjectProtocol?

    /// Whether a document is currently open in this pane.
    var isOpen: Bool { document != nil }

    /// Creates a new pane view model with the current decoding settings.
    init() {
        // One partition per pane, created empty and reset when a document opens.
        segmentStore = SegmentStore(size: 0, name: "")
        let currentSettings = TextDecodingSettingsStore().settings
        textDecoder = TextDecoderRegistry.make(identifier: currentSettings.identifier, placeholder: currentSettings.placeholder)
        // Rebuild the decoder when text-decoding settings change.
        textDecodingObserver = NotificationCenter.default.addObserver(
            forName: TextDecodingSettingsStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The .main queue posts on the main actor; this view model is
            // MainActor-confined, so the mutation is safe to assume isolated.
            MainActor.assumeIsolated {
                guard let self else { return }
                let store = TextDecodingSettingsStore()
                let settings = store.settings
                self.textDecoder = TextDecoderRegistry.make(identifier: settings.identifier, placeholder: settings.placeholder)
                // A decoding change only affects the decoded-text column; the
                // view redraws that band instead of the whole pane (§3.3
                // extension). The content channel repaints only — it never
                // reveals the caret, which a decoding change does not move
                // (§10.4).
                self.onContentChanged?(.textDecoding)
            }
        }
    }

    deinit {
        if let textDecodingObserver {
            NotificationCenter.default.removeObserver(textDecodingObserver)
        }
    }

    // MARK: - External change detection (§5.5)

    private var changeWatcher: FileChangeWatcher?
    /// Own writes (save/save-as/revert) also trip the watcher; events within
    /// this window are the app's own and are suppressed. Measured on the same
    /// injectable clock as the typing windows, so a test can step over the
    /// window instead of sleeping through it.
    private var externalChangeSuppressedUntil: TimeInterval = -.greatestFiniteMagnitude

    /// How long the app's own write suppresses change events after it.
    static let ownWriteSuppressionWindow: TimeInterval = 1.0

    /// Fired (on the main actor) when the file changed on disk from outside the
    /// app. The view controller decides what to prompt.
    var onExternalChange: (() -> Void)?

    // MARK: - Document lifecycle

    func open(url: URL) throws {
        let doc = try BinaryDocument(url: url)
        document = doc
        // A real file on disk is never untitled — opening one must clear the
        // flag an earlier New File left behind, or the pane header keeps showing
        // "Untitled" with the new-file glyph instead of the loaded file (§4/§5).
        isUntitled = false
        // Whatever name a duplicate was wearing belongs to the document that
        // has just been replaced, not to this one.
        untitledName = nil
        refreshSavedStorage()
        // A new file re-arms the one-time insert-mode warning (it is per opened
        // file, not per session).
        hasWarnedInsertShift = false
        // Ends the typing series, so a batch undo cannot span this checkpoint
        // (§7.5.1) — see `save()`.
        resetEditingState()
        // A new file is one piece — itself — named after the file (§21).
        resetSegments(for: doc)
        // The matches belonged to the file that was here (§11).
        clearMatches()
        startWatching(url)
        // Opening a new file replaces the storage wholesale, like a revert —
        // the comparison must re-read, even when the mode is unchanged (both
        // panes already open), which is the one path that skips `apply(mode:)`.
        onFullInvalidation?()
        // Announce the new document so the header glyph/name and the hex view
        // update immediately, not only on the next user action.
        notify()
        notifyCompanionContentFullyChanged()
    }

    /// Opens a brand-new empty document in memory (File > New File). Nothing is
    /// written to disk until the first Save As; until then the pane reports
    /// `isUntitled` so the UI can show "Untitled" and route Save to Save As.
    /// The placeholder URL never has a file behind it — it exists only to give
    /// the document an identity until a real location is chosen.
    func openUntitled() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Untitled")
        let doc = BinaryDocument(
            storage: EditOverlayStorage(base: MemoryBackedStorage()),
            url: url,
            readOnly: false
        )
        document = doc
        savedStorage = nil
        isUntitled = true
        untitledName = nil
        // A new file re-arms the one-time insert-mode warning.
        hasWarnedInsertShift = false
        resetEditingState()
        // A new (empty) file is one piece, named after the (placeholder) file.
        resetSegments(for: doc)
        clearMatches()
        changeWatcher?.stop()
        changeWatcher = nil
        // A new document replaces the storage wholesale, like a revert — the
        // comparison must re-read even when the mode is unchanged.
        onFullInvalidation?()
        notify()
        notifyCompanionContentFullyChanged()
    }

    /// Adopts a copy of `source`'s content as this pane's document (§23
    /// Duplicate). The result is an untitled, never-saved document, exactly as
    /// `openUntitled` leaves the pane — no watcher, no on-disk reference, Save
    /// routed through Save As — but holding the source's bytes, unsaved edits
    /// included, and dirty, because that content has never been written anywhere
    /// (a close must warn about it).
    ///
    /// No bytes are copied: the two documents share an immutable snapshot of the
    /// content and keep their own edits in their own overlays
    /// (`BinaryDocument.duplicate`). The source pane is left untouched.
    ///
    /// Throws when the snapshot cannot be taken; the pane is unchanged in that
    /// case (the document is only swapped in after the copy exists).
    /// The name an untitled document goes by, when it has one worth showing.
    ///
    /// A duplicate of a file is called after it — `bios-2.bin` — so two copies
    /// are told apart and each says which dump it came from (§23). Nothing is
    /// written to disk for it: this is the header's label and the save panel's
    /// pre-fill, and the file exists only once the user saves. Nil for a
    /// document with no such story, like `File ▸ New File`, which is "Untitled"
    /// because that is exactly what it is.
    private(set) var untitledName: String?

    /// Whether this pane's name can be changed by hand (§23).
    ///
    /// Only a document with no file behind it. Its name is a label — what the
    /// header shows, what the save panel opens with, and what Save All as
    /// Separate Files builds each piece's file name from (§21.5) — and a label
    /// costs nothing to change. A saved document's name is its file's, and
    /// moving a file is Save As's business, not a field in a header.
    var canRename: Bool { isOpen && isUntitled }

    /// Renames an unsaved document, reporting whether the name was taken.
    ///
    /// Nothing is written and nothing moves: this sets the label, which is the
    /// whole of an unsaved document's name. Refused for a document with a file
    /// behind it, and for a name that survives `PaneName.sanitized` as nothing.
    @discardableResult
    func rename(to raw: String) -> Bool {
        guard canRename, let name = PaneName.sanitized(raw) else { return false }
        guard name != untitledName else { return false }
        untitledName = name
        return true
    }

    func openDuplicate(of source: PaneViewModel, named name: String? = nil) throws {
        guard let sourceDoc = source.document else { return }
        let doc = try sourceDoc.duplicate()
        document = doc
        untitledName = name
        // Nothing on disk to compare against: like an untitled document, the copy
        // has no saved bytes, so no byte of it reads as modified (§6) until it is
        // saved and edited.
        savedStorage = nil
        isUntitled = true
        // A new file re-arms the one-time insert-mode warning.
        hasWarnedInsertShift = false
        resetEditingState()
        resetSegments(for: doc)
        // The copy is the source's bytes, so it is the source's pieces too: the
        // partition and the names come across (§23). Restoring over the reset
        // above keeps the reset's hooks — it only replaces the partition, which
        // is valid unchanged because the two contents have the same size.
        segmentStore.restore(source.segmentStore.snapshot())
        // The copy is a different document: it was never searched.
        clearMatches()
        changeWatcher?.stop()
        changeWatcher = nil
        // A new document replaces the storage wholesale, like a revert — the
        // comparison must re-read even when the mode is unchanged.
        onFullInvalidation?()
        notify()
        notifyCompanionContentFullyChanged()
    }

    func close() {
        document = nil
        savedStorage = nil
        isUntitled = false
        untitledName = nil
        // Closing drops the file, so the one-time insert-mode warning re-arms
        // for whatever opens next.
        hasWarnedInsertShift = false
        changeWatcher?.stop()
        changeWatcher = nil
        resetEditingState()
        // The segments go with the file (§21 edge cases); nothing is persisted.
        segmentStore.reset(size: 0, name: "")
        // So does the search session: there is nothing left to highlight (§11).
        clearMatches()
        segmentUndoStack.removeAll()
        segmentRedoStack.removeAll()
        pendingSegmentSnapshot = nil
    }

    func save() throws {
        guard let doc = document else { return }
        // An untitled document must pick a location first; the controller
        // routes through Save As, but throwing here makes a stray call safe
        // (it can never silently write to the placeholder URL).
        guard !isUntitled else { throw PaneSaveError.requiresSaveAs }
        try doc.save()
        refreshSavedStorage()
        // The reset is load-bearing here, not housekeeping: it ends the typing
        // series, so no batch undo can span the checkpoint this save just set
        // and the user can always come back to the saved state in one press
        // (§7.5.1).
        resetEditingState()
        rearmWatcher()
        // The dirty state just cleared — the header glyph and status bar must
        // flip back immediately, not on the next user action.
        notify()
    }

    func saveAs(to url: URL) throws {
        guard let doc = document else { return }
        try doc.save(to: url)
        // A Save As of an untitled document turns it into a real file: it gains
        // a watcher (none was needed while nothing existed on disk) and a saved
        // reference for modified-byte detection.
        isUntitled = false
        untitledName = nil
        refreshSavedStorage()
        resetEditingState()
        if changeWatcher == nil {
            startWatching(url)
        } else {
            rearmWatcher()
        }
        notify()
    }

    func revert() throws {
        guard let doc = document else { return }
        try doc.revert()
        refreshSavedStorage()
        resetEditingState()
        rearmWatcher()
        // Revert replaces the storage wholesale; the comparison must re-read.
        onFullInvalidation?()
        // The partition survives the revert, re-based onto the saved size (§21.2)
        // — the cuts and names the user set up are kept, not reset to one piece.
        preserveSegments(for: doc)
        // The matches do not: a revert replaces the bytes they were found in.
        clearMatches()
        notify()
        notifyCompanionContentFullyChanged()
    }

    /// The document's live byte storage — the same class instance across edits,
    /// so a comparison coordinator can hold it and always read current bytes.
    var byteStorage: (any ByteStorage)? { document?.storage }

    /// The byte ranges whose content is no longer the content the file held there
    /// — where editing wrote, plus everything after an insert or a delete, which
    /// moved. The save path uses the first kind to decide what to patch
    /// (`StorageSaver`, which only asks while nothing has shifted); the minimap's
    /// overview uses the whole answer to know which rows to compare against
    /// `savedStorage` instead of comparing the entire file (§19.4). Empty when
    /// nothing was edited.
    var editedRanges: [Range<UInt64>] {
        (document?.storage as? EditOverlayStorage)?.changedRanges ?? []
    }

    private func refreshSavedStorage() {
        defer { onSavedStateChanged?() }
        guard let doc = document else { savedStorage = nil; return }
        savedStorage = try? FileBackedStorage(url: doc.url)
    }

    private func startWatching(_ url: URL) {
        changeWatcher?.stop()
        let watcher = FileChangeWatcher(url: url)
        changeWatcher = watcher
        watcher.onChange = { [weak self] in
            self?.handleExternalChange()
        }
    }

    private func handleExternalChange() {
        guard isOpen else { return }
        if Self.clock() < externalChangeSuppressedUntil { return }
        onExternalChange?()
    }

    /// Re-arms the watcher after the app itself wrote the file: its own write
    /// events are suppressed for a moment, and the descriptor is rebound because
    /// an atomic save may have replaced the inode.
    private func rearmWatcher() {
        externalChangeSuppressedUntil = Self.clock() + Self.ownWriteSuppressionWindow
        changeWatcher?.rebind(to: document?.url)
    }

    private func resetEditingState() {
        breakTypingSeries()
        nibble = 0
        inputRegion = .hex
        overwriteSelection = nil
        selectionAnchor = nil
        pendingInsertOffset = nil
    }

    // MARK: - Segments (§21)

    /// Resets the partition to one piece — the whole file — named after it,
    /// clears the snapshot stacks, and wires the document's transaction hook so
    /// the stacks stay parallel to the undo stack. Called on open and close,
    /// where a fresh file genuinely is one piece (revert re-bases instead — see
    /// `preserveSegments`).
    private func resetSegments(for doc: BinaryDocument) {
        segmentStore.reset(size: doc.size, name: doc.url.lastPathComponent)
        segmentUndoStack.removeAll()
        segmentRedoStack.removeAll()
        pendingSegmentSnapshot = nil
        doc.onTransactionCommitted = { [weak self] in
            self?.segmentTransactionCommitted()
        }
        // A change to the partition repaints the rows it touches (§21.3): the
        // tint is the only thing that moves, so the content-change channel
        // invalidates exactly those rows. Set after the reset so the reset's own
        // change does not fire a redundant invalidation while the pane is still
        // being set up.
        segmentStore.onChange = { [weak self] range in
            self?.notify(contentChange: .bytes(in: range))
            self?.onSegmentsChanged?()
        }
    }

    /// Keeps the partition across a Revert to Saved, re-basing it onto the saved
    /// size (§21.2): the cuts and names the user set up survive, and any cut past
    /// the new end is dropped. The snapshot stacks are cleared — `doc.revert()`
    /// reset the byte-edit history they run parallel to, so keeping them would
    /// leave stale snapshots that pair with no undo step. The document's
    /// transaction hook and the store's change hook were wired on open and
    /// survive the revert, so there is nothing to re-set.
    private func preserveSegments(for doc: BinaryDocument) {
        segmentStore.rebase(to: doc.size)
        segmentUndoStack.removeAll()
        segmentRedoStack.removeAll()
        pendingSegmentSnapshot = nil
    }

    /// Captures the partition before an edit lands, so the transaction the edit
    /// commits can be undone back to it (§21.2). Called from every forward-edit
    /// path **before** the document mutation, because the mutation is what
    /// commits the transaction (firing `onTransactionCommitted`); the capture
    /// must precede that or the snapshot is taken one edit too late. A coalesced
    /// typing group captures once — on its first nibble — and keeps that
    /// snapshot, so the whole group undoes to the state before its first byte.
    private func beginSegmentEdit() {
        guard document != nil, pendingSegmentSnapshot == nil else { return }
        pendingSegmentSnapshot = segmentStore.snapshot()
    }

    /// Applies the net edit to the pane's segment partition, moving the cuts
    /// with the content (§21.2). Called from every forward-edit path **after**
    /// the document mutation, with the same `DiffEdit` the comparison index
    /// consumes (§8.3) and the file's post-edit size. Not called for undo/redo —
    /// those restore by snapshot, not by inverse edit.
    private func applySegmentEdit(_ edit: DiffEdit) {
        guard let doc = document else { return }
        segmentStore.apply(edit, newSize: doc.size)
    }

    /// Pushes the captured pre-edit snapshot onto the undo stack when the
    /// gesture's transaction commits, and drops the redo side (the state has
    /// diverged). No-op when the gesture was cancelled and left no snapshot.
    private func segmentTransactionCommitted() {
        guard let snapshot = pendingSegmentSnapshot else { return }
        pendingSegmentSnapshot = nil
        segmentUndoStack.append(snapshot)
        segmentRedoStack.removeAll()
    }

    /// Discards a captured snapshot whose gesture was cancelled (no transaction
    /// recorded), so it cannot leak into the next edit.
    private func discardPendingSegmentSnapshot() {
        pendingSegmentSnapshot = nil
    }

    /// Restores the partition after an undo that reverted `step` transactions —
    /// one step, which may be a fast-undo batch of several series bytes. The
    /// transactions move from the undo side to the redo side, and their
    /// snapshots move with them: the undo side keeps one *before* snapshot per
    /// transaction, the redo side one *after* snapshot per transaction. Because
    /// `before(tᵢ₊₁) == after(tᵢ)`, the redo side's snapshots are the popped
    /// ones minus the earliest, plus the current state (the batch's end). The
    /// store returns to the earliest — the state the step began from.
    private func undoSegments(step: Int) {
        guard step > 0 else { return }
        let popped = Array(segmentUndoStack.suffix(step))
        segmentUndoStack.removeLast(min(step, segmentUndoStack.count))
        let afterStates = popped.dropFirst()
        segmentRedoStack.append(contentsOf: afterStates)
        segmentRedoStack.append(segmentStore.snapshot())   // after(t_last) = current
        segmentStore.restore(popped.first ?? segmentStore.snapshot())
    }

    /// Restores the partition after a redo that reapplied `step` transactions —
    /// one step, unfolded back into individual byte steps by the document. The
    /// inverse of `undoSegments`: the redo side's *after* snapshots become the
    /// undo side's *before* snapshots (`before(t₁) == current`,
    /// `before(tᵢ₊₁) == after(tᵢ)`), and the store returns to the latest — the
    /// state the step ended in.
    private func redoSegments(step: Int) {
        guard step > 0 else { return }
        let popped = Array(segmentRedoStack.suffix(step))
        segmentRedoStack.removeLast(min(step, segmentRedoStack.count))
        segmentUndoStack.append(segmentStore.snapshot())   // before(t₁) = current
        segmentUndoStack.append(contentsOf: popped.dropLast())
        segmentStore.restore(popped.last ?? segmentStore.snapshot())
    }

    /// Moves the caret's input region to `region` (set when the user clicks the
    /// hex or ASCII area).
    func setInputRegion(_ region: HexInputRegion) {
        guard inputRegion != region else { return }
        inputRegion = region
        // A region change breaks the typing series *and* closes the nibble
        // group: the byte typed after it is a different byte, so it must not
        // coalesce into the same undo step as the half-typed one left behind
        // (see `moveCaret(to:)`).
        breakTypingSeries()
        // A region change only moves the caret bar between the hex and ASCII
        // columns — the bytes are unchanged, so a selection-only redraw
        // suffices (§3.3). The guard matters on the drag hot path:
        // `mouseDragged` calls this on every event, and an unconditional full
        // `notify()` there would rebuild and repaint the whole pane on each
        // one, re-introducing the drag lag on tall windows.
        notify(selectionChangedOnly: true)
    }

    // MARK: - HexViewDataSource

    var fileSize: UInt64 { document?.size ?? 0 }

    /// The comparison's extent: this pane scrolls as far as the longer of the
    /// two files, so a synchronized offset past this file's EOF is still
    /// reachable and shows empty rows (§9). Equal to `fileSize` in single-file
    /// mode, where there is no companion.
    var scrollExtent: UInt64 { max(fileSize, companion?.fileSize ?? 0) }

    func hexByteStates(in range: Range<UInt64>) -> [HexByteState] {
        guard let doc = document, range.lowerBound < range.upperBound else { return [] }
        let count = Int(range.upperBound - range.lowerBound)
        var states = [HexByteState](repeating: HexByteState(isEOF: true), count: count)

        let size = doc.size
        let start = min(range.lowerBound, size)
        guard start < size else { return states }
        let presentCount = Int(size - start)
        let n = min(count, presentCount)

        let current = (try? doc.read(at: start, length: n)) ?? []
        let saved = (try? savedStorage?.read(at: start, length: n)) ?? []
        let savedSize = savedStorage?.size ?? 0
        // Live visible diff (§8.3 rule 6): read the companion's bytes for the
        // same absolute range. Immediate, exact, and self-consistent with the
        // background block index (which only drives navigation).
        let other = companionBytes(in: start..<start + UInt64(n))
        let otherSize = companion?.fileSize ?? 0

        for i in 0..<n {
            let offset = start + UInt64(i)
            let byte = current.indices.contains(i) ? current[i] : 0
            var isModified = false
            if !isUntitled {
                // Untitled documents have no on-disk reference — every byte
                // would compare "modified". The dirty marker in the header and
                // status bar already conveys "unsaved", so no red foreground.
                if offset >= savedSize {
                    isModified = true
                } else if saved.indices.contains(i) {
                    isModified = saved[i] != byte
                }
            }
            var isDifferent = false
            if let other {
                if offset >= otherSize {
                    // Only this pane has a byte here — EOF-only difference (§8.1).
                    isDifferent = true
                } else if other.indices.contains(i) {
                    isDifferent = other[i] != byte
                }
            }
            states[Int(offset - range.lowerBound)] = HexByteState(
                byte: byte, isModified: isModified, isDifferent: isDifferent, isEOF: false
            )
        }
        return states
    }

    /// The companion pane's bytes for `range`, or nil when not in comparison
    /// mode. Reads fewer bytes than requested past the companion's EOF.
    private func companionBytes(in range: Range<UInt64>) -> [UInt8]? {
        guard let other = companion, let doc = other.document else { return nil }
        return (try? doc.read(at: range.lowerBound, length: Int(range.count))) ?? []
    }

    /// The bookmarked rows in `range` (a range of offsets), for the offset
    /// column's per-row drawing (§20). A set per range rather than a call per
    /// row, the same shape as `hexByteStates`. Empty when the pane has no
    /// store behind it.
    func hexBookmarkedRows(in range: Range<UInt64>) -> Set<UInt64> {
        bookmarkStore?.rows(in: range) ?? []
    }

    /// The segment pieces in `range`, with the palette index that tints each,
    /// for the row's background tint (§21.3). Empty when the pane is one piece
    /// (no cuts): a single colour over a whole file is noise, and the readout
    /// appearing at all is the signal that the dump is partitioned.
    func hexMatchRanges(in range: Range<UInt64>) -> [Range<UInt64>] {
        matchRanges(intersecting: range)
    }

    func hexCurrentMatch() -> Range<UInt64>? {
        currentMatchRange
    }

    func hexSegmentSpans(in range: Range<UInt64>) -> [HexSegmentSpan] {
        // One partition value per paint job: the whole drawn range tints from a
        // single `current`, so the page cannot split across two boundaries if a
        // cut lands mid-draw (§21.3).
        let current = segmentStore.current
        guard current.pieces.count > 1 else { return [] }
        return current.segments
            .filter { $0.range.overlaps(range) }
            .map { HexSegmentSpan(range: $0.range,
                                  colorIndex: $0.index % HexTheme.segmentTints.count) }
    }

    /// The bookmark on the row containing `offset` (§20.2) — what the mark's
    /// tooltip and VoiceOver read, and what tells a right-clicked address from
    /// an unmarked one.
    func hexBookmark(atRowContaining offset: UInt64) -> Bookmark? {
        bookmarkStore?.bookmark(atRowContaining: offset)
    }

    func hexSelection() -> SelectionModel {
        document?.selection ?? SelectionModel.empty(at: 0, fileSize: 0)
    }

    /// The byte the caret logically occupies for reveal purposes: the *moving*
    /// edge of the selection — the last byte when it was extended forward
    /// (anchor at the start), the first byte when extended backward (anchor at
    /// the end). A bare caret is its own edge. The view keeps this byte on
    /// screen, so extending a selection follows the edge being dragged, not the
    /// fixed anchor (§10.4).
    func hexCaretRevealOffset() -> UInt64 {
        guard let doc = document else { return 0 }
        // Typing over a selection consumes it from the start, one byte at a
        // time (§7.4), so while that is running the byte worth keeping on
        // screen is the one about to be written — not the selection's far edge.
        // This is §10.4's stated exception for typing over a selection.
        if let overwrite = overwriteSelection { return overwrite.start }
        let sel = doc.selection
        if sel.isEmpty { return sel.start }
        if let anchor = selectionAnchor, anchor == sel.end {
            return sel.start          // extended backward: the first byte is active
        }
        guard selectionAnchor != nil else {
            // Installed wholesale rather than dragged out: there is no moving
            // edge, so the block's start is the byte worth showing.
            return sel.start
        }
        return sel.end - 1            // extended forward: the last byte
    }

    func hexCaretNibble() -> Int { nibble }

    func hexInputRegion() -> HexInputRegion { inputRegion }

    /// Whether the caret should be drawn. Hidden while a block is selected and
    /// the user is not typing into it — the selection fill already shows the
    /// active region; visible when the selection is empty or when typing is
    /// consuming the selection, so the caret marks the next byte to land (§7.4).
    var hexCaretVisible: Bool {
        guard let doc = document else { return false }
        return doc.selection.isEmpty || overwriteSelection != nil
    }

    /// The pane's typing mode — the hex view draws the insert-mode caret (a red
    /// vertical line at the byte boundary) when this is true.
    var hexInsertMode: Bool { isInsertMode }

    /// Whether the caret sits on a byte whose high nibble was just inserted in
    /// insert mode and the low nibble is still pending — a genuine half-typed
    /// byte, as opposed to a mid-byte caret a click placed. The view shows the
    /// dim `_` placeholder in the low-nibble slot only in this state (§7): a
    /// click merely places the caret, it does not blank the byte.
    var hexHasPendingInsert: Bool {
        guard let doc = document else { return false }
        return pendingInsertOffset == doc.selection.start
    }

    /// The companion pane's selection, clamped to this pane's file size — what
    /// this pane's hex view frames to mirror the opposite pane (§3.3). Nil in
    /// single-file mode (no companion).
    func hexMirroredSelection() -> SelectionModel? {
        guard let doc = document, let other = companion else { return nil }
        return other.hexSelection().clamped(to: doc.size)
    }

    // MARK: - Status

    var status: PaneStatus {
        // The typing mode belongs to the pane, not to its document: it survives
        // a file being closed and reopened, so it is reported either way.
        guard let doc = document else { return PaneStatus(isInsertMode: isInsertMode) }
        let caret = doc.selection.start
        return PaneStatus(
            fileName: isUntitled ? (untitledName ?? "Untitled") : doc.url.lastPathComponent,
            fileSize: doc.size,
            cursorOffset: caret,
            selectionLength: doc.selection.count,
            isDirty: doc.isDirty,
            isReadOnly: doc.readOnly,
            isUntitled: isUntitled,
            canUndo: doc.canUndo,
            canRedo: doc.canRedo,
            isInsertMode: isInsertMode,
            segment: segmentReadout(caret: caret)
        )
    }

    /// The status bar's readout of the piece the caret is in (§21.3) — nil when
    /// the pane is a single piece, where the readout's absence is the signal
    /// that the dump is not partitioned.
    private func segmentReadout(caret: UInt64) -> SegmentReadout? {
        let current = segmentStore.current
        guard current.pieces.count > 1,
              let piece = current.segment(containing: caret) else { return nil }
        return SegmentReadout(label: piece.label, range: piece.range)
    }

    var caretOffset: UInt64 { document?.selection.start ?? 0 }

    // MARK: - Hex input (§7)

    /// The one-time insert-mode warning. Returns `true` to proceed with the
    /// keystroke, `false` to swallow it (the user cancelled). Shown once per
    /// opened file; a cancelled warning does not set the flag, so the next
    /// keystroke re-asks. A nil presenter (pure unit tests) proceeds without
    /// asking.
    private func confirmFirstInsertModeEdit() -> Bool {
        guard isInsertMode, !hasWarnedInsertShift,
              let confirm = confirmInsertModeWarning else { return true }
        guard confirm() else { return false }   // user cancelled → swallow the keystroke
        hasWarnedInsertShift = true
        return true
    }

    /// Collapses a selection to its start before an insert-mode byte lands
    /// there. Insert mode does not consume a selection the way overwrite typing
    /// does (§7.4 is an overwrite rule), and a selection left standing would go
    /// on highlighting a span whose bytes have since shifted right — the
    /// highlight would name bytes the user never selected. Dropping it also
    /// clears any consuming state a mode switch left behind mid-selection.
    private func dropSelectionForInsert() {
        guard let doc = document else { return }
        overwriteSelection = nil
        guard !doc.selection.isEmpty else { return }
        doc.setSelection(SelectionModel.empty(at: doc.selection.start, fileSize: doc.size))
    }

    /// Types one hex digit (0–15) into the current nibble (§7: hex nibble
    /// input; after the second nibble the caret advances to the next byte).
    /// The two nibbles of a byte coalesce into one undo step.
    ///
    /// In insert mode the **first** digit inserts a new byte at the caret with
    /// the high nibble set and the low nibble empty (the tail shifts right),
    /// and the **second** digit fills the low nibble in place (an overwrite)
    /// and advances. The pair coalesces into one undo step via the same edit
    /// group as overwrite mode.
    func typeHexNibble(_ digit: Int) {
        guard let doc = document, (0...15).contains(digit),
              confirmFirstInsertModeEdit() else { return }
        let sizeBefore = doc.size

        if isInsertMode {
            // Typing inserts before the caret; it never consumes a selection,
            // so `prepareForTyping` is skipped.
            if nibble == 0 { dropSelectionForInsert() }
            let offset = typingOffset(doc)
            if nibble == 0 {
                // High nibble: insert a new byte at the caret with the high
                // nibble set and the low nibble empty (0); the tail shifts
                // right. `doc.insert` leaves the caret at `offset` (on the new
                // byte) so the next digit fills it — no advance here.
                ensureTypingSeries(mode: inputRegion)
                beginTypingGroup()
                beginSegmentEdit()
                try? doc.insert(at: offset, bytes: [UInt8(digit) << 4])
                nibble = 1
                pendingInsertOffset = offset
                lastTypingTime = Self.clock()
                onEdit?(.insert(at: offset, length: 1))
                applySegmentEdit(.insert(at: offset, length: 1))
                notifyAfterEdit(range: offset..<offset + 1, sizeBefore: sizeBefore)
                notifyCompanionContentFullyChanged()
                return
            } else {
                // Low nibble: fill the byte's low nibble in place (an
                // overwrite, no new insertion) and advance past it.
                let old = byteAt(offset) ?? 0
                beginSegmentEdit()
                try? doc.overwrite(range: offset..<offset + 1, with: [(old & 0xF0) | UInt8(digit)])
                nibble = 0
                pendingInsertOffset = nil
                endTypingGroup()
                advanceAfterByte()
                lastTypingTime = Self.clock()
                onEdit?(.overwrite(range: offset..<offset + 1))
                applySegmentEdit(.overwrite(range: offset..<offset + 1))
                notifyAfterEdit(range: offset..<offset + 1, sizeBefore: sizeBefore)
                return
            }
        }

        let offset: UInt64
        if nibble == 0 {
            prepareForTyping()
            ensureTypingSeries(mode: inputRegion)
            offset = typingOffset(doc)
            let old = byteAt(offset) ?? 0
            beginTypingGroup()
            beginSegmentEdit()
            try? doc.overwrite(range: offset..<offset + 1, with: [(UInt8(digit) << 4) | (old & 0x0F)])
            nibble = 1
            lastTypingTime = Self.clock()
            onEdit?(.overwrite(range: offset..<offset + 1))
            applySegmentEdit(.overwrite(range: offset..<offset + 1))
        } else {
            offset = typingOffset(doc)
            let old = byteAt(offset) ?? 0
            beginSegmentEdit()
            try? doc.overwrite(range: offset..<offset + 1, with: [(old & 0xF0) | UInt8(digit)])
            nibble = 0
            endTypingGroup()
            advanceAfterByte()
            lastTypingTime = Self.clock()
            onEdit?(.overwrite(range: offset..<offset + 1))
            applySegmentEdit(.overwrite(range: offset..<offset + 1))
        }
        notifyAfterEdit(range: offset..<offset + 1, sizeBefore: sizeBefore)
    }

    /// Types one decoded-text character. The HexView validates the character
    /// through `textDecoder.encode(_)` before calling this, so any byte that
    /// arrives here is representable in the current code page. A whole-byte
    /// edit: one undo step. In insert mode the byte is inserted at the caret
    /// (the tail shifts right) instead of overwriting.
    func typeASCII(_ byte: UInt8) {
        guard let doc = document, confirmFirstInsertModeEdit() else { return }
        let sizeBefore = doc.size
        endTypingGroup()
        if isInsertMode {
            // Insert a whole byte at the caret; the tail shifts right. Skip
            // `prepareForTyping` — insert never consumes a selection.
            dropSelectionForInsert()
            ensureTypingSeries(mode: inputRegion)
            let offset = typingOffset(doc)
            beginSegmentEdit()
            try? doc.insert(at: offset, bytes: [byte])
            nibble = 0
            advanceAfterByte()
            lastTypingTime = Self.clock()
            onEdit?(.insert(at: offset, length: 1))
            applySegmentEdit(.insert(at: offset, length: 1))
            notifyAfterEdit(range: offset..<offset + 1, sizeBefore: sizeBefore)
            notifyCompanionContentFullyChanged()
            return
        }
        prepareForTyping()
        ensureTypingSeries(mode: inputRegion)
        let offset = typingOffset(doc)
        beginSegmentEdit()
        try? doc.overwrite(range: offset..<offset + 1, with: [byte])
        nibble = 0
        advanceAfterByte()
        lastTypingTime = Self.clock()
        onEdit?(.overwrite(range: offset..<offset + 1))
        applySegmentEdit(.overwrite(range: offset..<offset + 1))
        notifyAfterEdit(range: offset..<offset + 1, sizeBefore: sizeBefore)
    }

    /// Delete: in overwrite mode it fills the selection (or the current byte)
    /// with 0x00 (§7.3). In insert mode it removes the selection (or the byte at
    /// the caret) and shifts the tail left (§7.6) — the same length-changing
    /// delete Backspace performs there, guarded by the same one-time warning.
    func deleteForward() {
        guard let doc = document else { return }
        if isInsertMode {
            guard confirmFirstInsertModeEdit() else { return }
            breakTypingSeries()
            guard let range = deletionRange(forward: true) else { return }
            deleteShiftingTail(range)
            return
        }
        breakTypingSeries()
        if !doc.selection.isEmpty {
            fillSelection()
            return
        }
        let sizeBefore = doc.size
        let caret = doc.selection.start
        guard caret < doc.size else { return }
        // Forward delete fills a byte but leaves the caret put — redo must too.
        beginSegmentEdit()
        try? doc.fillZero(in: caret..<caret + 1, caretAfter: caret)
        nibble = 0
        onEdit?(.overwrite(range: caret..<caret + 1))
        applySegmentEdit(.overwrite(range: caret..<caret + 1))
        notifyAfterEdit(range: caret..<caret + 1, sizeBefore: sizeBefore)
    }

    /// Backspace. In overwrite mode it fills the selection (or the previous
    /// byte) with 0x00 and moves the caret back (§7.3). In insert mode it
    /// removes the selection — or, with none, the byte before the caret — and
    /// shifts the tail left (§7.6). A half-typed insert-mode byte is rolled back
    /// instead (see `rollbackPendingInsert`).
    func deleteBackward() {
        guard let doc = document else { return }
        // Insert mode, caret on a half-typed byte (high nibble just inserted,
        // low nibble still pending): Backspace rolls the first nibble back — the
        // inserted byte is removed, the tail shifts left, and the open edit
        // group is cancelled so nothing lands on the undo stack, as if the
        // first nibble was never entered. No warning: this takes back the user's
        // own keystroke, it does not shift anything that was not just shifted.
        if isInsertMode, nibble == 1, pendingInsertOffset == doc.selection.start {
            rollbackPendingInsert()
            return
        }
        if isInsertMode {
            guard confirmFirstInsertModeEdit() else { return }
            breakTypingSeries()
            guard let range = deletionRange(forward: false) else { return }
            deleteShiftingTail(range)
            return
        }
        breakTypingSeries()
        if !doc.selection.isEmpty {
            fillSelection()
            return
        }
        let sizeBefore = doc.size
        let caret = doc.selection.start
        guard caret > 0 else { return }
        // Overwrite mode: fill the previous byte with 0x00 and step back one —
        // redo must land there too, not at the (unmoved) caret.
        beginSegmentEdit()
        try? doc.fillZero(in: (caret - 1)..<caret, caretAfter: caret - 1)
        doc.setSelection(SelectionModel.empty(at: caret - 1, fileSize: doc.size))
        nibble = 0
        onEdit?(.overwrite(range: (caret - 1)..<caret))
        applySegmentEdit(.overwrite(range: (caret - 1)..<caret))
        notifyAfterEdit(range: (caret - 1)..<caret, sizeBefore: sizeBefore)
    }

    /// What an insert-mode Delete or Backspace removes: the selection if there
    /// is one — in a mode where these keys shift the tail, a selected span goes
    /// as a whole, the way it would in a text editor — otherwise the single byte
    /// at (Delete) or before (Backspace) the caret. Nil when there is nothing
    /// there: Backspace at offset 0, Delete at EOF.
    private func deletionRange(forward: Bool) -> Range<UInt64>? {
        guard let doc = document else { return nil }
        if !doc.selection.isEmpty { return doc.selection.start..<doc.selection.end }
        let caret = doc.selection.start
        if forward {
            guard caret < doc.size else { return nil }
            return caret..<caret + 1
        }
        guard caret > 0 else { return nil }
        return (caret - 1)..<caret
    }

    /// Removes `range` and shifts the tail left: a real length-changing delete,
    /// so it records its own undo step and repaints the companion's difference
    /// background (every offset from here on moved). The caret lands where the
    /// removed bytes were, which is where redo must put it too.
    private func deleteShiftingTail(_ range: Range<UInt64>) {
        guard let doc = document else { return }
        let sizeBefore = doc.size
        beginSegmentEdit()
        try? doc.delete(range: range)
        doc.setSelection(SelectionModel.empty(at: range.lowerBound, fileSize: doc.size))
        nibble = 0
        overwriteSelection = nil
        pendingInsertOffset = nil
        onEdit?(.delete(range: range))
        applySegmentEdit(.delete(range: range))
        notifyAfterEdit(range: range, sizeBefore: sizeBefore)
        notifyCompanionContentFullyChanged()
    }

    /// Rolls back a half-typed insert-mode byte (Backspace on the pending first
    /// nibble): reverts the high-nibble insert — the byte disappears and the
    /// tail shifts left — and cancels the open edit group so no undo step is
    /// recorded. The caret returns to where it was before the insert, as if the
    /// first nibble was never entered.
    private func rollbackPendingInsert() {
        guard let doc = document else { return }
        let offset = doc.selection.start
        let sizeBefore = doc.size
        try? doc.cancelEditGroup()
        // The document has closed the group; the pane must agree, or the next
        // `beginTypingGroup` skips `beginEditGroup` (it still thinks a group is
        // open) and the following `endTypingGroup` drives the document's group
        // depth negative — after which no byte's two nibbles ever coalesce
        // again, in either mode, for the rest of the document's life.
        typingGroupOpen = false
        pendingInsertOffset = nil
        nibble = 0
        onEdit?(.delete(range: offset..<offset + 1))
        // Revert the high-nibble insert in the partition, then drop the captured
        // snapshot: the group was cancelled, so no transaction committed and the
        // snapshot must not leak into the next edit.
        applySegmentEdit(.delete(range: offset..<offset + 1))
        discardPendingSegmentSnapshot()
        notifyAfterEdit(range: offset..<offset + 1, sizeBefore: sizeBefore)
        notifyCompanionContentFullyChanged()
    }

    /// Fill Selection with… (menu command, §7.3): repeats `pattern` across the
    /// selection.
    func fillSelection(with pattern: [UInt8]) {
        guard let doc = document, !doc.selection.isEmpty, !pattern.isEmpty else { return }
        breakTypingSeries()
        fillSelection(pattern: pattern)
    }

    /// True length-changing delete (Edit > Delete Bytes…, §7.2, confirmed by
    /// the UI before calling).
    func deleteBytes(in range: Range<UInt64>) throws {
        guard let doc = document else { return }
        breakTypingSeries()
        beginSegmentEdit()
        try doc.delete(range: range)
        doc.setSelection(SelectionModel.empty(at: range.lowerBound, fileSize: doc.size))
        doc.noteSelectionAfterEdit()
        nibble = 0
        overwriteSelection = nil
        onEdit?(.delete(range: range))
        applySegmentEdit(.delete(range: range))
        notify()
        notifyCompanionContentFullyChanged()
    }

    /// Paste Write: overwrite from the caret (or selection start), extending
    /// past EOF without confirmation (§7.1, §12.2).
    func pasteWrite(_ bytes: [UInt8]) throws {
        guard let doc = document, !bytes.isEmpty else { return }
        // Break the series BEFORE recording: the paste's own transaction must
        // not inherit the typing series' id.
        breakTypingSeries()
        let sizeBefore = doc.size
        let start = doc.selection.start
        let range = start..<start + UInt64(bytes.count)
        beginSegmentEdit()
        try doc.overwrite(range: range, with: bytes)
        doc.setSelection(SelectionModel.empty(at: range.upperBound, fileSize: doc.size))
        resetEditingState()
        // The engine's `.overwrite` recomputes `[start, end)`, which covers the
        // paste even when it extends past EOF (the recompute reads current bytes).
        onEdit?(.overwrite(range: range))
        applySegmentEdit(.overwrite(range: range))
        // A paste that extends past EOF grows the file, so the layout (frame
        // height, caret row) must rebuild — `notifyAfterEdit` handles that.
        notifyAfterEdit(range: range, sizeBefore: sizeBefore)
    }

    /// Paste Insert: insert before the caret (confirmed by the UI, §7.2/§12.3).
    func pasteInsert(_ bytes: [UInt8]) throws {
        guard let doc = document, !bytes.isEmpty else { return }
        // Break the series BEFORE recording: the paste's own transaction must
        // not inherit the typing series' id.
        breakTypingSeries()
        let at = doc.selection.start
        beginSegmentEdit()
        try doc.insert(at: at, bytes: bytes)
        doc.setSelection(SelectionModel.empty(at: at + UInt64(bytes.count), fileSize: doc.size))
        doc.noteSelectionAfterEdit()
        resetEditingState()
        onEdit?(.insert(at: at, length: UInt64(bytes.count)))
        applySegmentEdit(.insert(at: at, length: UInt64(bytes.count)))
        notify()
        notifyCompanionContentFullyChanged()
    }

    // MARK: - Replace a piece from a file (§21.6)

    /// Replaces `piece`'s bytes with the contents of the file at `url`, which
    /// must match the piece's length (§21.6). The file is opened as the chunked
    /// reader and streamed in, so it is never loaded whole into RAM.
    func replaceSegment(_ piece: Segment, withContentsOf url: URL) throws {
        let donor = try FileBackedStorage(url: url)
        try replaceSegment(piece, withContentsOf: donor)
    }

    /// The chunked, same-length swap, given an already-open donor (§21.6). The
    /// donor must match the piece's length; the whole swap is one transaction, so
    /// undo takes it back as one step. A same-length overwrite moves no cut, so
    /// there is no `applySegmentEdit` — only the content-change repaint.
    func replaceSegment(_ piece: Segment, withContentsOf donor: any ByteStorage) throws {
        guard let doc = document else { return }
        breakTypingSeries()
        let sizeBefore = doc.size
        beginSegmentEdit()
        do {
            try SegmentReplacer.replace(range: piece.range, in: doc, withContentsOf: donor)
        } catch {
            // The gesture recorded nothing (a refused length, or a mid-stream
            // failure rolled back), so the captured snapshot must not leak into
            // the next edit.
            discardPendingSegmentSnapshot()
            throw error
        }
        // The engine's `.overwrite` recomputes the range, which covers the swap
        // (a same-length overwrite, so the size is unchanged).
        onEdit?(.overwrite(range: piece.range))
        notifyAfterEdit(range: piece.range, sizeBefore: sizeBefore)
        notifyCompanionContentFullyChanged()
    }

    // MARK: - Join a file (§22)

    /// Joins the file at `url` into this pane's content, at the start or the end
    /// (§22.1). The file is opened as the chunked reader and streamed in, so it
    /// is never loaded whole into RAM. The joined piece is named for the file it
    /// came from (§22.3).
    func join(contentsOf url: URL, at position: JoinPosition,
              becoming joinedName: String? = nil) throws {
        try join(contentsOf: FileBackedStorage(url: url),
                 named: url.lastPathComponent,
                 at: position,
                 becoming: joinedName)
    }

    /// The chunked join, given an already-open source and the name to give the
    /// joined piece (§22). The join is a document-level act, not an edit
    /// (§22.2): it detaches the document from the file it came from (the result
    /// is untitled and never-saved), but it is undoable — the byte insert is one
    /// undo step on top of any earlier edits, and undoing it re-attaches the
    /// document to the file it left. The document is left dirty so a close still
    /// warns. The seam is a cut (§22.3): the content the pane already held keeps
    /// the name of the file it was opened from, and the joined bytes take
    /// `sourceName`.
    /// `joinedName` is the name the detached image takes — the pane's own name
    /// with a series suffix (§22.2). The caller derives it, because the series
    /// has to step over the names in use across the whole app and a pane can see
    /// only its own window. Nil leaves the image unnamed, which is what a pane
    /// that had already detached wants: it keeps what it is wearing.
    func join(contentsOf source: any ByteStorage, named sourceName: String,
              at position: JoinPosition, becoming joinedName: String? = nil) throws {
        guard let doc = document else { return }
        breakTypingSeries()
        let sizeBefore = doc.size
        let sourceSize = source.size
        // The join commits one transaction, and it is undoable (§22.2): capture
        // the pre-join partition so the transaction's commit (fired by
        // `onTransactionCommitted` inside `doc.join`) pushes it onto the
        // segment undo stack — undoing the join then restores the partition to
        // what it was. The seam cut and renames below are the post-join state.
        beginSegmentEdit()
        try doc.join(contentsOf: source, at: position)
        // The insert moves the partition with the content and grows the content
        // size (§21.2). This must run before the seam cut below: a cut is
        // refused at the content's end, and for an append the seam IS the old
        // end. For an insert at the start the new bytes join the piece that
        // opens at 0, so the cut at the seam then splits them off as their own
        // piece.
        let edit: DiffEdit = (position == .start) ? .insert(at: 0, length: sourceSize)
                                                  : .insert(at: sizeBefore, length: sourceSize)
        applySegmentEdit(edit)
        // The seam is a cut (§22.3): the insert left one piece spanning the
        // joined content, so a cut at the seam splits it, and the renames put
        // each half under the right name.
        if sizeBefore == 0 {
            // The pane was empty: the whole content is the source, so the one
            // piece takes the source's name (there is no original content to
            // name, and a cut at 0 or at EOF would be refused).
            segmentStore.rename(0, to: sourceName)
        } else {
            let seam = (position == .start) ? sourceSize : sizeBefore
            // For an insert at the start the cut splits the piece that opens at
            // 0: the earlier half (the new bytes) keeps that piece's name and
            // the later half (the original content) is left unnamed. So the
            // original name is remembered from the piece before the cut — not
            // from the document's URL, which is already untitled after a first
            // join (§22.3: the content keeps the name it was opened with).
            let originalName = (position == .start) ? segmentStore.segments[0].name : ""
            segmentStore.addCut(at: seam)
            if position == .start {
                // Piece 0 is the joined bytes (take the source's name); piece 1
                // is the original content (addCut left it unnamed, so name it).
                segmentStore.rename(0, to: sourceName)
                segmentStore.rename(1, to: originalName)
            } else {
                // Piece 0 is the original content (addCut kept its name); piece
                // 1 is the joined bytes (take the source's name).
                segmentStore.rename(1, to: sourceName)
            }
        }
        // The caret sits at the start of the added part (§22.5) — `doc.join`
        // placed it there and recorded it as the transaction's post-edit
        // selection, so redo of the join restores the same spot (and undo
        // returns the pre-join caret). No caret work left for the pane.
        // The document detached: it is untitled now, with no on-disk reference
        // (the placeholder URL has no file behind it) and no watcher.
        //
        // It is not the file it came from, but it is that file with something
        // added, so it wears that file's name with a series suffix — `bios.bin`
        // becomes `bios-2.bin` (§22.2), the same shape a copy takes (§23), and
        // for the same reason: the header has to say which dump is on screen,
        // and Save All as Separate Files has to have a base name to build the
        // pieces from (§21.5).
        //
        // Only the first join names it. A pane that had already detached keeps
        // the name it is wearing: joining a second donor into an image does not
        // make a different image, and a name that stepped on every join would
        // count joins instead of naming what is on screen.
        let wasAttached = !isUntitled
        isUntitled = true
        if wasAttached { untitledName = joinedName }
        refreshSavedStorage()
        changeWatcher?.stop()
        changeWatcher = nil
        // The join is a length-changing edit: the whole pane repaints, the
        // comparison index shifts for the insert, and the companion's diff
        // background re-reads. It is a navigation command: the seam (the caret)
        // is centred if it landed outside the viewport (§10.4).
        onEdit?(edit)
        notify(reveal: .center)
        notifyCompanionContentFullyChanged()
    }

    // MARK: - Caret & selection

    func moveCaret(by delta: Int64, extendSelection: Bool = false, center: Bool = false) {
        guard let doc = document else { return }
        // Clearing a selection (no extend) collapses the caret to the selection's
        // *active edge* — the byte the caret logically sits on while the
        // selection is up (its last byte when extended forward, its first byte
        // when extended backward) — and drops the selection. The caret then
        // moves from there, so the first arrow after a selection continues from
        // where the selection ended, not from the edge the arrow points to
        // (§10.4).
        if !extendSelection, !doc.selection.isEmpty {
            moveCaret(to: hexCaretRevealOffset(), extendSelection: false, center: center)
            return
        }
        // The caret's live position is the selection's *moving* end, not its
        // normalized `start`: extending right keeps the anchor (the left edge)
        // fixed while the end moves, and extending left keeps the right edge
        // fixed while the start moves. Starting from `selection.start` in both
        // directions froze a forward extension at anchor+1 — repeated Shift+Right
        // went nowhere. A bare caret has start == end, so either edge is fine.
        let current: UInt64
        if extendSelection, let anchor = selectionAnchor, !doc.selection.isEmpty {
            current = (anchor == doc.selection.end) ? doc.selection.start : doc.selection.end
        } else {
            current = doc.selection.start
        }
        var target: UInt64
        if delta >= 0 {
            target = min(doc.size, current + UInt64(delta))
        } else {
            let amount = UInt64(-delta)
            target = amount > current ? 0 : current - amount
        }
        // Arrow/page keys are incremental navigation: the minimum scroll that
        // keeps the caret on screen — except when it was already out of view, in
        // which case the move centres it back (§10.4).
        moveCaret(to: target, extendSelection: extendSelection, center: center)
    }

    /// Moves the caret to `offset`. `center` (default `true`) marks it a
    /// navigation command: the view centres the caret if it landed outside the
    /// viewport (§10.4). Incremental callers — arrow keys, mouse, Home/End —
    /// pass `false` for the minimum-scroll follow.
    func moveCaret(to offset: UInt64, extendSelection: Bool = false, center: Bool = true) {
        guard let doc = document else { return }
        // Caret movement ends the byte being typed: it breaks the typing series
        // *and* closes the nibble group, so the half-typed byte left behind is
        // recorded as its own undo step.
        //
        // Leaving the group open here (what this used to do) meant a half-typed
        // byte stayed uncommitted in `pendingGroupOps` and glued itself to
        // whatever byte was typed next, at a different offset — one undo step
        // for two unrelated bytes. Worse, insert mode's Backspace rollback
        // cancels the open group, so it reverted that earlier byte too, with
        // nothing left on the undo stack to bring it back (§7.5.1).
        breakTypingSeries()
        let clamped = min(offset, doc.size)
        if extendSelection {
            let anchor = selectionAnchor
                ?? (clamped >= doc.selection.start ? doc.selection.start : doc.selection.end)
            selectionAnchor = anchor
            doc.setSelection(SelectionModel(start: anchor, end: clamped, fileSize: doc.size))
        } else {
            selectionAnchor = nil
            doc.setSelection(SelectionModel.empty(at: clamped, fileSize: doc.size))
        }
        nibble = 0
        overwriteSelection = nil
        // Moving the caret off a half-typed byte detaches it: the inserted byte
        // stays — now as a committed undo step of its own, thanks to the group
        // closing above — and Backspace no longer rolls it back from the new
        // position. Undo does.
        pendingInsertOffset = nil
        notify(selectionChangedOnly: true, reveal: center ? .center : .follow)
    }

    func selectAll() {
        guard let doc = document else { return }
        doc.setSelection(SelectionModel(start: 0, end: doc.size, fileSize: doc.size))
        resetEditingState()
        // Anchored at the start, so the selection reads as extended forward and
        // its active edge is the file's last byte — a following Shift+Left
        // shortens it from the end, the way a text editor's Select All behaves.
        // Set after `resetEditingState`, which clears the anchor.
        selectionAnchor = 0
        // No scroll: everything is selected, so there is nothing to go and look
        // at, and dragging a 64 MB dump's viewport to its end would only cost
        // the user their place.
        notify(selectionChangedOnly: true, reveal: .stay)
    }

    /// Installs `selection` wholesale. Does not scroll: every caller follows
    /// with its own centred reveal on the block's start (§10.2).
    func setSelection(_ selection: SelectionModel) {
        guard let doc = document else { return }
        doc.setSelection(selection)
        resetEditingState()
        notify(selectionChangedOnly: true, reveal: .stay)
    }

    /// Selects `range`, clamped to the file size (used by Find and Select
    /// Block). Does not scroll, for the same reason as `setSelection`.
    func select(range: Range<UInt64>) {
        guard let doc = document else { return }
        doc.setSelection(SelectionModel(start: range.lowerBound, end: range.upperBound, fileSize: doc.size))
        resetEditingState()
        notify(selectionChangedOnly: true, reveal: .stay)
    }

    // MARK: - Undo / Redo

    @discardableResult
    func undo() throws -> Bool {
        guard let doc = document else { return false }
        // Flush a pending typing group BEFORE undoing: a half-typed byte must be
        // committed so undo reverts it (and keeps the redo stack intact) instead
        // of skipping it for an older edit.
        resetEditingState()
        // The fast-undo window: a repeat press within `fastUndoWindow` of a
        // series-byte undo asks the history to remove the rest of the series in
        // one step (whether that happens is decided by `UndoHistory`).
        let now = Self.clock()
        let fast = lastUndoTime.map { now - $0 < Self.fastUndoWindow } ?? false
        lastUndoTime = now
        // The step's size in transactions — one normally, more for a fast-undo
        // batch — is the drop in the history's transaction count.
        let depthBefore = doc.undoHistory.undoDepth
        let attachedBefore = doc.isAttached
        let edit = try doc.undo(batch: fast)   // restores the caret to where the edit began
        if let edit {
            undoSegments(step: depthBefore - doc.undoHistory.undoDepth)
            // Undo mutates the storage in place, so the net DiffEdit updates the
            // comparison incrementally — no full-file re-scan (§8.3).
            onEdit?(edit)
            notifyCompanionContentChanged(edit)
        }
        // Undoing the join's transaction re-attaches the document (§22.2); the
        // pane owns the watcher and `isUntitled`, so it follows.
        if doc.isAttached != attachedBefore { syncAttachment() }
        // A navigation command: centre the restored caret if it landed outside
        // the viewport (§10.4).
        notify(reveal: .center)
        return edit != nil
    }

    @discardableResult
    func redo() throws -> Bool {
        guard let doc = document else { return false }
        resetEditingState()
        // Redo does not inherit the fast window: a redo followed quickly by an
        // undo is not a "repeat undo".
        lastUndoTime = nil
        // The step's size in transactions — the rise in the history's count, a
        // batch step unfolding back into its individual byte steps.
        let depthBefore = doc.undoHistory.undoDepth
        let attachedBefore = doc.isAttached
        let edit = try doc.redo()   // restores the caret to where the edit left it
        if let edit {
            redoSegments(step: doc.undoHistory.undoDepth - depthBefore)
            onEdit?(edit)
            notifyCompanionContentChanged(edit)
        }
        // Redoing the join's transaction re-detaches the document (§22.2); the
        // pane follows (see `undo`).
        if doc.isAttached != attachedBefore { syncAttachment() }
        // A navigation command: centre the restored caret if it landed outside
        // the viewport (§10.4).
        notify(reveal: .center)
        return edit != nil
    }

    /// Re-syncs the pane's file-attachment state after an undo/redo flipped the
    /// document's attachment (undoing or redoing a join, §22.2). The document
    /// re-attaches/re-detaches itself; the pane owns `isUntitled`, the watcher,
    /// and `savedStorage`, so it follows.
    private func syncAttachment() {
        guard let doc = document else { return }
        isUntitled = !doc.isAttached
        refreshSavedStorage()
        if doc.isAttached {
            // Re-attached: re-arm the watcher on the restored file.
            if changeWatcher == nil {
                startWatching(doc.url)
            } else {
                rearmWatcher()
            }
        } else {
            // Detached again (the join stands): no file to watch.
            changeWatcher?.stop()
            changeWatcher = nil
        }
    }

    // MARK: - Internals

    /// When a selection exists and the user types, switch to consuming it one
    /// byte at a time from its start (§7.4).
    private func prepareForTyping() {
        guard let doc = document else { return }
        if overwriteSelection == nil, !doc.selection.isEmpty {
            overwriteSelection = doc.selection
            nibble = 0
            // Show the still-unconsumed part of the selection shrinking as we type.
            doc.setSelection(SelectionModel(start: doc.selection.start, end: doc.selection.end, fileSize: doc.size))
            // The bytes land at the selection's START, which can be nowhere
            // near what the view is showing — after Select All, or any
            // selection made and then scrolled away from. Bring that byte into
            // view before the first one is written, or the user types blind.
            // Centred when it is off screen, left alone when it is already
            // visible (§10.4); the edits that follow go through the content
            // channel, which deliberately never scrolls.
            notify(selectionChangedOnly: true, reveal: .center)
        }
    }

    /// The offset the next typed byte lands on: selection start while a
    /// selection is being consumed, otherwise the caret.
    private func typingOffset(_ doc: BinaryDocument) -> UInt64 {
        overwriteSelection?.start ?? doc.selection.start
    }

    private func byteAt(_ offset: UInt64) -> UInt8? {
        guard let doc = document, offset < doc.size else { return nil }
        return (try? doc.read(at: offset, length: 1))?.first
    }

    /// Opens an edit group so the low nibble of the byte being typed coalesces
    /// with its high nibble into a single undo step (§7.5).
    private func beginTypingGroup() {
        guard let doc = document, !typingGroupOpen else { return }
        doc.beginEditGroup()
        typingGroupOpen = true
    }

    /// Closes the edit group opened by `beginTypingGroup`, if any. Called on
    /// every path that leaves the mid-byte state (nibble 1 pending), so a half
    /// typed byte never swallows a later unrelated edit into the same undo step.
    private func endTypingGroup() {
        guard let doc = document, typingGroupOpen else { return }
        doc.endEditGroup()
        typingGroupOpen = false
    }

    /// Opens (or continues) the typing series for the byte about to be
    /// completed in `mode` — called at the start of each byte (the high-nibble
    /// branch of hex input, the start of an ASCII character). A series breaks
    /// on a pause longer than `seriesBreakThreshold` since the last typed
    /// event, or on a change of input region; each new series gets a fresh id
    /// from the document so a fast undo can roll it back in one batch.
    private func ensureTypingSeries(mode: HexInputRegion) {
        guard let doc = document else { return }
        let now = Self.clock()
        if !typingSeriesOpen
            || now - lastTypingTime > Self.seriesBreakThreshold
            || lastTypingMode != mode {
            doc.endSeries()
            seriesCounter += 1
            doc.beginSeries(seriesCounter)
            typingSeriesOpen = true
        }
        lastTypingMode = mode
        lastTypingTime = now
    }

    /// Closes the typing series without touching the nibble group: caret
    /// movement and input-region changes break the series (the next typed byte
    /// starts a fresh one) but must not flush a half-typed byte.
    private func closeTypingSeries() {
        guard typingSeriesOpen, let doc = document else { return }
        doc.endSeries()
        typingSeriesOpen = false
        lastTypingMode = nil
    }

    /// Breaks the typing series: closes a half-typed byte (flushing its edit
    /// group) and ends the series on the document, so the next typed byte
    /// starts a fresh series. Called by every command that is not plain typing
    /// (delete, fill, paste, selection changes, undo/redo).
    private func breakTypingSeries() {
        endTypingGroup()
        closeTypingSeries()
    }

    /// After a complete typed byte, advance one byte through a consuming
    /// selection, or past the caret.
    private func advanceAfterByte() {
        guard let doc = document else { return }
        if let sel = overwriteSelection {
            let next = sel.start + 1
            if next < sel.end {
                overwriteSelection = SelectionModel(start: next, end: sel.end, fileSize: doc.size)
                doc.setSelection(overwriteSelection!)
            } else {
                overwriteSelection = nil
                doc.setSelection(SelectionModel.empty(at: next, fileSize: doc.size))
            }
        } else {
            doc.setSelection(SelectionModel.empty(at: doc.selection.start + 1, fileSize: doc.size))
        }
    }

    private func fillSelection() {
        fillSelection(pattern: [0])
    }

    private func fillSelection(pattern: [UInt8]) {
        guard let doc = document else { return }
        let sizeBefore = doc.size
        let start = doc.selection.start
        let end = doc.selection.end
        // A fill leaves the caret at the selection start — redo must too.
        beginSegmentEdit()
        try? doc.fill(pattern: pattern, in: start..<end, caretAfter: start)
        doc.setSelection(SelectionModel.empty(at: start, fileSize: doc.size))
        nibble = 0
        overwriteSelection = nil
        onEdit?(.overwrite(range: start..<end))
        applySegmentEdit(.overwrite(range: start..<end))
        notifyAfterEdit(range: start..<end, sizeBefore: sizeBefore)
    }

    /// Reports a change to the view (and, where relevant, the companion's
    /// view). Three routes, in increasing cost:
    /// - `selectionChangedOnly`: a pure caret/selection move — the bytes are
    ///   unchanged, so the view redraws only the rows the selection now covers
    ///   differently (§3.3).
    /// - `contentChange`: bytes overwritten or the decoder rebuilt — the view
    ///   redraws just the affected rows/columns, and the companion redraws the
    ///   same rows so its live diff background catches up (§3.3 extension).
    /// - neither (plain `notify()`): a layout or lifecycle change (insert /
    ///   delete, undo/redo, open/save/revert) — the whole pane repaints.
    ///
    /// `reveal` is the caret-reveal mode (§10.4) for the two caret-moving
    /// routes. The content route ignores it — a content change does not move
    /// the caret, so it never scrolls.
    private func notify(selectionChangedOnly: Bool = false, contentChange: HexViewChange? = nil,
                        reveal: SelectionReveal = .follow) {
        // Selections are independent per pane (§3.3): the companion must not
        // adopt this pane's selection — its hex view only redraws the frames
        // mirroring it.
        companion?.onMirroredSelectionChanged?()
        if let contentChange {
            // An edit in this pane changes the comparison difference in the
            // companion: it redraws the affected rows so its diff background
            // recomputes against the new bytes (§3.3 extension). The content
            // channel repaints only — it never reveals the caret, which a
            // content change does not move (§10.4).
            companion?.onCompanionContentChanged?(contentChange)
            onContentChanged?(contentChange)
        } else if selectionChangedOnly {
            // A pure selection move (drag, click, keyboard, Find): the bytes
            // are unchanged, so the view redraws only the rows the selection
            // now covers differently instead of the whole pane (§3.3).
            onSelectionChanged?(reveal)
        } else {
            onChange?(reveal == .center)
        }
        onCaretChanged?()
    }

    /// Reports an in-place byte edit. When the file size is unchanged, a
    /// region-scoped content change — the affected rows redraw instead of the
    /// whole pane; when the size grew or shrank, a full change, because the
    /// layout (frame height, caret row) must rebuild.
    private func notifyAfterEdit(range: Range<UInt64>, sizeBefore: UInt64) {
        // The command has placed the selection by now — hand it to the undo
        // history so redo returns to this state, not to the bare end of the
        // range it wrote (§7.5).
        document?.noteSelectionAfterEdit()
        if document?.size == sizeBefore {
            notify(contentChange: .bytes(in: range))
        } else {
            notify()
        }
    }

    /// A structural edit — undo/redo, revert, a length-changing insert/delete,
    /// opening a new document — can move or replace bytes at any offset, so no
    /// single `.bytes(in:)` range describes it. The companion's diff background
    /// is computed live in `hexByteStates`, so it only needs to repaint: tell
    /// it the whole content may differ. The range spans both panes' sizes so
    /// EOF-only differences past a shrunk pane's end are repainted too; the
    /// view clamps invalidation to the visible viewport, keeping the cost
    /// bounded (§3.3 extension). This mirrors `onMirroredSelectionChanged`:
    /// without it, an undo/redo in one pane would leave the other pane's diff
    /// background stale until that pane happened to repaint for its own reason.
    private func notifyCompanionContentFullyChanged() {
        let maxSize = max(document?.size ?? 0, companion?.fileSize ?? 0)
        guard maxSize > 0 else { return }
        companion?.onCompanionContentChanged?(.bytes(in: 0..<maxSize))
    }

    /// The companion's diff background for an undo/redo: repaint only the rows a
    /// net edit can have changed, mirroring the edit's own invalidation. A
    /// length-shifting edit (`.insert`/`.delete`) moves every offset at/after
    /// its earliest point, so the companion repaints that range to EOF; a
    /// length-preserving edit touches only its window.
    private func notifyCompanionContentChanged(_ edit: DiffEdit) {
        let maxSize = max(document?.size ?? 0, companion?.fileSize ?? 0)
        let range: Range<UInt64>
        switch edit {
        case .overwrite(let r): range = r
        case .insert(let at, _): range = at..<maxSize
        case .delete(let r): range = r.lowerBound..<maxSize
        }
        guard range.lowerBound < maxSize else { return }
        companion?.onCompanionContentChanged?(.bytes(in: range))
    }
}

// MARK: - HexEditorDelegate

extension PaneViewModel: HexEditorDelegate {
    func hexEditor(_ editor: HexView, typeHexNibble digit: Int) {
        typeHexNibble(digit)
    }

    func hexEditor(_ editor: HexView, typeASCIIByte byte: UInt8) {
        typeASCII(byte)
    }

    func hexEditorDeleteForward(_ editor: HexView) {
        deleteForward()
    }

    func hexEditorDeleteBackward(_ editor: HexView) {
        deleteBackward()
    }

    func hexEditor(_ editor: HexView, moveCaretBy delta: Int64, extendSelection: Bool, center: Bool) {
        moveCaret(by: delta, extendSelection: extendSelection, center: center)
    }

    func hexEditor(_ editor: HexView, moveCaretTo offset: UInt64, extendSelection: Bool, center: Bool) {
        moveCaret(to: offset, extendSelection: extendSelection, center: center)
    }

    func hexEditorSelectAll(_ editor: HexView) {
        selectAll()
    }

    func hexEditor(_ editor: HexView, didClickAt offset: UInt64, region: HexInputRegion, extendSelection: Bool, nibble: Int) {
        // A mouse click places the caret where the user pointed: follow, don't
        // centre (§10.4).
        moveCaret(to: offset, extendSelection: extendSelection, center: false)
        // A click can place the caret mid-byte (before the low nibble). Arrow
        // movement always lands on a byte's left boundary (`moveCaret` resets
        // the nibble), so only a direct click sets it (§3.3).
        if !extendSelection {
            self.nibble = nibble
        }
        setInputRegion(region)
    }
}
