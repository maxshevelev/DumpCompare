import AppKit
import AppPalette

/// A table in a tool-module's panel, drawn at the panel's size
/// (`ToolPanelFont`) rather than at one of AppKit's three fixed row styles.
///
/// Both firmware panels have one, and getting a table to follow a type size
/// takes three things AppKit does not do by itself:
///
/// - `rowSizeStyle` has to be `.custom`, or the row height is one of the fixed
///   numbers behind `.small`/`.medium`/`.large` and text past about 12 points
///   is clipped by it.
/// - A column's header draws with its own font, which is not the cell's.
/// - A header view keeps whatever height it was given when the scroll view
///   tiled it, and re-tiling hands it that same height again — so a taller
///   header needs a view that insists on its height rather than a one-off
///   `frame` assignment (measured: the assignment is undone by the next tile).
@MainActor public enum ToolPanelTable {
    /// A header that keeps the height the panel asks for.
    public final class HeaderView: NSTableHeaderView {
        /// What the header is tall, whatever the scroll view tiles it to.
        public var preferredHeight: CGFloat = ToolPanelFont.headerHeight {
            didSet {
                guard preferredHeight != oldValue else { return }
                frame = frame
                enclosingScrollView?.tile()
                needsDisplay = true
            }
        }

        override public var frame: NSRect {
            get { super.frame }
            set {
                var height = newValue
                height.size.height = preferredHeight
                super.frame = height
            }
        }
    }

    /// Multiplies every column's width by `ratio` — how a table follows a
    /// zoom without forgetting a width the user set.
    ///
    /// Scaled from the width the column *has*, not recomputed from the width
    /// the panel was laid out with: a column the user dragged wider keeps
    /// being the wider one, and one nobody has touched lands where the design
    /// put it.
    public static func scaleColumnWidths(of table: NSTableView, by ratio: CGFloat) {
        guard ratio > 0, ratio != 1 else { return }
        for column in table.tableColumns {
            column.width = (column.width * ratio).rounded()
        }
    }

    // MARK: - Cells

    /// The tag a cell's marker wears, so a recycled cell can find the icon it
    /// was given and restyle or hide it per row. A view, not a pointer to
    /// remember: cells come back out of the pool without their state.
    public static let markerTag = 6_001

    /// A cell for a view-based table drawn at the panel's size: one line of
    /// text, cut short at the end, optionally with icons at the leading edge —
    /// a red warning triangle for the column that marks a bad row, and a
    /// marker slot ahead of it for a row's second verdict.
    ///
    /// One factory for both firmware panels — the cell is the same shape in
    /// each — and the caller sets the font it wants per row afterwards, since
    /// a column of numbers reads in monospaced digits and a column of words
    /// does not. Only the FIT panel's Type column asks for the marker slot;
    /// every other cell, the UEFI panel's included, is what it always was.
    ///
    /// The text never wraps. A field free to take a second line is a field
    /// taller than its row, and a view does not clip its drawing: the second
    /// line lands on the rows above and below (measured, in the UEFI tree —
    /// half a GUID over its neighbour's name, the disclosure arrow buried).
    public static func makeCell(
        identifier: NSUserInterfaceItemIdentifier,
        warning: Bool = false,
        marker: Bool = false
    ) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = ToolPanelFont.body()
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.isBordered = false
        field.drawsBackground = false
        // The column's width wins over the text's: a value wider than the
        // column is cut short rather than pushing the cell wider.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = field

        let content: NSView
        if warning || marker {
            var leading: [NSView] = []
            if marker {
                // Ahead of the warning: a row's "latest" verdict is what the
                // user is reading the column for, and the warning is the older,
                // sadder mark.
                let mark = makeMarker()
                leading.append(mark)
            }
            if warning {
                let triangle = makeWarning()
                cell.imageView = triangle
                leading.append(triangle)
            }
            let row = NSStackView(views: leading + [field])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4
            // Packed against the leading edge with the text taking the rest:
            // the stack is as wide as the column, and one that hands its slack
            // to its views instead reads as a right-aligned column (measured —
            // the triangle and the name sat against the column's right edge).
            row.distribution = .fill
            field.setContentHuggingPriority(.init(1), for: .horizontal)
            for icon in leading {
                icon.setContentHuggingPriority(.required, for: .horizontal)
            }
            row.setHuggingPriority(.defaultLow, for: .horizontal)
            content = row
        } else {
            content = field
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// Shows or hides `cell`'s warning and sizes it at the panel's size, with
    /// `explanation` as what the pointer reads on it.
    ///
    /// Set per row, never once when the cell is made: cells are recycled, and
    /// one that kept its triangle would wear it on a row that is fine.
    public static func setWarning(
        _ shown: Bool, on cell: NSTableCellView, explanation: String? = nil
    ) {
        guard let triangle = cell.imageView else { return }
        // A hidden arranged view is detached from the stack, so a clean row's
        // text starts where it would with no warning at all rather than a
        // triangle's width in.
        triangle.isHidden = !shown
        triangle.symbolConfiguration = .init(
            pointSize: ToolPanelFont.size, weight: .regular
        )
        triangle.toolTip = explanation
    }

    /// The warning a flagged row wears: a red triangle in an image view of its
    /// own.
    ///
    /// A view, not an `NSTextAttachment` inside the text — an attachment is
    /// laid out as a glyph, and a glyph taller than the line makes the field
    /// re-wrap and spill out of its row (measured: the name broke across two
    /// lines and the triangle drew above the text as a red stub).
    ///
    /// The filled octagon: this marks a value that is *wrong* — a checksum that
    /// does not check out — rather than something to look at twice, and the
    /// octagon is the shape the app gives an error. A triangle is left to the
    /// states that are not errors, like a microcode the catalogue has a newer
    /// revision for.
    private static func makeWarning() -> NSImageView {
        let warning = NSImageView()
        let symbol = NSImage(
            systemSymbolName: "exclamationmark.octagon.fill",
            accessibilityDescription: "Invalid"
        )
        symbol?.isTemplate = true
        warning.image = symbol
        warning.contentTintColor = SemanticColors.bad
        warning.imageScaling = .scaleProportionallyUpOrDown
        warning.setContentCompressionResistancePriority(.required, for: .horizontal)
        warning.translatesAutoresizingMaskIntoConstraints = false
        return warning
    }

    /// Draws `cell`'s marker as `symbol` in `tint` — or hides it when `symbol`
    /// is nil — with `toolTip` as what the pointer reads on it.
    ///
    /// The marker is a second, leading icon the FIT Type column uses for a
    /// row's "latest" verdict. It is one per cell — green where the installed
    /// revision is the newest the catalogue lists, orange where the catalogue
    /// has a newer one, and hidden entirely (`.notRated`) where there is no
    /// basis for a verdict. The shared package cannot know what those verdicts
    /// mean, so it takes the glyph the caller chose and says nothing about it.
    ///
    /// Set per row, like `setWarning`; a recycled cell would otherwise wear
    /// whatever row it last dressed. A nil symbol is how a row with no verdict
    /// is dressed, and the colour that was there before does not linger: the
    /// marker comes back hidden and colourless.
    public static func setMarker(
        symbol: String?,
        tint: NSColor? = nil,
        toolTip: String? = nil,
        on cell: NSTableCellView
    ) {
        guard let marker = cell.viewWithTag(markerTag) as? NSImageView else { return }
        guard let symbol, let tint else {
            marker.isHidden = true
            marker.image = nil
            marker.toolTip = nil
            return
        }
        marker.isHidden = false
        marker.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: toolTip
        )
        marker.image?.isTemplate = true
        marker.contentTintColor = tint
        marker.symbolConfiguration = .init(
            pointSize: ToolPanelFont.size, weight: .regular
        )
        marker.toolTip = toolTip
    }

    /// The blank slot the marker is drawn into, hidden until a row earns it.
    /// Tagged so `setMarker` can find it on a cell come back out of the pool.
    private static func makeMarker() -> NSImageView {
        let marker = NSImageView()
        marker.tag = markerTag
        marker.isHidden = true
        marker.imageScaling = .scaleProportionallyUpOrDown
        marker.setContentCompressionResistancePriority(.required, for: .horizontal)
        marker.translatesAutoresizingMaskIntoConstraints = false
        return marker
    }

    /// Draws `table` at the panel's size: the row height, the header's height
    /// and the font its labels are drawn with. Called once the columns exist,
    /// and again whenever the zoom moves.
    ///
    /// A cell's own font is the panel's business — it knows which columns hold
    /// numbers — and this deliberately does not touch it.
    public static func apply(to table: NSTableView) {
        table.rowSizeStyle = .custom
        table.rowHeight = ToolPanelFont.rowHeight

        // The label goes in as an attributed string, not as a font on the
        // header cell: a header cell draws its title with the size the table's
        // style hands it and ignores `font` outright (measured — the labels
        // stayed at 13 while the rows grew to 20).
        let headerFont = ToolPanelFont.body()
        for column in table.tableColumns {
            column.headerCell.font = headerFont
            column.headerCell.attributedStringValue = NSAttributedString(
                string: column.title,
                attributes: [
                    .font: headerFont,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }

        // A table with no header (the FIT panel's problem list) is left with
        // none: a header is a column's label, not a consequence of the size.
        guard table.headerView != nil else { return }
        let header = table.headerView as? HeaderView ?? {
            let replacement = HeaderView()
            table.headerView = replacement
            return replacement
        }()
        header.preferredHeight = ToolPanelFont.headerHeight
    }
}
