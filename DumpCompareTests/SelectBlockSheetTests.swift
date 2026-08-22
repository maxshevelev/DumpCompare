import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §10.2 Select Block: three fields — Start, End, Length — where the radio
/// buttons before End and Length activate exactly one of the two, and the
/// inactive field is disabled but keeps the value the user already typed.
@MainActor
final class SelectBlockSheetTests: XCTestCase {
    /// Builds a sheet, forces `loadView`, and captures whatever `handleSubmit`
    /// hands to the `onSelect` callback.
    private func makeSheet(fileSize: UInt64 = 0x100,
                           presetStart: UInt64? = nil) -> (sheet: SelectBlockSheetController, selection: () -> SelectionModel?) {
        var captured: SelectionModel?
        let sheet = SelectBlockSheetController(fileSize: fileSize, presetStart: presetStart) { captured = $0 }
        _ = sheet.view  // loadView builds the widgets
        return (sheet, { captured })
    }

    /// Opened from the offset context menu the sheet says nothing above its
    /// fields: the Start field already shows the address that was right-clicked
    /// and Length is already the active option, so a sentence saying both would be
    /// the sheet narrating its own fields (§10.2).
    func testThePresetSheetHasNoMessageAboveItsFields() throws {
        let preset = SelectBlockSheetController(fileSize: 0x1000, presetStart: 0x24) { _ in }
        preset.loadViewIfNeeded()
        XCTAssertNil(preset.messageText)
        XCTAssertEqual(preset.startField.stringValue, "0x24", "the address is in the field instead")

        let plain = SelectBlockSheetController(fileSize: 0x1000) { _ in }
        plain.loadViewIfNeeded()
        XCTAssertNotNil(plain.messageText,
                        "opened from the menu bar it still says what End means")
        XCTAssertLessThan(preset.view.fittingSize.height, plain.view.fittingSize.height,
                          "and the sheet is shorter for the line it does not show")
    }

    /// A sheet is as tall as its own rows: a floor of 200 pt left the one-field
    /// sheets with a hand's width of nothing between the field and the buttons,
    /// because the slack had to go somewhere (§10).
    func testASheetIsAsTallAsItsRows() throws {
        let fill = FillSheetController(selectionCount: 64) { _ in }
        fill.loadViewIfNeeded()
        fill.view.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(fill.firstField())
        let fieldFrame = fill.view.convert(field.bounds, from: field)
        let buttons = fill.view.convert(fill.buttonRow.bounds, from: fill.buttonRow)
        // The sheet's root view is not flipped, so lower means a smaller y.
        let gap = fieldFrame.minY - buttons.maxY
        XCTAssertGreaterThan(gap, 0, "the buttons are below the field")
        XCTAssertLessThan(gap, 40, "and not a hand's width away")

        let block = SelectBlockSheetController(fileSize: 0x100) { _ in }
        block.loadViewIfNeeded()
        block.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(block.view.fittingSize.height, fill.view.fittingSize.height,
                             "three rows of fields make a taller sheet than one")
    }

    /// The validation message lines up with the fields it is about, not with the
    /// sheet's left edge (§10).
    func testTheValidationMessageLinesUpWithTheFields() throws {
        let (sheet, _) = makeSheet()
        sheet.startField.stringValue = "0xZZ"
        _ = sheet.validate()
        sheet.showError("Invalid start offset.")
        sheet.view.layoutSubtreeIfNeeded()

        let message = sheet.view.convert(sheet.errorLabel.bounds, from: sheet.errorLabel)
        let field = sheet.view.convert(sheet.startField.bounds, from: sheet.startField)
        XCTAssertEqual(message.minX, field.minX, accuracy: 3)
    }

    // MARK: - Default state

    func testDefaultStateEndActiveLengthDisabled() {
        let (sheet, _) = makeSheet()
        XCTAssertEqual(sheet.endRadio.state, .on)
        XCTAssertEqual(sheet.lengthRadio.state, .off)
        XCTAssertTrue(sheet.endField.isEnabled)
        XCTAssertFalse(sheet.lengthField.isEnabled,
                       "Length is not the active mode by default")
    }

    /// §10: focus must not select the "0x" prefix — the caret sits right after
    /// it so the user types hex digits immediately (and deletes the prefix only
    /// for a decimal value). The rule belongs to EVERY field, not just the one
    /// `viewDidAppear` focuses, so the same sheet is asked twice.
    func testFocusPositionsCaretAfterThe0xPrefixInEveryField() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let (sheet, _) = makeSheet()
        window.contentView = sheet.view

        sheet.viewDidAppear()
        guard let first = window.firstResponder as? NSTextView else {
            return XCTFail("the field's editor must be first responder after focus")
        }
        XCTAssertEqual(first.selectedRange.location, 2,
                       "the caret must sit after the 0x prefix")
        XCTAssertEqual(first.selectedRange.length, 0,
                       "the prefix must not be selected")

        window.makeFirstResponder(sheet.endField)
        guard let end = window.firstResponder as? NSTextView else {
            return XCTFail("the End field's editor must be first responder")
        }
        XCTAssertEqual(end.selectedRange.location, 2,
                       "a field focused later gets the same caret placement")
        XCTAssertEqual(end.selectedRange.length, 0,
                       "and the same unselected prefix")
    }

    // MARK: - Radio switching

    /// The radios activate exactly one of End / Length in either direction, and
    /// the field being disabled keeps whatever was already typed into it — so
    /// switching modes to look at the other one loses nothing (§10.2).
    func testSwitchingTheActiveFieldDisablesTheOtherButKeepsItsValue() {
        let (sheet, _) = makeSheet()
        sheet.endField.stringValue = "0x100"
        sheet.lengthField.stringValue = "0x40"

        sheet.lengthRadio.performClick(nil)

        XCTAssertEqual(sheet.lengthRadio.state, .on)
        XCTAssertEqual(sheet.endRadio.state, .off)
        XCTAssertTrue(sheet.lengthField.isEnabled)
        XCTAssertFalse(sheet.endField.isEnabled)
        XCTAssertEqual(sheet.endField.stringValue, "0x100",
                       "the disabled End field must keep the value already entered")

        sheet.endRadio.performClick(nil)      // back to End

        XCTAssertEqual(sheet.endRadio.state, .on)
        XCTAssertEqual(sheet.lengthRadio.state, .off)
        XCTAssertTrue(sheet.endField.isEnabled)
        XCTAssertFalse(sheet.lengthField.isEnabled)
        XCTAssertEqual(sheet.lengthField.stringValue, "0x40",
                       "the re-disabled Length field must restore its value")
    }

    // MARK: - Submit

    func testEndModeSubmitBuildsStartEndSelection() {
        let (sheet, selection) = makeSheet()
        sheet.startField.stringValue = "0x10"
        sheet.endField.stringValue = "0x20"      // End is the block's LAST byte
        sheet.lengthField.stringValue = "0x99"   // inactive — ignored
        XCTAssertNil(sheet.validate())
        sheet.handleSubmit()
        XCTAssertEqual(selection(), SelectionModel(start: 0x10, end: 0x21, fileSize: 0x100),
                       "End is inclusive — the half-open range ends after it")
    }

    func testLengthModeSubmitBuildsStartLengthSelection() {
        let (sheet, selection) = makeSheet()
        sheet.lengthRadio.performClick(nil)
        sheet.startField.stringValue = "0x10"
        sheet.endField.stringValue = "0x99"     // inactive — ignored
        sheet.lengthField.stringValue = "0x5"
        XCTAssertNil(sheet.validate())
        sheet.handleSubmit()
        XCTAssertEqual(selection(), SelectionModel(start: 0x10, length: 0x5, fileSize: 0x100))
    }

    // MARK: - Validation

    func testValidationRejectsStartBeyondFile() {
        let (sheet, _) = makeSheet(fileSize: 0x80)
        sheet.startField.stringValue = "0x100"
        XCTAssertEqual(sheet.validate(), "Start is beyond the end of the file.")
    }

    func testValidationRejectsStartAfterEnd() {
        let (sheet, _) = makeSheet()
        sheet.startField.stringValue = "0x20"
        sheet.endField.stringValue = "0x10"
        XCTAssertEqual(sheet.validate(), "Start must not exceed end.")
    }

    /// End is a byte address, so the last byte (fileSize - 1) is fine, but the
    /// byte PAST EOF (fileSize) is not — there is no last byte there — and
    /// neither is anything further out.
    func testValidationRejectsEndAtOrBeyondFileSize() {
        let (sheet, _) = makeSheet(fileSize: 0x80)
        sheet.startField.stringValue = "0x10"

        sheet.endField.stringValue = "0x80"
        XCTAssertEqual(sheet.validate(), "End is beyond the end of the file.",
                       "fileSize itself is one past the file's last byte")

        sheet.endField.stringValue = "0x100"
        XCTAssertEqual(sheet.validate(), "End is beyond the end of the file.",
                       "and an address well past EOF is rejected the same way")
    }

    /// A block that ends at the file's last byte is valid and reaches EOF.
    func testEndModeSubmitAtFileSizeBoundary() {
        let (sheet, selection) = makeSheet(fileSize: 0x80)
        sheet.startField.stringValue = "0x10"
        sheet.endField.stringValue = "0x7F"      // last byte of the file
        XCTAssertNil(sheet.validate())
        sheet.handleSubmit()
        XCTAssertEqual(selection(), SelectionModel(start: 0x10, end: 0x80, fileSize: 0x80))
    }

    func testValidationRejectsInvalidEnd() {
        let (sheet, _) = makeSheet()
        sheet.startField.stringValue = "0x10"
        sheet.endField.stringValue = "not-a-number"
        XCTAssertEqual(sheet.validate(), "Invalid end offset.")
    }

    func testValidationRejectsInvalidLength() {
        let (sheet, _) = makeSheet()
        sheet.lengthRadio.performClick(nil)
        sheet.startField.stringValue = "0x10"
        sheet.lengthField.stringValue = "not-a-number"
        XCTAssertEqual(sheet.validate(), "Invalid length.")
    }

    // MARK: - Live validation (§10)

    /// Simulates a keystroke the way the real editing path does: the field
    /// editor's text changes, then the control's `textDidChange` fires (with
    /// the editor as the notification object). That is exactly what
    /// `HexInputField` uses to trigger live re-validation, so a manual call is
    /// required — a programmatic `string` set alone doesn't fire it.
    private func type(_ value: String, into field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else {
            field.stringValue = value
            field.textDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            return
        }
        editor.string = value
        field.textDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor))
    }

    /// A window hosting the sheet, kept alive for the test so the focused
    /// field's editor doesn't vanish mid-test.
    private func hostingWindow(for sheet: SelectBlockSheetController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = sheet.view
        return window
    }

    /// Validation runs during input: an incomplete offset shows the error the
    /// moment it's typed, not only on submit or focus loss.
    func testLiveValidationShowsErrorWhileTyping() {
        let (sheet, _) = makeSheet()
        let window = hostingWindow(for: sheet)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(sheet.startField)
        type("0x", into: sheet.startField)   // prefix alone is invalid
        XCTAssertEqual(sheet.errorLabel.stringValue, "Invalid start offset.")
    }

    /// The error clears as soon as the whole form becomes valid — the user
    /// typed a correct value, so the stale message must not linger. The prefix
    /// is only for hex, so a decimal value (prefix deleted) clears it too.
    func testLiveValidationClearsTheErrorForAValidHexOrDecimalValue() {
        let (sheet, _) = makeSheet()
        let window = hostingWindow(for: sheet)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(sheet.startField)
        type("0x", into: sheet.startField)   // triggers an error
        XCTAssertFalse(sheet.errorLabel.isHidden)

        sheet.endField.stringValue = "0x30"
        type("0x20", into: sheet.startField)
        XCTAssertTrue(sheet.errorLabel.isHidden,
                      "a valid hex offset must clear the live error")

        type("0x", into: sheet.startField)   // back to invalid
        XCTAssertFalse(sheet.errorLabel.isHidden,
                       "an incomplete offset brings the error back")
        type("32", into: sheet.startField)
        XCTAssertTrue(sheet.errorLabel.isHidden,
                      "a decimal offset must validate like hex")
    }

    // MARK: - Submit only on OK / Return

    /// Activation must happen only on OK / Return — moving focus to another
    /// field with valid values must NOT submit the selection (the old
    /// `sendsActionOnEndEditing` default fired the field's action on focus
    /// loss, an unexpected side effect).
    func testLosingFocusDoesNotActivateSelection() {
        let (sheet, selection) = makeSheet()
        let window = hostingWindow(for: sheet)
        defer { window.orderOut(nil) }
        sheet.startField.stringValue = "0x10"
        sheet.endField.stringValue = "0x20"
        window.makeFirstResponder(sheet.startField)
        // Valid values, focus moves away — the block must not be activated.
        window.makeFirstResponder(sheet.endField)
        XCTAssertNil(selection(),
                     "losing focus must not activate the selection")
    }

    // MARK: - Preset start ("Select block from here", §10.2)

    /// Opened from the offset context menu: Start is pre-filled with the
    /// clicked address, Length is the active option (End disabled), and the
    /// first responder lands in the Length field.
    func testPresetStartPrefillsStartAndActivatesLength() {
        let (sheet, _) = makeSheet(presetStart: 0x24)
        XCTAssertEqual(sheet.startField.stringValue, "0x24")
        XCTAssertEqual(sheet.endRadio.state, .off)
        XCTAssertEqual(sheet.lengthRadio.state, .on)
        XCTAssertFalse(sheet.endField.isEnabled)
        XCTAssertTrue(sheet.lengthField.isEnabled)
        XCTAssertTrue(sheet.firstField() === sheet.lengthField,
                       "the cursor must land in the Length field")
    }

    /// The preset Start stays editable — a right-click pre-fills the address,
    /// it doesn't lock it; the form follows a later change.
    func testPresetStartRemainsEditable() {
        let (sheet, selection) = makeSheet(presetStart: 0x24)
        sheet.startField.stringValue = "0x30"
        sheet.lengthField.stringValue = "0x4"
        XCTAssertNil(sheet.validate())
        sheet.handleSubmit()
        XCTAssertEqual(selection(), SelectionModel(start: 0x30, length: 0x4, fileSize: 0x100))
    }

    /// Switching from the preset Length mode back to End keeps the pre-filled
    /// Start and validates against End (the block's last byte, inclusive).
    func testPresetStartCanSwitchToEndMode() {
        let (sheet, selection) = makeSheet(presetStart: 0x24)
        sheet.endRadio.performClick(nil)
        XCTAssertEqual(sheet.endRadio.state, .on)
        XCTAssertEqual(sheet.lengthRadio.state, .off)
        XCTAssertTrue(sheet.endField.isEnabled)
        XCTAssertFalse(sheet.lengthField.isEnabled)
        XCTAssertEqual(sheet.startField.stringValue, "0x24")
        sheet.endField.stringValue = "0x2F"
        XCTAssertNil(sheet.validate())
        sheet.handleSubmit()
        XCTAssertEqual(selection(), SelectionModel(start: 0x24, end: 0x30, fileSize: 0x100),
                       "End is inclusive — the half-open range ends after it")
    }

    /// The preset's focus is the Length field, and its caret sits after the
    /// "0x" prefix so hex digits can be typed immediately (§10).
    func testPresetFocusLandsInLengthWithCaretAfterPrefix() {
        let (sheet, _) = makeSheet(presetStart: 0x24)
        let window = hostingWindow(for: sheet)
        defer { window.orderOut(nil) }
        window.contentView = sheet.view
        sheet.viewDidAppear()
        guard let editor = window.firstResponder as? NSTextView else {
            return XCTFail("the Length field's editor must be first responder")
        }
        XCTAssertTrue(sheet.lengthField.currentEditor() != nil,
                      "the first responder's editing session must belong to Length")
        XCTAssertEqual(editor.selectedRange.location, 2,
                       "the caret must sit after the 0x prefix")
        XCTAssertEqual(editor.selectedRange.length, 0,
                       "the prefix must not be selected")
    }

    /// Validation still runs live in the preset: a bad length shows the error
    /// the moment it is typed, and the correct value clears it.
    func testPresetLiveValidationCoversLength() {
        let (sheet, _) = makeSheet(presetStart: 0x24)
        let window = hostingWindow(for: sheet)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(sheet.lengthField)
        type("0x", into: sheet.lengthField)   // prefix alone is invalid
        XCTAssertEqual(sheet.errorLabel.stringValue, "Invalid length.")

        type("0x10", into: sheet.lengthField)
        XCTAssertTrue(sheet.errorLabel.isHidden,
                      "a valid length must clear the live error")
    }

}
