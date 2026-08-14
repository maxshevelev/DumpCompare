import Cocoa

final class MainViewController: NSViewController {
    private(set) var mode: WindowMode = .empty

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        apply(mode: .empty)
    }

    /// Swaps the content area for the given window mode (§3 of REQUIREMENTS.md).
    func apply(mode: WindowMode) {
        self.mode = mode
        switch mode {
        case .empty:
            setContentView(EmptyStateView())
        case .singleFile, .comparison:
            // Implemented in Milestones 4–5 (see IMPLEMENTATION_PLAN.md).
            let placeholder = NSTextField(labelWithString: "\(mode) mode — arriving in a later milestone")
            placeholder.textColor = .secondaryLabelColor
            placeholder.alignment = .center
            setContentView(placeholder)
        }
    }

    private func setContentView(_ newView: NSView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        newView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newView)
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: view.topAnchor),
            newView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            newView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// File > Open… (§4.1). The panel is live; document loading lands in Milestone 4.
    @objc func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            // TODO(Milestone 4): load documents per the §4.1 placement rules.
            print("Open panel selected: \(panel.urls)")
        }
    }
}
