import Cocoa

// A prototype of the Find bar's pattern field: the combo it has today, above
// the search field with a sectioned menu, as settled in
// PATTERN_LIBRARY_IDEA.md. Built to be looked at — the questions it answers
// are whether a search field sits in the bar's stack the way the combo does,
// and whether the menu reads.
//
//   swiftc -o /tmp/pattern-field Design/pattern-field-prototype.swift
//   /tmp/pattern-field /tmp          # writes /tmp/bars.png, then waits
//
// ⌘Q quits. The menu is opened from the disclosure arrow beside the magnifier;
// it is its own window, so it cannot be captured by `cacheDisplay` — that one
// is for the eye.
//
// The bar's real metrics are used throughout — spacing 8, insets 8/10, icons
// 13pt, the count in monospaced digits at 11pt over an "8888 of 8888"
// template — so the comparison is honest. The sample entries are made up.

let iconPointSize: CGFloat = 13
let shotDirectory = CommandLine.arguments.dropFirst().first ?? "."

func icon(_ name: String, weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: iconPointSize, weight: weight))
}

func iconButton(_ name: String, on: Bool = false) -> NSButton {
    let button = NSButton()
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.image = icon(name)
    button.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
    button.symbolConfiguration = .init(pointSize: iconPointSize,
                                       weight: on ? .semibold : .regular)
    return button
}

let history: [(pattern: String, encoding: String, caseSensitive: Bool)] = [
    ("DE AD BE EF", "Hex bytes", false),
    ("windows", "UTF-16 LE", false),
    ("Root", "ASCII", true),
    ("FF 33", "Hex bytes", false),
]

/// A favourite: a name, the pattern itself, and what it is searched as.
let favourites: [(name: String, pattern: String, encoding: String, caseSensitive: Bool)] = [
    ("ME FPT", "$FPT", "Hex bytes", false),
    ("Aptio capsule header", "5A A5 F0 0F", "Hex bytes", false),
    ("Vendor S/N table", "SN:", "ASCII", true),
    ("EFI volume header", "_FVH", "ASCII", false),
    ("Windows loader string", "windows", "UTF-16 LE", false),
]

/// Every actionable row is given a target and an action. Without one AppKit
/// disables it — `autoenablesItems` — and draws it dimmed, which is why the
/// prototype's first menu came out grey throughout.
final class MenuActions: NSObject {
    @objc func pick(_ sender: Any?) {}
}
let menuActions = MenuActions()

/// The menu's type sizes. Smaller than the system menu's 13pt: these rows are
/// a list to scan rather than commands to read one at a time.
let rowSize: CGFloat = 12
let flagSize: CGFloat = 11

func actionItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(MenuActions.pick(_:)),
                          keyEquivalent: "")
    item.target = menuActions
    item.attributedTitle = NSAttributedString(
        string: title, attributes: [.font: NSFont.systemFont(ofSize: rowSize)])
    return item
}

/// One row of either list: `Name: "pattern", flags` for a favourite,
/// `"pattern", flags` for a recent — the same shape, minus the description
/// nothing typed into the field has.
///
/// The flags are grey, which is what separates them from the pattern: they say
/// how it is searched, not what is searched for.
func patternItem(name: String?, pattern: String, encoding: String,
                 caseSensitive: Bool) -> NSMenuItem {
    let item = actionItem(name ?? pattern)
    let title = NSMutableAttributedString()
    let row: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: rowSize)]
    if let name {
        title.append(NSAttributedString(string: "\(name): ", attributes: row))
    }
    title.append(NSAttributedString(string: "\"\(pattern)\"", attributes: row))
    // The case rule is stated either way — "ignore case" is a fact about the
    // search, not the absence of one, and a reader should not have to know
    // which way the silence went. Hex is the exception: bytes have no case, so
    // there is nothing to state (§11).
    let flags = encoding == "Hex bytes"
        ? encoding
        : "\(encoding), \(caseSensitive ? "match case" : "ignore case")"
    title.append(NSAttributedString(
        string: "  \(flags)",
        attributes: [.font: NSFont.systemFont(ofSize: flagSize),
                     .foregroundColor: NSColor.secondaryLabelColor]))
    item.attributedTitle = title
    return item
}

/// A section header carrying an icon: `NSMenuItem.sectionHeader(title:)` takes
/// only a title, so the header is built by hand — disabled, the symbol as its
/// image, and the title in the header's own weight and colour.
func header(_ title: String, symbol: String) -> NSMenuItem {
    let item = NSMenuItem()
    item.isEnabled = false
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    item.attributedTitle = NSAttributedString(
        string: title,
        attributes: [.font: NSFont.systemFont(ofSize: flagSize, weight: .semibold),
                     .foregroundColor: NSColor.secondaryLabelColor])
    return item
}

/// The menu the search field drops (the structure as settled): recents with
/// their own commands, then favourites with theirs.
func libraryMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(header("Recent Queries", symbol: "clock"))
    for entry in history {
        menu.addItem(patternItem(name: nil, pattern: entry.pattern,
                                 encoding: entry.encoding,
                                 caseSensitive: entry.caseSensitive))
    }
    // The commands are about the list above them, and are not part of it.
    menu.addItem(.separator())
    menu.addItem(actionItem("Add to Favorites"))
    menu.addItem(actionItem("Clear Recents"))
    menu.addItem(.separator())
    menu.addItem(header("Favorites", symbol: "star.fill"))
    for entry in favourites {
        menu.addItem(patternItem(name: entry.name, pattern: entry.pattern,
                                 encoding: entry.encoding,
                                 caseSensitive: entry.caseSensitive))
    }
    menu.addItem(.separator())
    menu.addItem(actionItem("Manage Favorites…"))
    return menu
}

func countLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "3 of 128")
    label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.alignment = .right
    let template = "8888 of 8888" as NSString
    let width = template.size(withAttributes: [.font: label.font!]).width
    label.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(width)).isActive = true
    return label
}

func encodingPopup() -> NSPopUpButton {
    let popup = NSPopUpButton()
    popup.addItems(withTitles: ["Hex bytes", "ASCII", "UTF-8", "UTF-16 LE", "UTF-16 BE"])
    popup.selectItem(at: 1)
    return popup
}

func stepper() -> NSSegmentedControl {
    NSSegmentedControl(images: [icon("chevron.left") ?? NSImage(),
                                icon("chevron.right") ?? NSImage()],
                       trackingMode: .momentary, target: nil, action: nil)
}

/// One bar, built the way `FindBarView` builds its stack.
func bar(field: NSView, label: String) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

    let caption = NSTextField(labelWithString: label)
    caption.font = .systemFont(ofSize: 9, weight: .semibold)
    caption.textColor = .tertiaryLabelColor

    let find = NSTextField(labelWithString: "Find")
    find.font = .systemFont(ofSize: 12)
    find.textColor = .secondaryLabelColor

    let done = NSButton(title: "Done", target: nil, action: nil)

    let stack = NSStackView(views: [find, field, encodingPopup(),
                                    iconButton("wand.and.sparkles", on: true),
                                    iconButton("textformat"), countLabel(), stepper(),
                                    iconButton("list.bullet"), done])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    stack.translatesAutoresizingMaskIntoConstraints = false
    for view in stack.views where view !== field {
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    caption.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    container.addSubview(caption)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: container.topAnchor),
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        caption.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: -2),
        caption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
        caption.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
    ])
    return container
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let searchField = NSSearchField()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let combo = NSComboBox()
        combo.addItems(withObjectValues: history.map { "\($0.pattern) — \($0.encoding)" })
        combo.stringValue = "windows"
        combo.completes = false

        searchField.stringValue = "windows"
        searchField.searchMenuTemplate = libraryMenu()
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false

        let rows = NSStackView(views: [bar(field: combo, label: "TODAY — NSComboBox"),
                                       bar(field: searchField,
                                           label: "PROPOSED — NSSearchField with a sectioned menu")])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.distribution = .fillEqually
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        rows.translatesAutoresizingMaskIntoConstraints = false
        for row in rows.views {
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 860, height: 150),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Find bar — pattern field prototype"
        window.contentView = rows
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // A crisp picture of the two bars, drawn by the views themselves. The
        // menu is its own window and cannot be drawn this way — that one is
        // for looking at live, from the magnifier's disclosure arrow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            write(rows, to: "\(shotDirectory)/bars.png")
        }
    }

    private func write(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
// A menu bar for one reason: ⌘Q. A prototype must not be a thing to hunt down
// in Activity Monitor.
let mainMenu = NSMenu()
let appItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Prototype", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
appItem.submenu = appMenu
mainMenu.addItem(appItem)
app.mainMenu = mainMenu
app.run()
