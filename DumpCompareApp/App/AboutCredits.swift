import AppKit

/// The paragraph under the standard About panel that says where the names
/// DumpCompare shows come from — which open-source projects contributed data,
/// and who makes them.
///
/// Handed to `NSApplication.orderFrontStandardAboutPanelWithOptions` as an
/// attributed string rather than shipped as a static `Credits.rtf`: the panel
/// renders a file with whatever colour the document was saved in, which is
/// unreadable in one of the app's two themes, whereas text built from the
/// system's semantic colours follows the theme it is shown in.
enum AboutCredits {
    /// One project whose data the app ships or fetches.
    private struct Project {
        let name: String
        let author: String
        let repository: URL
        let profile: URL
        /// What the app actually takes from the project.
        let taken: String
    }

    private static let projects: [Project] = [
        Project(
            name: "UEFITool",
            author: "LongSoft",
            repository: URL(string: "https://github.com/LongSoft/UEFITool")!,
            profile: URL(string: "https://github.com/LongSoft")!,
            taken: "The UEFI Structure tool's item types, NVRAM GUID constants"
                + " and GUID-name catalogue (common/guids.csv)."
        ),
        Project(
            name: "CPUMicrocodes",
            author: "platomav",
            repository: URL(string: "https://github.com/platomav/CPUMicrocodes")!,
            profile: URL(string: "https://github.com/platomav")!,
            taken: "The catalogue of CPU microcodes the FIT tool's picker offers."
        ),
    ]

    /// The credits the About panel shows, centred, one short block per project.
    static func text() -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let lead = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)

        let out = NSMutableAttributedString()

        func plain(_ string: String, font: NSFont = body,
                   colour: NSColor = .labelColor) {
            out.append(NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: colour,
            ]))
        }
        func link(_ string: String, to url: URL, font: NSFont = body) {
            out.append(NSAttributedString(string: string, attributes: [
                .font: font, .link: url, .foregroundColor: NSColor.linkColor,
            ]))
        }

        plain("Data sources\n", font: lead)
        for project in projects {
            // The name opens the repository; the author's name opens their
            // profile; the bare address below is the same link made copyable.
            link(project.name, to: project.repository, font: lead)
            plain(" by ")
            link(project.author, to: project.profile)
            plain("\n")
            plain(project.taken + "\n", colour: .secondaryLabelColor)
            link(project.repository.host! + project.repository.path, to: project.repository)
            plain("\n\n")
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        out.addAttribute(.paragraphStyle, value: style,
                         range: NSRange(location: 0, length: out.length))
        return out
    }
}
