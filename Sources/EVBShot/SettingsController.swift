import AppKit

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate {
    private let settings: CaptureSaveSettings
    private let path = NSPathControl()
    private let updates: AppUpdates?
    var onClose: (() -> Void)?

    init(settings: CaptureSaveSettings = CaptureSaveSettings(), updates: AppUpdates? = nil) {
        self.settings = settings
        self.updates = updates
        let height:CGFloat = updates == nil ? 190 : 280
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: height),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Settings"; window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        super.init(window: window); window.delegate = self
        let title = NSTextField(labelWithString: "Save location")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let detail = NSTextField(labelWithString: "Screenshots, videos, and audio save here immediately.")
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        refreshPath(); path.isEditable = false
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setAccessibilityLabel("Capture save folder")
        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        let reset = NSButton(title: "Use Default Folder", target: self, action: #selector(resetFolder))
        reset.bezelStyle = .rounded
        let buttons = NSStackView(views: [choose, reset]); buttons.spacing = 8
        let stack = NSStackView(views: [title, detail, path, buttons])
        if let updates {
            let separator = NSBox(); separator.boxType = .separator
            let automatic = NSButton(checkboxWithTitle:"Automatically check for updates",target:self,action:#selector(changeAutomaticChecks))
            automatic.state = updates.automaticallyChecks ? .on : .off
            let check = NSButton(title:"Check for Updates…",target:updates,action:#selector(AppUpdates.checkForUpdates(_:)))
            check.bezelStyle = .rounded
            let row = NSStackView(views:[automatic,check]); row.spacing = 12
            stack.addArrangedSubview(separator); stack.addArrangedSubview(row)
        }
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            path.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.widthAnchor.constraint(equalToConstant: 480),
            content.heightAnchor.constraint(equalToConstant: height)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSaveFolder(_ url: URL) {
        settings.folder = url; refreshPath()
    }
    private func refreshPath() {
        path.url = settings.folder
        if !FileManager.default.fileExists(atPath: settings.folder.path) {
            path.pathItems.last?.image = NSImage(named: NSImage.folderName)
        }
    }
    @objc private func changeAutomaticChecks(_ sender:NSButton) { updates?.automaticallyChecks = sender.state == .on }
    @objc private func resetFolder() { setSaveFolder(CaptureSaveSettings.defaultFolder) }
    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"; panel.directoryURL = settings.folder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setSaveFolder(url)
        }
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
