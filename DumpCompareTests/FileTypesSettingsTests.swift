import Cocoa
import XCTest
@testable import DumpCompare

/// §25.3: the File Types tab. Every call the tab makes to the system goes
/// through a seam here — the real ones change the machine's file associations
/// and can raise a modal alert — so what these tests pin is the tab's own
/// behaviour: it asks for what the user clicked, and then believes the system
/// rather than the click.
@MainActor
final class FileTypesSettingsTests: XCTestCase {
    private let suite = "FileTypesSettingsTests"
    private var store: UserDefaults!

    /// The system as the tab sees it: which extensions this app handles, and the
    /// name shown for each. A test moves this and reloads, the way reality moves
    /// under the tab.
    private var selfHandled: Set<String> = []
    private var handlerNames: [String: String] = [:]
    private var handlerIDs: [String: String] = [:]

    /// What the tab asked for.
    private var setSelfCalls: [String] = []
    private var setHandlerCalls: [(ext: String, bundleID: String)] = []
    private var messages: [String] = []

    override func setUp() {
        super.setUp()
        store = UserDefaults(suiteName: suite)
        store.removePersistentDomain(forName: suite)
        DefaultHandlerSettings.defaults = store
        selfHandled = []
        handlerNames = ["bin": "Archive Utility", "rom": "DumpCompare"]
        handlerIDs = ["bin": "com.apple.archiveutility", "rom": "dev.maxik.DumpCompare"]
        selfHandled = ["rom"]
        setSelfCalls = []
        setHandlerCalls = []
        messages = []
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        DefaultHandlerSettings.defaults = .standard
        super.tearDown()
    }

    /// A loaded tab with every seam pointed at this test's fake system. The
    /// stubs are installed before the view loads, because loading reads them.
    private func makeTab(prompt: String? = nil) -> FileTypesSettingsViewController {
        let tab = FileTypesSettingsViewController()
        tab.isSelfDefault = { [unowned self] ext in self.selfHandled.contains(ext) }
        tab.handlerName = { [unowned self] ext in self.handlerNames[ext] }
        tab.currentHandlerIdentifier = { [unowned self] ext in self.handlerIDs[ext] }
        tab.presentMessage = { [unowned self] text in self.messages.append(text) }
        tab.promptForExtension = { prompt }
        tab.setSelfAsDefault = { [unowned self] ext, then in
            self.setSelfCalls.append(ext)
            then(nil)
        }
        tab.setHandler = { [unowned self] ext, bundleID, then in
            self.setHandlerCalls.append((ext, bundleID))
            then(nil)
        }
        _ = tab.view
        return tab
    }

    // MARK: - Reading

    /// The rows are the list; the checkbox and the handler column are readings
    /// of the system, not of anything the tab stored.
    func testTheTableShowsTheListAndReadsTheSystem() throws {
        let tab = makeTab()
        XCTAssertEqual(tab.rows.map(\.ext), ["bin", "rom"])
        XCTAssertEqual(tab.table.numberOfRows, 2)

        XCTAssertEqual(tab.checkbox(atRow: 0)?.state, .off, "Archive Utility holds .bin")
        XCTAssertEqual(tab.checkbox(atRow: 1)?.state, .on, "this app holds .rom")
        XCTAssertEqual(tab.handlerLabel(atRow: 0), "Archive Utility")
        XCTAssertEqual(tab.handlerLabel(atRow: 1), "DumpCompare")
    }

    /// An extension nothing claims reads as "—": that nobody opens it is a fact
    /// worth showing, not a blank.
    func testAnUnclaimedExtensionSaysSo() throws {
        handlerNames = [:]
        handlerIDs = [:]
        selfHandled = []
        let tab = makeTab()
        XCTAssertEqual(tab.handlerLabel(atRow: 0), "—")
        XCTAssertEqual(tab.checkbox(atRow: 0)?.state, .off)
    }

    /// A default changed elsewhere — in Finder, or by another app — shows up on
    /// the next appearance (§25.3).
    func testTheTabRereadsTheSystemWhenItAppears() throws {
        let tab = makeTab()
        XCTAssertEqual(tab.checkbox(atRow: 0)?.state, .off)

        selfHandled.insert("bin")
        handlerNames["bin"] = "DumpCompare"
        tab.viewWillAppear()

        XCTAssertEqual(tab.checkbox(atRow: 0)?.state, .on)
        XCTAssertEqual(tab.handlerLabel(atRow: 0), "DumpCompare")
    }

    // MARK: - Ticking

    /// Ticking asks the system for that extension, and records who is being
    /// displaced first — after the change the answer would be this app, and
    /// unticking would have nowhere to hand the type back to (§25.3).
    func testTickingAsksTheSystemAndRemembersWhoHeldTheType() throws {
        let tab = makeTab()
        let checkbox = try XCTUnwrap(tab.checkbox(atRow: 0))
        XCTAssertEqual(checkbox.state, .off, "Archive Utility holds it, so the click will tick")
        // The fake system grants it.
        tab.setSelfAsDefault = { [unowned self] ext, then in
            self.setSelfCalls.append(ext)
            self.selfHandled.insert(ext)
            self.handlerNames[ext] = "DumpCompare"
            then(nil)
        }
        checkbox.performClick(nil)

        XCTAssertEqual(setSelfCalls, ["bin"])
        XCTAssertEqual(DefaultHandlerSettings.displacedHandler(for: "bin"), "com.apple.archiveutility")
        XCTAssertEqual(tab.checkbox(atRow: 0)?.state, .on)
        XCTAssertEqual(tab.handlerLabel(atRow: 0), "DumpCompare")
        XCTAssertEqual(messages, [], "granting a type says nothing")
    }

    /// The system's answer can be no — the user declining its confirmation is a
    /// normal outcome. The checkbox then goes back to what the system says, and
    /// the tab reports nothing (§25.3).
    func testATickTheSystemDeclinesGoesBackWithoutComplaint() throws {
        let tab = makeTab()
        let checkbox = try XCTUnwrap(tab.checkbox(atRow: 0))
        // Granted nothing: the fake system is left as it was, with an error.
        tab.setSelfAsDefault = { [unowned self] ext, then in
            self.setSelfCalls.append(ext)
            then(CocoaError(.userCancelled))
        }
        checkbox.performClick(nil)

        XCTAssertEqual(setSelfCalls, ["bin"])
        XCTAssertEqual(tab.checkbox(atRow: 0)?.state, .off, "the row shows the system, not the click")
        XCTAssertEqual(tab.handlerLabel(atRow: 0), "Archive Utility")
        XCTAssertEqual(messages, [], "a decision the user made needs no alert about it")
    }

    /// The guard in the register path: between the row being drawn and the click
    /// landing, the system's answer can already be this app (the user set it in
    /// Finder meanwhile). Recording that as the displaced handler would make
    /// unticking hand the type to itself, so it is not recorded.
    func testTickingATypeTheSystemAlreadySaysIsOursRecordsNothing() throws {
        // The row was drawn as off, and by click time the handler is this app.
        handlerIDs["bin"] = DefaultHandlerService.selfBundleIdentifier
        let tab = makeTab()
        try XCTUnwrap(tab.checkbox(atRow: 0)).performClick(nil)

        XCTAssertEqual(setSelfCalls, ["bin"], "the tick is still asked for")
        XCTAssertNil(DefaultHandlerSettings.displacedHandler(for: "bin"))
    }

    // MARK: - Unticking

    /// Unticking hands the type back to the app the tab took it from, and then
    /// forgets it: a second uncheck has nothing left to do.
    func testUntickingHandsTheTypeBackAndForgetsIt() throws {
        DefaultHandlerSettings.recordDisplacedHandler("com.apple.archiveutility", for: "bin")
        selfHandled.insert("bin")
        handlerNames["bin"] = "DumpCompare"
        let tab = makeTab()
        let checkbox = try XCTUnwrap(tab.checkbox(atRow: 0))
        XCTAssertEqual(checkbox.state, .on)

        tab.setHandler = { [unowned self] ext, bundleID, then in
            self.setHandlerCalls.append((ext, bundleID))
            self.selfHandled.remove(ext)
            self.handlerNames[ext] = "Archive Utility"
            then(nil)
        }
        checkbox.performClick(nil)

        XCTAssertEqual(setHandlerCalls.map(\.ext), ["bin"])
        XCTAssertEqual(setHandlerCalls.map(\.bundleID), ["com.apple.archiveutility"])
        XCTAssertNil(DefaultHandlerSettings.displacedHandler(for: "bin"), "handed back, so forgotten")
        XCTAssertEqual(tab.checkbox(atRow: 0)?.state, .off)
        XCTAssertEqual(tab.handlerLabel(atRow: 0), "Archive Utility")
    }

    /// A refused hand-back keeps the record: the type is still this app's, and
    /// the user may try again.
    func testARefusedHandBackKeepsTheRecord() throws {
        DefaultHandlerSettings.recordDisplacedHandler("com.apple.archiveutility", for: "bin")
        selfHandled.insert("bin")
        handlerNames["bin"] = "DumpCompare"
        let tab = makeTab()
        tab.setHandler = { [unowned self] ext, bundleID, then in
            self.setHandlerCalls.append((ext, bundleID))
            then(CocoaError(.userCancelled))
        }
        let checkbox = try XCTUnwrap(tab.checkbox(atRow: 0))
        XCTAssertEqual(checkbox.state, .on)
        checkbox.performClick(nil)

        XCTAssertEqual(DefaultHandlerSettings.displacedHandler(for: "bin"), "com.apple.archiveutility")
        XCTAssertEqual(tab.checkbox(atRow: 0)?.state, .on, "the type is still this app's")
    }

    /// With nobody recorded there is nothing to hand the type to — macOS has no
    /// API to clear a default — so the tab says what the user has to do instead
    /// of pretending the click worked (§25.3).
    func testUntickingWithNothingRecordedExplainsItself() throws {
        selfHandled.insert("bin")
        handlerNames["bin"] = "DumpCompare"
        let tab = makeTab()
        let checkbox = try XCTUnwrap(tab.checkbox(atRow: 0))
        XCTAssertEqual(checkbox.state, .on)
        checkbox.performClick(nil)

        XCTAssertEqual(setHandlerCalls.count, 0, "nothing to ask for")
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(message.contains(".bin"), "the message names the type: \(message)")
        XCTAssertEqual(tab.checkbox(atRow: 0)?.state, .on, "the row still shows the system")
    }

    // MARK: - The list

    /// `+` takes an extension, normalizes it, adds the row and selects it — the
    /// user's own extension works like the built-in ones (§25.2).
    func testAddingAnExtensionAddsAndSelectsTheRow() throws {
        let tab = makeTab(prompt: ".Dump")
        tab.addButton.performClick(nil)

        XCTAssertEqual(tab.rows.map(\.ext), ["bin", "rom", "dump"])
        XCTAssertEqual(tab.table.selectedRow, 2, "the new row is selected, so − acts on it")
        XCTAssertEqual(messages, [])
    }

    func testAddingSomethingThatIsNotAnExtensionSaysSo() throws {
        let tab = makeTab(prompt: "a/b")
        tab.addButton.performClick(nil)

        XCTAssertEqual(tab.rows.map(\.ext), ["bin", "rom"])
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(message.contains("a/b"), message)
    }

    func testCancellingTheAddPromptAddsNothing() throws {
        let tab = makeTab(prompt: nil)
        tab.addButton.performClick(nil)
        XCTAssertEqual(tab.rows.map(\.ext), ["bin", "rom"])
        XCTAssertEqual(messages, [])
    }

    /// `−` is dead until a row is selected, and then removes that row from the
    /// list only: the association is the system's, and the tab says so when the
    /// removed type is still this app's (§25.3).
    func testRemovingTheSelectedRow() throws {
        let tab = makeTab()
        XCTAssertFalse(tab.removeButton.isEnabled, "nothing selected")

        tab.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(tab.removeButton.isEnabled)
        tab.removeButton.performClick(nil)

        XCTAssertEqual(tab.rows.map(\.ext), ["rom"])
        XCTAssertEqual(messages, [], "Archive Utility held .bin, so its removal is silent")
    }

    func testRemovingATypeThisAppStillHoldsSaysWhatHappened() throws {
        let tab = makeTab()
        tab.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        tab.removeButton.performClick(nil)

        XCTAssertEqual(tab.rows.map(\.ext), ["bin"])
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(message.contains(".rom"), message)
    }

    // MARK: - The tab in the window

    /// The Settings window carries File Types as its sixth tab, and its toolbar
    /// item switches to it.
    func testTheSettingsWindowCarriesTheFileTypesTab() throws {
        let controller = SettingsWindowController()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(window.toolbar)
        let identifier = NSToolbarItem.Identifier("FileTypes")

        XCTAssertTrue(controller.toolbarDefaultItemIdentifiers(toolbar).contains(identifier))
        let item = try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: identifier,
                                                   willBeInsertedIntoToolbar: true))
        XCTAssertEqual(item.label, "File Types")
        XCTAssertNotNil(item.image)

        _ = NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        XCTAssertTrue(window.contentViewController is FileTypesSettingsViewController,
                      "the item selects the tab")
    }
}
