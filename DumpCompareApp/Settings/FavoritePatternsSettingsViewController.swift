import Cocoa
import DumpCompareCore

/// The Favorites tab of the Settings window (§11): the named patterns the user
/// keeps, in the order they keep them in.
///
/// Every other tab in this window applies live, so this one does too — a commit
/// writes the store, and every open Find bar's menu re-reads. There is nothing
/// to confirm and nothing to lose, which is what lets the whole tab be a table.
///
/// Two rules are worth stating, because they are the ones a table like this
/// usually gets wrong:
///
/// - **Nothing unsearchable is stored.** A pattern is committed through the
///   same `SearchEngine.parsePattern` call the Find bar makes; when it throws,
///   the cell goes back to what it held and the reason is said under the table.
///   The one way an unusable entry can exist is a hand-edited plist, and the
///   menu marks those (§11).
/// - **A new row is a draft until it has a pattern.** `+` puts an empty row in
///   the *table*, not in the store: an entry with no pattern is not a search,
///   and a list the user curates should not gain a row that searches for
///   nothing. Leaving the tab abandons an unfinished row.
final class FavoritePatternsSettingsViewController: NSViewController,
                                                    NSTableViewDataSource, NSTableViewDelegate {
    /// The rows as the table shows them — a snapshot, so a row index means the
    /// same thing to every method that reads one, plus any draft row.
    private(set) var rows: [SearchPatternEntry] = []

    /// The widgets. Internal so tests can drive them: the settings window is
    /// not on screen under XCTest.
    private(set) var table: NSTableView!
    private(set) var addButton: NSButton!
    private(set) var removeButton: NSButton!
    private(set) var messageLabel: NSTextField!
    /// Where the library lives, and the two commands that move it.
    private(set) var locationLabel: NSTextField!
    private(set) var moveButton: NSButton!
    private(set) var keepHereButton: NSButton!
    private(set) var resolveButton: NSButton!

    // MARK: - Seams
    //
    // Both of these put something in front of the user, which a test run has
    // nobody to answer, so both go through a closure a test can replace.

    /// Asks which folder to keep the library in. Nil when the user cancelled.
    var chooseSharedFolder: (() -> URL?)?
    /// Asks whether the library file left behind should be removed.
    var askAboutOldFile: ((URL) -> Bool)?
    /// Asks what to do with a file that already holds patterns. Nil when the
    /// user backed out.
    var askAboutExistingFile: ((URL) -> LibrarySync.Adoption?)?

    private var storeObserver: NSObjectProtocol?

    private enum ColumnID {
        static let name = NSUserInterfaceItemIdentifier("favoriteName")
        static let pattern = NSUserInterfaceItemIdentifier("favoritePattern")
        static let encoding = NSUserInterfaceItemIdentifier("favoriteEncoding")
        static let caseRule = NSUserInterfaceItemIdentifier("favoriteCase")
    }

    /// The row index a drag carries, on the pasteboard.
    private static let rowDragType = NSPasteboard.PasteboardType("com.dumpcompare.favorite-row")

    private var tableHeight: NSLayoutConstraint!
    private static let rowHeight: CGFloat = 24
    private static let minVisibleRows = 4
    private static let maxVisibleRows = 12

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    // MARK: - Layout

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: "Favorites")
        titleLabel.font = .boldSystemFont(ofSize: 15)

        let list = makeTable()
        let footer = makeFooter()

        let message = NSTextField(labelWithString: "")
        message.font = .systemFont(ofSize: 11)
        message.textColor = .systemRed
        message.lineBreakMode = .byTruncatingTail
        messageLabel = message

        let location = makeLocationRow()

        let caption = NSTextField(wrappingLabelWithString:
            "Patterns you keep, with the encoding they are read in. They appear under "
            + "Favorites in the Find bar's search menu, where picking one fills the bar "
            + "and searches. Drag rows to reorder them — the menu lists them in this order. "
            + "Keep the library in a synced folder to have it on another Mac.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 4

        for subview in [titleLabel, location, list, footer, message, caption] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            location.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            location.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            location.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            list.topAnchor.constraint(equalTo: location.bottomAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            footer.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            // The message sits close under the footer it is about, with the full
            // gap before the caption — the sheets' spacing rule (§10).
            message.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 6),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            caption.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 10),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            // Exact width, like every other tab: the window sizes to this view's
            // fitting size, and a wrapping label's ideal width is its whole text
            // on one line. Wider than the others because four columns have to
            // fit — the tab bar keeps its own width, and the window follows the
            // tab that is showing.
            root.widthAnchor.constraint(equalToConstant: 540),
        ])
        view = root

        reload()
        // Another window's Find bar can keep a pattern while this tab is open
        // (§11) — the store says so, and the table is not the only writer.
        storeObserver = NotificationCenter.default.addObserver(
            forName: FavoritePatternStore.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.reloadUnlessDrafting()
            self?.closeResolverIfItsQuestionsChanged()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func makeTable() -> NSView {
        let table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.headerView = NSTableHeaderView()
        table.rowHeight = Self.rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.allowsMultipleSelection = false

        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            return column
        }
        table.addTableColumn(column(ColumnID.name, "Name", width: 140))
        table.addTableColumn(column(ColumnID.pattern, "Pattern", width: 160))
        table.addTableColumn(column(ColumnID.encoding, "Encoding", width: 120))
        table.addTableColumn(column(ColumnID.caseRule, "Match Case", width: 70))
        self.table = table

        // The order is the user's, so it is dragged (§11).
        table.registerForDraggedTypes([Self.rowDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table
        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.height(forRows: 4))
        tableHeight.isActive = true
        return scrollView
    }

    /// Where the library lives, said in one line, with the two commands that
    /// move it (§11, `Design/FAVORITES_SYNC_PLAN.md`).
    ///
    /// One line because it is a fact, not a setting with options: the library
    /// is on this Mac, or it is in a file the user picked — and the file is
    /// what a sync client carries to their other machine.
    private func makeLocationRow() -> NSView {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationLabel = label

        let resolve = NSButton(title: "Resolve…", target: self, action: #selector(resolvePressed))
        resolve.bezelStyle = .rounded
        resolve.controlSize = .small
        resolve.isHidden = true
        resolveButton = resolve

        let move = NSButton(title: "Move…", target: self, action: #selector(movePressed))
        move.bezelStyle = .rounded
        move.controlSize = .small
        move.toolTip = "Keep the library in a folder of your own — a synced one puts it on your other Macs, "
            + "and one that already has a library joins it"
        moveButton = move

        // The title is the state it produces, in the words the line above uses
        // for that state — "Use This Mac" named a machine and left the rest to
        // be guessed at.
        let keepHere = NSButton(title: "Keep on This Mac", target: self,
                                action: #selector(keepHerePressed))
        keepHere.bezelStyle = .rounded
        keepHere.controlSize = .small
        keepHere.toolTip = "Stop publishing to the folder and keep the library in the app's "
            + "own storage — your other Macs stop seeing your changes"
        keepHereButton = keepHere

        // The path on a line of its own, the commands under it. A path is the
        // one thing here that has to be read in full — two libraries in one
        // synced folder tree are told apart by nothing else — and sharing a row
        // with three buttons left it a few characters wide.
        let buttons = NSStackView(views: [resolve, move, keepHere])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let column = NSStackView(views: [label, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        return column
    }

    /// Says where the library is, and — when it is published — when it and the
    /// file last agreed. A file that cannot be reached changes nothing about
    /// the list: the truth is this machine's, and the line is where the app
    /// says so rather than pretending everything is current.
    private func refreshLocation() {
        guard let locationLabel else { return }
        let conflicts = FavoritePatternStore.conflicts
        resolveButton?.isHidden = conflicts.isEmpty
        // While a merge has a question outstanding the library is read-only
        // (§11): nothing may be written until the user answers, so the table
        // stops offering to *change* it. Selecting a row still works — reading
        // one is how the user decides what to answer — and disabling the whole
        // table took that away along with the editing.
        addButton?.isEnabled = conflicts.isEmpty
        updateRemoveButton()
        guard conflicts.isEmpty else {
            // Red, like the publishing failure beside it: this is not a note
            // about the library, it is something only the user can settle, and
            // in the secondary grey the rest of the line uses it read as
            // furniture.
            locationLabel.textColor = .systemRed
            let problem = FavoritePatternStore.syncProblem ?? "conflicting changes"
            var text = conflicts.count == 1
                ? "\(problem) — the library is read-only until it is answered"
                : "\(problem) — the library is read-only until they are answered"
            // And what stops an answer from taking effect, if anything does. A
            // question that cannot be published is one the user can answer for
            // ever without the answer going anywhere, and showing only the
            // question is how that becomes a mystery: the conflict line used to
            // return here, hiding the very failure that made the conflict
            // unanswerable.
            if !FavoritePatternStore.hasFolderAccess {
                text += ". macOS is not letting the app write to the library folder — "
                    + "choose it again with Move…"
            } else if let failure = FavoritePatternStore.publishError {
                text += ". Answering cannot be published: \(failure.localizedDescription)"
            } else if FavoritePatternStore.answerDidNotTake {
                // The one case where pressing Apply changes nothing and nothing
                // is broken: the shared library moved while the sheet was open,
                // so the answer was about a version that is no longer there.
                text = "The shared library changed while you were answering — "
                    + "\(problem) to look at again"
            }
            locationLabel.stringValue = text
            locationLabel.toolTip = FavoritePatternStore.publishError.map { "\($0)" }
            keepHereButton?.isHidden = true
            moveButton?.isHidden = true
            return
        }
        moveButton?.isHidden = false
        if let folder = FavoritePatternStore.sharedFolder, let url = FavoritePatternStore.sharedURL {
            var text = "Library folder: \(Self.readablePath(of: folder))"
            // A publish that cannot happen is said here, and said as what to do
            // about it. Silence was what made a library published to a file
            // that had since been moved in the Finder look like an app that had
            // stopped saving.
            if !FavoritePatternStore.hasFolderAccess {
                // The grant is gone rather than the folder. Said as the thing
                // to do about it, because there is exactly one.
                text += " — macOS is no longer letting the app write there; "
                    + "choose the folder again with Move…"
                locationLabel.textColor = .systemRed
                locationLabel.toolTip = url.path
            } else if let failure = FavoritePatternStore.publishError {
                // The system's own words, not a paraphrase: when publishing
                // stops the reason is the whole of what anyone can act on, and
                // "cannot be written" says nothing a report can be made from.
                let missing = !FileManager.default.fileExists(atPath: url.path)
                text += missing
                    ? " — that file is no longer there; use Move… to point at it again"
                    : " — cannot be published: \(failure.localizedDescription)"
                if let published = FavoritePatternStore.lastPublished {
                    text += " (last published \(Self.times.string(from: published)))"
                }
                locationLabel.toolTip = "\(url.path)\n\n\(failure)"
                locationLabel.textColor = .systemRed
            } else {
                locationLabel.textColor = .secondaryLabelColor
                text += FavoritePatternStore.lastPublished.map {
                    " — published \(Self.times.string(from: $0))"
                } ?? " — not published yet"
            }
            locationLabel.stringValue = text
            // The whole path on hover, for a folder deep enough to truncate.
            locationLabel.toolTip = folder.path
            keepHereButton?.isHidden = false
        } else {
            locationLabel.textColor = .secondaryLabelColor
            locationLabel.stringValue = "Library: on this Mac only"
            locationLabel.toolTip = FavoritesFile.url.path
            keepHereButton?.isHidden = true
        }
    }

    /// The whole path, with the home folder as `~`.
    ///
    /// A file name and its folder are not enough to say where a library is:
    /// with Desktop & Documents in iCloud, `~/Documents` *is* iCloud Drive's
    /// Documents folder, and "DumpCompare Patterns.json in Documents" reads
    /// exactly like the file of that name in iCloud Drive's root — which is a
    /// different file, syncing to the same places, that nothing will update.
    /// Two libraries a person cannot tell apart is worse than a long line.
    static func readablePath(of url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static let times: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: - Moving the library

    /// Puts the library in a place of the user's choosing.
    ///
    /// A **folder** is what is asked for, not a file name, and that is the
    /// whole of the permission story: a sandboxed app is granted what the user
    /// pointed at, and a grant on a file dies with that file — which every
    /// atomic write replaces, ours and every other machine's. A folder grant
    /// survives all of it, covers the conflicted copies a sync client leaves
    /// *beside* the library, and means the system asks once rather than at
    /// every launch. The file inside it is ours to name (§11).
    @objc private func movePressed() {
        guard let folder = (chooseSharedFolder ?? { self.runFolderPanel() })() else { return }
        publish(to: folder)
    }

    /// Publishes into `folder`: what is already in it decides whether anything
    /// is asked.
    private func publish(to folder: URL) {
        let previous = FavoritePatternStore.sharedURL
        // Where this Mac's own file will go. Each machine writes one of its
        // own in that folder and reads the rest (`LibrarySync`).
        let url = LibraryLocation.file(in: folder)
        switch FavoritePatternStore.inspectShared(in: folder) {
        case .empty:
            // No library there yet, or an empty one: nothing to reconcile, so
            // nothing to ask about.
            FavoritePatternStore.publish(to: folder, adopting: .merge)
            reload()
            offerToTrash(previous, movingTo: url)
        case .patterns:
            let ask = askAboutExistingFile ?? { folder in
                MainViewController.isRunningTests ? nil : self.askAboutFile(in: folder)
            }
            guard let adoption = ask(folder) else { return }
            FavoritePatternStore.publish(to: folder, adopting: adoption)
            reload()
            offerToTrash(previous, movingTo: url)
        case .unreadable:
            // There is a file and this Mac cannot read it — most often one
            // iCloud has not finished downloading. Publishing into it would
            // write over something unread, so it is refused and said.
            show(message: "The library already in “\(folder.lastPathComponent)” cannot be read "
                    + "yet — if it is in iCloud Drive, wait for it to download and try again.")
        }
    }

    /// Puts the merge's questions to the user. Opened from here rather than
    /// thrown in front of them: a conflict arrives when the sync client
    /// delivers, which may be in the middle of a search of an 8 MB dump (§11).
    @objc private func resolvePressed() {
        let conflicts = FavoritePatternStore.conflicts
        guard !conflicts.isEmpty else { return }
        let sheet = LibraryConflictSheetController(conflicts: conflicts) { [weak self] answers in
            // Forgotten before the answer is applied: applying it clears the
            // questions, which announces, which would otherwise read as the
            // sheet's questions going away under it — and it is already on its
            // way out, by its own Apply.
            self?.openResolver = nil
            FavoritePatternStore.resolve(answers)
            self?.reload()
        }
        openResolver = sheet
        presentResolver?(sheet) ?? presentAsSheet(sheet)
    }

    /// The resolver, while it is open. Weak: **Later** dismisses it without
    /// telling anyone, and a sheet nobody is holding is one nobody has to close.
    private weak var openResolver: LibraryConflictSheetController?

    /// Takes the resolver away when it is no longer asking what is outstanding.
    ///
    /// An answer given on the other Mac settles the same disagreement here, so
    /// a sheet left standing would offer a choice about something already
    /// decided and its Apply would find nothing to apply. It is said as well as
    /// done: a sheet that vanishes on its own is otherwise a mystery.
    private func closeResolverIfItsQuestionsChanged() {
        guard let sheet = openResolver,
              FavoritePatternStore.conflicts != sheet.questions else { return }
        openResolver = nil
        let settled = FavoritePatternStore.conflicts.isEmpty
        sheet.closeBecauseTheQuestionsChanged()
        show(message: settled
                ? "Those questions were answered on your other Mac, so they are settled here too."
                : "The library changed on your other Mac — open Resolve… again for the questions "
                    + "that are left.")
    }

    /// How the resolver is put on screen. Behind a seam because a sheet has
    /// nobody to answer it in a test run.
    var presentResolver: ((LibraryConflictSheetController) -> Void)?

    @objc private func keepHerePressed() {
        let previous = FavoritePatternStore.sharedURL
        FavoritePatternStore.sharedFolder = nil
        reload()
        offerToTrash(previous, movingTo: nil)
    }

    /// The library has just moved somewhere else; the file it used to be
    /// published to is still sitting there, holding a copy that will never be
    /// updated again.
    ///
    /// Asked rather than done, and never by default. That file may be in a
    /// folder another Mac publishes to, and removing a file in a synced folder
    /// removes it *there* — a second machine would lose the library it is
    /// pointed at. Left behind, the worst it can do is confuse someone later,
    /// which is why the question is asked at all.
    private func offerToTrash(_ previous: URL?, movingTo destination: URL?) {
        guard let previous, previous != destination,
              FavoritePatternStore.publishError == nil,
              FileManager.default.fileExists(atPath: previous.path) else { return }
        // Under XCTest nobody can answer an alert, and the conservative answer
        // is the one that keeps a file (§ test mode).
        let ask = askAboutOldFile ?? { url in
            MainViewController.isRunningTests ? false : self.askAboutRemoving(at: url)
        }
        guard ask(previous) else { return }
        // The Trash, not `unlink`: it is the user's file, in the user's folder,
        // and a library that turns out to have been wanted is then a drag away.
        // It is also the operation the sandbox is likeliest to allow — deleting
        // outright needs write access to the folder the file is in, which is
        // the folder the library has just stopped living in.
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: previous, resultingItemURL: &trashed)
        } catch {
            do {
                try FileManager.default.removeItem(at: previous)
            } catch let removal {
                // Said, not swallowed: this used to set a message that the
                // refresh straight after it wiped, so a removal that could not
                // happen looked exactly like one that had.
                show(message: "“\(previous.lastPathComponent)” could not be moved to the Trash: "
                        + removal.localizedDescription)
            }
        }
    }

    private func askAboutRemoving(at url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move the library file left behind to the Trash?"
        alert.informativeText = "“\(Self.readablePath(of: url))” is no longer where the library "
            + "lives, and its copy of the patterns will not be updated again.\n\nIf it is in a "
            + "synced folder, trashing it removes it on your other Macs too — keep it if one of "
            + "them publishes there."
        alert.addButton(withTitle: "Keep It")
        alert.addButton(withTitle: "Move to Trash")
        alert.buttons.last?.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The folder panel behind `chooseSharedFolder`. It opens on iCloud Drive
    /// when the user has it — the panel runs out of process, so it may be
    /// pointed at a folder this app cannot read itself.
    private func runFolderPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Keep Pattern Library"
        panel.message = "Choose the folder to keep the pattern library in. Each Mac writes its "
            + "own file there and reads the others. "
            + "A folder your Mac syncs — iCloud Drive, Google Drive, Dropbox — puts the library "
            + "on your other machines."
        panel.prompt = "Keep Here"
        panel.directoryURL = LibraryLocation.suggestedFolder()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The three answers to "that folder already holds a library" (§11).
    private func askAboutFile(in folder: URL) -> LibrarySync.Adoption? {
        let alert = NSAlert()
        alert.messageText = "“\(folder.lastPathComponent)” already holds patterns"
        alert.informativeText = "Merging keeps both lists, which is usually what you want when "
            + "setting up a second Mac."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Use the Folder's Patterns")
        alert.addButton(withTitle: "Replace What Is There")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .merge
        case .alertSecondButtonReturn: return .takeTheFile
        case .alertThirdButtonReturn: return .replaceTheFile
        default: return nil
        }
    }

    private static func height(forRows count: Int) -> CGFloat {
        let visible = min(max(count, minVisibleRows), maxVisibleRows)
        return CGFloat(visible + 1) * rowHeight + 4
    }

    /// The `+`/`−` footer under the table — the File Types tab's idiom (§25),
    /// itself the Segments form's (§21.4).
    private func makeFooter() -> NSView {
        func footerIcon(_ name: String, _ description: String) -> NSImage {
            let glyph = NSImage(systemSymbolName: name, accessibilityDescription: description)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
                ?? NSImage()
            let side: CGFloat = 18
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let g = glyph.size
                glyph.draw(at: NSPoint(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2),
                           from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            image.isTemplate = true
            return image
        }

        let plus = NSButton(title: "", target: self, action: #selector(addPressed))
        plus.image = footerIcon("plus", "Add Favorite")
        plus.imagePosition = .imageOnly
        plus.isBordered = false
        plus.contentTintColor = .secondaryLabelColor
        plus.toolTip = "Add a pattern"
        plus.setAccessibilityLabel("Add Favorite")
        addButton = plus

        let minus = NSButton(title: "", target: self, action: #selector(removePressed))
        minus.image = footerIcon("minus", "Remove Favorite")
        minus.imagePosition = .imageOnly
        minus.isBordered = false
        minus.contentTintColor = .secondaryLabelColor
        minus.toolTip = "Remove the selected pattern"
        minus.setAccessibilityLabel("Remove Favorite")
        minus.isEnabled = false
        removeButton = minus

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [plus, minus, spacer])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    // MARK: - Data

    /// Re-reads the store and repaints.
    func reload() {
        let updated = FavoritePatternStore.favorites
        show(message: nil)
        refreshLocation()
        // A list that says the same thing is not a change to show. Rebuilding
        // the table drops the selection and ends any edit in progress, so doing
        // it for an announcement that carries nothing takes the row out from
        // under the user — which is what a library that syncs, and therefore
        // announces, made constant.
        guard rows.map(\.id) != updated.map(\.id) || rows != updated else {
            rows = updated
            return
        }
        rows = updated
        refreshTable()
    }

    /// The same, unless there is a draft row on screen — a row the user is
    /// still filling in is not in the store, and re-reading would take it away
    /// under their hands.
    private func reloadUnlessDrafting() {
        guard !hasDraft else { return }
        reload()
    }

    private var hasDraft: Bool { rows.contains { $0.pattern.isEmpty } }

    private func refreshTable() {
        // Not while a cell is being typed into: a change that arrives from
        // another Mac mid-word must not take the word away. It is applied when
        // the edit ends (`fieldCommitted`).
        guard !isEditingACell else {
            pendingRefresh = true
            return
        }
        pendingRefresh = false
        tableHeight?.constant = Self.height(forRows: rows.count)
        table?.reloadData()
        updateRemoveButton()
    }

    /// A refresh that arrived while the user was typing.
    private var pendingRefresh = false

    /// Whether a cell of this table is being typed into.
    ///
    /// Asked of the window's first responder rather than of the table:
    /// `NSTableView.currentEditor()` answers for an edit the *table* started
    /// (`editColumn`), and a click straight into a cell's text field — which is
    /// how most edits here begin — never goes through it.
    private var isEditingACell: Bool {
        guard let table,
              let editor = table.window?.firstResponder as? NSText,
              let edited = editor.delegate as? NSView else { return false }
        var view: NSView? = edited
        while let current = view {
            if current === table { return true }
            view = current.superview
        }
        return false
    }

    /// Writes the rows that are searches. A draft row is left out — it has no
    /// pattern, so there is nothing to store yet.
    private func save() {
        FavoritePatternStore.replace(with: rows.filter { !$0.pattern.isEmpty })
    }

    private func show(message: String?) {
        messageLabel?.stringValue = message ?? ""
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = tableColumn?.identifier else { return nil }
        let entry = rows[row]
        switch id {
        case ColumnID.name:
            return field(entry.name, placeholder: "Name", column: id, row: row)
        case ColumnID.pattern:
            return field(entry.pattern, placeholder: "Pattern", column: id, row: row)
        case ColumnID.encoding:
            let popup = NSPopUpButton()
            popup.isBordered = false
            popup.font = .systemFont(ofSize: 12)
            for encoding in SearchEncoding.allCases {
                popup.addItem(withTitle: encoding.displayName)
            }
            popup.selectItem(at: SearchEncoding.allCases.firstIndex(of: entry.encoding) ?? 0)
            popup.tag = row
            popup.target = self
            popup.action = #selector(encodingPicked(_:))
            popup.isEnabled = FavoritePatternStore.conflicts.isEmpty
            popup.setAccessibilityLabel("Encoding")
            return cell(around: popup, inset: 0)
        case ColumnID.caseRule:
            let checkbox = NSButton(checkboxWithTitle: "", target: self,
                                    action: #selector(casePicked(_:)))
            checkbox.tag = row
            checkbox.state = entry.caseSensitive ? .on : .off
            // Hex is byte-exact whatever the flag holds, so there is nothing to
            // tick (§11) — the same reason the bar's toggle leaves the bar.
            checkbox.isEnabled = entry.encoding != .hex && FavoritePatternStore.conflicts.isEmpty
            checkbox.setAccessibilityLabel("Match Case")
            return cell(around: checkbox, inset: 2)
        default:
            return nil
        }
    }

    /// An editable cell. Borderless and backgroundless so the table reads as a
    /// list rather than a grid of boxes, and editing happens in place.
    private func field(_ text: String, placeholder: String,
                       column: NSUserInterfaceItemIdentifier, row: Int) -> NSTableCellView {
        let field = NSTextField(string: text)
        // Read-only while a question stands (§11).
        field.isEditable = FavoritePatternStore.conflicts.isEmpty
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.identifier = column
        field.tag = row
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.setAccessibilityLabel(placeholder)
        let holder = cell(around: field, inset: 2)
        holder.textField = field
        return holder
    }

    private func cell(around control: NSView, inset: CGFloat) -> NSTableCellView {
        let holder = NSTableCellView()
        control.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
            control.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -inset),
            control.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    private func updateRemoveButton() {
        removeButton?.isEnabled = (table?.selectedRow ?? -1) >= 0
            && FavoritePatternStore.conflicts.isEmpty
    }

    // MARK: - Editing

    @objc private func fieldCommitted(_ sender: NSTextField) {
        guard sender.tag < rows.count else { return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sender.identifier {
        case ColumnID.name:
            rows[sender.tag].name = text
        case ColumnID.pattern:
            let entry = rows[sender.tag]
            guard text.isEmpty
                    || (try? SearchEngine.parsePattern(text, encoding: entry.encoding)) != nil else {
                // Back to what it held: the same parse the bar makes said no, so
                // this text is not a search and the list does not gain one.
                sender.stringValue = entry.pattern
                show(message: Self.complaint(about: text, as: entry.encoding))
                return
            }
            rows[sender.tag].pattern = text
        default:
            return
        }
        show(message: nil)
        save()
        if pendingRefresh { reload() }
    }

    @objc private func encodingPicked(_ sender: NSPopUpButton) {
        guard sender.tag < rows.count else { return }
        let encoding = SearchEncoding.allCases[
            min(max(0, sender.indexOfSelectedItem), SearchEncoding.allCases.count - 1)]
        var entry = rows[sender.tag]
        // The pattern has to survive its new encoding: `DE A` is fine as ASCII
        // and is not hex, so the encoding is refused rather than the entry
        // quietly becoming unsearchable.
        guard entry.pattern.isEmpty
                || (try? SearchEngine.parsePattern(entry.pattern, encoding: encoding)) != nil else {
            sender.selectItem(at: SearchEncoding.allCases.firstIndex(of: entry.encoding) ?? 0)
            show(message: Self.complaint(about: entry.pattern, as: encoding))
            return
        }
        entry.encoding = encoding
        rows[sender.tag] = entry
        show(message: nil)
        save()
        // The case checkbox belongs to the encoding (hex has none), so the row
        // is redrawn rather than left saying the wrong thing.
        table?.reloadData(forRowIndexes: IndexSet(integer: sender.tag),
                          columnIndexes: IndexSet(integer: 3))
    }

    @objc private func casePicked(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        rows[sender.tag].caseSensitive = sender.state == .on
        show(message: nil)
        save()
    }

    private static func complaint(about pattern: String, as encoding: SearchEncoding) -> String {
        encoding == .hex
            ? "\"\(pattern)\" is not hex — use pairs like DE AD BE EF."
            : "\"\(pattern)\" cannot be written in \(encoding.displayName)."
    }

    // MARK: - Add and remove

    /// Adds an empty row and puts the caret in its Name. Nothing is stored yet:
    /// a row without a pattern is not a search (see the type's note).
    @objc private func addPressed() {
        guard !hasDraft else {
            // One at a time — a second empty row would be indistinguishable
            // from the first, and the store holds neither.
            beginEditing(row: rows.firstIndex { $0.pattern.isEmpty } ?? 0, column: 0)
            return
        }
        rows.append(SearchPatternEntry(pattern: "", encoding: .hex))
        show(message: nil)
        refreshTable()
        let row = rows.count - 1
        table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        beginEditing(row: row, column: 0)
    }

    private func beginEditing(row: Int, column: Int) {
        guard let table, row < rows.count else { return }
        table.scrollRowToVisible(row)
        table.editColumn(column, row: row, with: nil, select: true)
    }

    @objc private func removePressed() {
        guard let table, table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        rows.remove(at: table.selectedRow)
        show(message: nil)
        refreshTable()
        save()
    }

    // MARK: - Reordering

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation)
    -> NSDragOperation {
        // Between rows only: dropping *on* a row would mean something (replace?
        // merge?) that this list has no answer for.
        guard dropOperation == .above, draggedRow(from: info) != nil else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let from = draggedRow(from: info), from < rows.count else { return false }
        move(from: from, above: row)
        return true
    }

    /// Moves a row into the gap above `destination`. The drop index was read
    /// before the row left, so everything after it has shifted down by one.
    private func move(from: Int, above destination: Int) {
        guard from < rows.count else { return }
        let entry = rows.remove(at: from)
        rows.insert(entry, at: min(from < destination ? destination - 1 : destination, rows.count))
        show(message: nil)
        refreshTable()
        save()
    }

    private func draggedRow(from info: NSDraggingInfo) -> Int? {
        guard let text = info.draggingPasteboard.string(forType: Self.rowDragType) else { return nil }
        return Int(text)
    }

    // MARK: - Test seams
    //
    // The settings window is not on screen under XCTest, so a test reaches the
    // cells' controls the way the table builds them: on demand.

    /// The editable field in `row`'s Name or Pattern column.
    func fieldForTests(row: Int, name: Bool) -> NSTextField? {
        cellForTests(row: row, column: name ? 0 : 1)?.textField
    }

    func encodingPopupForTests(row: Int) -> NSPopUpButton? {
        cellForTests(row: row, column: 2)?.subviews.compactMap { $0 as? NSPopUpButton }.first
    }

    func caseCheckboxForTests(row: Int) -> NSButton? {
        cellForTests(row: row, column: 3)?.subviews.compactMap { $0 as? NSButton }.first
    }

    private func cellForTests(row: Int, column: Int) -> NSTableCellView? {
        guard let table, row < rows.count else { return nil }
        return table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
    }

    /// Types `text` into a cell and commits it, the way ending an edit does.
    func typeForTests(_ text: String, row: Int, name: Bool) {
        guard let field = fieldForTests(row: row, name: name) else { return }
        field.stringValue = text
        fieldCommitted(field)
    }

    /// Chooses `encoding` in `row`'s popup and commits it, the way a pick does.
    func pickEncodingForTests(_ encoding: SearchEncoding, row: Int) {
        guard let popup = encodingPopupForTests(row: row),
              let index = SearchEncoding.allCases.firstIndex(of: encoding) else { return }
        popup.selectItem(at: index)
        encodingPicked(popup)
    }

    /// Ticks or unticks `row`'s Match Case box, the way a click does.
    func setCaseForTests(_ on: Bool, row: Int) {
        guard let box = caseCheckboxForTests(row: row) else { return }
        box.state = on ? .on : .off
        casePicked(box)
    }

    /// What the tab is complaining about, if anything.
    var messageForTests: String { messageLabel?.stringValue ?? "" }

    /// Drops `from` into the gap above `to`, through the same move a dragged
    /// row goes through.
    func dropForTests(from: Int, above to: Int) {
        move(from: from, above: to)
    }
}
