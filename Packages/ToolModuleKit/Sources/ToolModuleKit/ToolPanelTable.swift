import AppKit

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
