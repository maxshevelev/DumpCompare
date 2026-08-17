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

/// Read-only snapshot of the pane's status-bar fields (§15).
struct PaneStatus: Equatable {
    var fileName = ""
    var fileSize: UInt64 = 0
    var cursorHex = ""
    var cursorDecimal = ""
    var selectionLength: UInt64 = 0
    var isDirty = false
    var isReadOnly = false
    /// True for an untitled in-memory document (File > New File) that has never
    /// been saved — the header shows "Untitled" with a plus-badge glyph.
    var isUntitled = false
    var canUndo = false
    var canRedo = false
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
    /// misreport.
    private var savedStorage: FileBackedStorage?
    /// True while the pane holds an untitled in-memory document (File > New
    /// File) that has never been saved to disk. Such a document has no URL to
    /// watch and no on-disk reference for modified-byte detection; the header
    /// shows "Untitled" with a plus-badge glyph until it is saved.
    private(set) var isUntitled = false

    /// Hex caret: 0 = high nibble, 1 = low nibble of the current byte.
    private(set) var nibble = 0
    /// The interactive region the caret currently targets (§7).
    private(set) var inputRegion: HexInputRegion = .hex
    /// When typing over a selection, the selection being consumed (§7.4).
    private var overwriteSelection: SelectionModel?
    /// Anchor for shift-extended selections.
    private var selectionAnchor: UInt64?
    /// Whether a hex-byte edit group is open (the two nibbles of a byte coalesce
    /// into a single undo step; see `beginTypingGroup`/`endTypingGroup`).
    private var typingGroupOpen = false

    /// The other pane in comparison mode. Selections are independent per pane
    /// (§3.3): this pane reads the companion's selection only to mirror it with
    /// frames, and tells the companion when its own selection changed so the
    /// mirror redraws. Nil in single-file mode. Weak to avoid a retain cycle.
    weak var companion: PaneViewModel?

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
    var onChange: (() -> Void)?

    /// Fired when only the caret/selection moved (no bytes changed), so the
    /// view can redraw just the rows the selection now covers differently — the
    /// hot path for mouse-drag selection, where a full redraw on every event
    /// lags the cursor (§3.3).
    var onSelectionChanged: (() -> Void)?

    /// Fired after a content change — bytes overwritten in this pane, or its
    /// text decoder rebuilt — carrying the affected region, so the view can
    /// redraw only the affected rows/columns instead of the whole pane (§3.3
    /// extension). Not fired for length-changing edits (insert/delete, paste
    /// insert, undo/redo/revert, open/save) — those still use `onChange`.
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

    /// The active text decoder, rebuilt whenever decoding settings change.
    private(set) var textDecoder: any TextDecoder

    private var textDecodingObserver: NSObjectProtocol?

    /// Whether a document is currently open in this pane.
    var isOpen: Bool { document != nil }

    /// Creates a new pane view model with the current decoding settings.
    init() {
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
                // extension).
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
    /// this window are the app's own and are suppressed.
    private var externalChangeSuppressedUntil = Date.distantPast

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
        refreshSavedStorage()
        resetEditingState()
        startWatching(url)
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
        document = BinaryDocument(
            storage: EditOverlayStorage(base: MemoryBackedStorage()),
            url: url,
            readOnly: false
        )
        savedStorage = nil
        isUntitled = true
        resetEditingState()
        changeWatcher?.stop()
        changeWatcher = nil
        notify()
        notifyCompanionContentFullyChanged()
    }

    func close() {
        document = nil
        savedStorage = nil
        isUntitled = false
        changeWatcher?.stop()
        changeWatcher = nil
        resetEditingState()
    }

    func save() throws {
        guard let doc = document else { return }
        // An untitled document must pick a location first; the controller
        // routes through Save As, but throwing here makes a stray call safe
        // (it can never silently write to the placeholder URL).
        guard !isUntitled else { throw PaneSaveError.requiresSaveAs }
        try doc.save()
        refreshSavedStorage()
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
        notify()
        notifyCompanionContentFullyChanged()
    }

    /// The document's live byte storage — the same class instance across edits,
    /// so a comparison coordinator can hold it and always read current bytes.
    var byteStorage: (any ByteStorage)? { document?.storage }

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
        if Date() < externalChangeSuppressedUntil { return }
        onExternalChange?()
    }

    /// Re-arms the watcher after the app itself wrote the file: its own write
    /// events are suppressed for a moment, and the descriptor is rebound because
    /// an atomic save may have replaced the inode.
    private func rearmWatcher() {
        externalChangeSuppressedUntil = Date().addingTimeInterval(1.0)
        changeWatcher?.rebind(to: document?.url)
    }

    private func resetEditingState() {
        endTypingGroup()
        nibble = 0
        inputRegion = .hex
        overwriteSelection = nil
        selectionAnchor = nil
    }

    /// Moves the caret's input region to `region` (set when the user clicks the
    /// hex or ASCII area).
    func setInputRegion(_ region: HexInputRegion) {
        guard inputRegion != region else { return }
        inputRegion = region
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

    func hexSelection() -> SelectionModel {
        document?.selection ?? SelectionModel.empty(at: 0, fileSize: 0)
    }

    func hexCaretNibble() -> Int { nibble }

    func hexInputRegion() -> HexInputRegion { inputRegion }

    /// The companion pane's selection, clamped to this pane's file size — what
    /// this pane's hex view frames to mirror the opposite pane (§3.3). Nil in
    /// single-file mode (no companion).
    func hexMirroredSelection() -> SelectionModel? {
        guard let doc = document, let other = companion else { return nil }
        return other.hexSelection().clamped(to: doc.size)
    }

    // MARK: - Status

    var status: PaneStatus {
        guard let doc = document else { return PaneStatus() }
        let caret = doc.selection.start
        return PaneStatus(
            fileName: isUntitled ? "Untitled" : doc.url.lastPathComponent,
            fileSize: doc.size,
            cursorHex: String(format: "0x%X", caret),
            cursorDecimal: "\(caret)",
            selectionLength: doc.selection.count,
            isDirty: doc.isDirty,
            isReadOnly: doc.readOnly,
            isUntitled: isUntitled,
            canUndo: doc.canUndo,
            canRedo: doc.canRedo
        )
    }

    var caretOffset: UInt64 { document?.selection.start ?? 0 }

    // MARK: - Hex input (§7)

    /// Types one hex digit (0–15) into the current nibble (§7: hex nibble
    /// input; after the second nibble the caret advances to the next byte).
    /// The two nibbles of a byte coalesce into one undo step.
    func typeHexNibble(_ digit: Int) {
        guard let doc = document, (0...15).contains(digit) else { return }
        let sizeBefore = doc.size

        let offset: UInt64
        if nibble == 0 {
            prepareForTyping()
            offset = typingOffset(doc)
            let old = byteAt(offset) ?? 0
            beginTypingGroup()
            try? doc.overwrite(range: offset..<offset + 1, with: [(UInt8(digit) << 4) | (old & 0x0F)])
            nibble = 1
            onEdit?(.overwrite(range: offset..<offset + 1))
        } else {
            offset = typingOffset(doc)
            let old = byteAt(offset) ?? 0
            try? doc.overwrite(range: offset..<offset + 1, with: [(old & 0xF0) | UInt8(digit)])
            nibble = 0
            endTypingGroup()
            advanceAfterByte()
            onEdit?(.overwrite(range: offset..<offset + 1))
        }
        notifyAfterEdit(range: offset..<offset + 1, sizeBefore: sizeBefore)
    }

    /// Types one decoded-text character. The HexView validates the character
    /// through `textDecoder.encode(_)` before calling this, so any byte that
    /// arrives here is representable in the current code page. A whole-byte
    /// edit: one undo step.
    func typeASCII(_ byte: UInt8) {
        guard let doc = document else { return }
        let sizeBefore = doc.size
        endTypingGroup()
        prepareForTyping()
        let offset = typingOffset(doc)
        try? doc.overwrite(range: offset..<offset + 1, with: [byte])
        nibble = 0
        advanceAfterByte()
        onEdit?(.overwrite(range: offset..<offset + 1))
        notifyAfterEdit(range: offset..<offset + 1, sizeBefore: sizeBefore)
    }

    /// Delete: fill the selection (or the current byte) with 0x00 (§7.3).
    func deleteForward() {
        guard let doc = document else { return }
        endTypingGroup()
        if !doc.selection.isEmpty {
            fillSelection()
            return
        }
        let sizeBefore = doc.size
        let caret = doc.selection.start
        guard caret < doc.size else { return }
        // Forward delete fills a byte but leaves the caret put — redo must too.
        try? doc.fillZero(in: caret..<caret + 1, caretAfter: caret)
        nibble = 0
        onEdit?(.overwrite(range: caret..<caret + 1))
        notifyAfterEdit(range: caret..<caret + 1, sizeBefore: sizeBefore)
    }

    /// Backspace: fill the selection (or the previous byte) with 0x00 and move
    /// the caret back (§7.3).
    func deleteBackward() {
        guard let doc = document else { return }
        endTypingGroup()
        if !doc.selection.isEmpty {
            fillSelection()
            return
        }
        let sizeBefore = doc.size
        let caret = doc.selection.start
        guard caret > 0 else { return }
        // Backspace fills the previous byte and steps back one — redo must land
        // there too, not at the (unmoved) caret.
        try? doc.fillZero(in: (caret - 1)..<caret, caretAfter: caret - 1)
        doc.setSelection(SelectionModel.empty(at: caret - 1, fileSize: doc.size))
        nibble = 0
        onEdit?(.overwrite(range: (caret - 1)..<caret))
        notifyAfterEdit(range: (caret - 1)..<caret, sizeBefore: sizeBefore)
    }

    /// Fill Selection with… (menu command, §7.3): repeats `pattern` across the
    /// selection.
    func fillSelection(with pattern: [UInt8]) {
        guard let doc = document, !doc.selection.isEmpty, !pattern.isEmpty else { return }
        endTypingGroup()
        fillSelection(pattern: pattern)
    }

    /// True length-changing delete (Edit > Delete Bytes…, §7.2, confirmed by
    /// the UI before calling).
    func deleteBytes(in range: Range<UInt64>) throws {
        guard let doc = document else { return }
        endTypingGroup()
        try doc.delete(range: range)
        doc.setSelection(SelectionModel.empty(at: range.lowerBound, fileSize: doc.size))
        nibble = 0
        overwriteSelection = nil
        onEdit?(.delete(range: range))
        notify()
        notifyCompanionContentFullyChanged()
    }

    /// Paste Write: overwrite from the caret (or selection start), extending
    /// past EOF without confirmation (§7.1, §12.2).
    func pasteWrite(_ bytes: [UInt8]) throws {
        guard let doc = document, !bytes.isEmpty else { return }
        let sizeBefore = doc.size
        let start = doc.selection.start
        let range = start..<start + UInt64(bytes.count)
        try doc.overwrite(range: range, with: bytes)
        doc.setSelection(SelectionModel.empty(at: range.upperBound, fileSize: doc.size))
        resetEditingState()
        // The engine's `.overwrite` recomputes `[start, end)`, which covers the
        // paste even when it extends past EOF (the recompute reads current bytes).
        onEdit?(.overwrite(range: range))
        // A paste that extends past EOF grows the file, so the layout (frame
        // height, caret row) must rebuild — `notifyAfterEdit` handles that.
        notifyAfterEdit(range: range, sizeBefore: sizeBefore)
    }

    /// Paste Insert: insert before the caret (confirmed by the UI, §7.2/§12.3).
    func pasteInsert(_ bytes: [UInt8]) throws {
        guard let doc = document, !bytes.isEmpty else { return }
        let at = doc.selection.start
        try doc.insert(at: at, bytes: bytes)
        doc.setSelection(SelectionModel.empty(at: at + UInt64(bytes.count), fileSize: doc.size))
        resetEditingState()
        onEdit?(.insert(at: at, length: UInt64(bytes.count)))
        notify()
        notifyCompanionContentFullyChanged()
    }

    // MARK: - Caret & selection

    func moveCaret(by delta: Int64, extendSelection: Bool = false) {
        guard let doc = document else { return }
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
        moveCaret(to: target, extendSelection: extendSelection)
    }

    func moveCaret(to offset: UInt64, extendSelection: Bool = false) {
        guard let doc = document else { return }
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
        notify(selectionChangedOnly: true)
    }

    func selectAll() {
        guard let doc = document else { return }
        doc.setSelection(SelectionModel(start: 0, end: doc.size, fileSize: doc.size))
        resetEditingState()
        notify(selectionChangedOnly: true)
    }

    func setSelection(_ selection: SelectionModel) {
        guard let doc = document else { return }
        doc.setSelection(selection)
        resetEditingState()
        notify(selectionChangedOnly: true)
    }

    /// Selects `range`, clamped to the file size (used by Find and Select Block).
    func select(range: Range<UInt64>) {
        guard let doc = document else { return }
        doc.setSelection(SelectionModel(start: range.lowerBound, end: range.upperBound, fileSize: doc.size))
        resetEditingState()
        notify(selectionChangedOnly: true)
    }

    /// Finds `pattern` in the current (unsaved) contents (§11). `from` is the
    /// offset at which to start; searches read live storage so pending edits are
    /// included. Returns the match range, or nil when not found.
    func find(pattern: [UInt8], from offset: UInt64, direction: SearchDirection) throws -> Range<UInt64>? {
        guard let doc = document else { return nil }
        return try SearchEngine.find(pattern: pattern, in: doc.storage, from: offset, direction: direction)
    }

    // MARK: - Undo / Redo

    @discardableResult
    func undo() throws -> Bool {
        guard let doc = document else { return false }
        // Flush a pending typing group BEFORE undoing: a half-typed byte must be
        // committed so undo reverts it (and keeps the redo stack intact) instead
        // of skipping it for an older edit.
        resetEditingState()
        let edit = try doc.undo()   // restores the caret to where the edit began
        if let edit {
            // Undo mutates the storage in place, so the net DiffEdit updates the
            // comparison incrementally — no full-file re-scan (§8.3).
            onEdit?(edit)
            notifyCompanionContentChanged(edit)
        }
        notify()
        return edit != nil
    }

    @discardableResult
    func redo() throws -> Bool {
        guard let doc = document else { return false }
        resetEditingState()
        let edit = try doc.redo()   // restores the caret to where the edit left it
        if let edit {
            onEdit?(edit)
            notifyCompanionContentChanged(edit)
        }
        notify()
        return edit != nil
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
        try? doc.fill(pattern: pattern, in: start..<end, caretAfter: start)
        doc.setSelection(SelectionModel.empty(at: start, fileSize: doc.size))
        nibble = 0
        overwriteSelection = nil
        onEdit?(.overwrite(range: start..<end))
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
    private func notify(selectionChangedOnly: Bool = false, contentChange: HexViewChange? = nil) {
        // Selections are independent per pane (§3.3): the companion must not
        // adopt this pane's selection — its hex view only redraws the frames
        // mirroring it.
        companion?.onMirroredSelectionChanged?()
        if let contentChange {
            // An edit in this pane changes the comparison difference in the
            // companion: it redraws the affected rows so its diff background
            // recomputes against the new bytes (§3.3 extension).
            companion?.onCompanionContentChanged?(contentChange)
            onContentChanged?(contentChange)
        } else if selectionChangedOnly {
            // A pure selection move (drag, click, keyboard, Find): the bytes
            // are unchanged, so the view redraws only the rows the selection
            // now covers differently instead of the whole pane (§3.3).
            onSelectionChanged?()
        } else {
            onChange?()
        }
        onCaretChanged?()
    }

    /// Reports an in-place byte edit. When the file size is unchanged, a
    /// region-scoped content change — the affected rows redraw instead of the
    /// whole pane; when the size grew or shrank, a full change, because the
    /// layout (frame height, caret row) must rebuild.
    private func notifyAfterEdit(range: Range<UInt64>, sizeBefore: UInt64) {
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

    func hexEditor(_ editor: HexView, moveCaretBy delta: Int64, extendSelection: Bool) {
        moveCaret(by: delta, extendSelection: extendSelection)
    }

    func hexEditor(_ editor: HexView, moveCaretTo offset: UInt64, extendSelection: Bool) {
        moveCaret(to: offset, extendSelection: extendSelection)
    }

    func hexEditorSelectAll(_ editor: HexView) {
        selectAll()
    }

    func hexEditor(_ editor: HexView, didClickAt offset: UInt64, region: HexInputRegion, extendSelection: Bool, nibble: Int) {
        moveCaret(to: offset, extendSelection: extendSelection)
        // A click can place the caret mid-byte (before the low nibble). Arrow
        // movement always lands on a byte's left boundary (`moveCaret` resets
        // the nibble), so only a direct click sets it (§3.3).
        if !extendSelection {
            self.nibble = nibble
        }
        setInputRegion(region)
    }
}
