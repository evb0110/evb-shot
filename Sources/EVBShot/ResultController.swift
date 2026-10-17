import AppKit
import AVKit
import UniformTypeIdentifiers

// Captured pixel dimensions describe the file, not the size of its preview UI.
private final class CapturePreviewView: NSImageView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

@MainActor
final class ResultController: NSWindowController, NSWindowDelegate {
    let artifact: CaptureArtifact
    private let audio = NSButton(checkboxWithTitle: "Include recorded audio", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Your capture is ready. Save it and paste its full path directly into a thread.")
    private let savePath = NSButton(title: "Save & Copy File Path…", target: nil, action: nil)
    private let save = NSButton(title: "Save…", target: nil, action: nil)
    private var player: AVPlayer?
    var onClose: (() -> Void)?

    init(_ artifact: CaptureArtifact) {
        self.artifact = artifact
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 510), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Capture Ready"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        if let notice = artifact.notice { status.stringValue = notice }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        let heading = NSTextField(labelWithString: artifact.detail); heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(heading)
        let preview: NSView
        if artifact.kind == .image {
            let image = CapturePreviewView(); image.image = artifact.preview; image.imageScaling = .scaleProportionallyUpOrDown
            preview = image
        } else {
            let view = AVPlayerView(); let player = AVPlayer(url: artifact.url)
            self.player = player; view.player = player; view.controlsStyle = .inline
            preview = view
        }
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(preview)
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let preferredHeight = preview.heightAnchor.constraint(equalToConstant: 250)
        preferredHeight.priority = .defaultLow; preferredHeight.isActive = true
        preview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        if artifact.kind == .image, CGFloat(artifact.height) > (artifact.preview?.size.height ?? 0) + 1 {
            let note = NSTextField(wrappingLabelWithString: "Preview shows the first viewport. The saved PNG contains the full image.")
            note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
        }
        if artifact.kind == .video && artifact.hasAudio {
            audio.state = .on; stack.addArrangedSubview(audio)
        }
        status.textColor = .secondaryLabelColor; status.preferredMaxLayoutWidth = 600; stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
        heading.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
        savePath.target = self; savePath.action = #selector(saveAndCopy)
        save.target = self; save.action = #selector(saveOnly)
        let reveal = NSButton(title: "Show Draft", target: self, action: #selector(revealDraft))
        stack.addArrangedSubview(NSStackView(views: [savePath, save, reveal]))
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 660, height: 510))
        content.wantsLayer = true; content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        let available = NSScreen.underPointer.visibleFrame.insetBy(dx: 16, dy: 16)
        let maximum = window.contentRect(forFrameRect: available).size
        // NSWindow minSize/maxSize are ignored under Auto Layout. Bound the
        // content itself so neither images nor labels can expand it across screens.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: min(580, maximum.width)),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: min(760, maximum.width)),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: min(420, maximum.height)),
            content.heightAnchor.constraint(lessThanOrEqualToConstant: min(600, maximum.height))
        ])
        window.contentView = content
        window.setContentSize(NSSize(width: min(660, maximum.width), height: min(510, maximum.height)))
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: available.midX - size.width / 2, y: available.midY - size.height / 2))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { player?.pause(); player = nil; onClose?() }
    @objc private func saveAndCopy() { chooseDestination(copy: true) }
    @objc private func saveOnly() { chooseDestination(copy: false) }
    @objc private func revealDraft() { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) }
    private func chooseDestination(copy: Bool) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CaptureFiles.suggestedName(artifact.kind)
        panel.allowedContentTypes = [artifact.kind == .image ? .png : artifact.kind == .video ? .quickTimeMovie : .mpeg4Audio]
        panel.canCreateDirectories = true
        panel.directoryURL = UserDefaults.standard.url(forKey: "saveFolder") ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            self.savePath.isEnabled = false; self.save.isEnabled = false
            self.status.stringValue = "Saving…"
            let includeAudio = self.artifact.kind != .video || !self.artifact.hasAudio || self.audio.state == .on
            Task {
                do {
                    let source = self.artifact.kind == .image ? self.artifact.url : try await MediaExport.normalized(self.artifact.url, includeAudio: includeAudio)
                    try await saveCaptureFile(from: source, to: destination, copyFilePath: copy)
                    if source != self.artifact.url { try? FileManager.default.removeItem(at: source) }
                    UserDefaults.standard.set(destination.deletingLastPathComponent(), forKey: "saveFolder")
                    self.status.stringValue = copy ? "Saved. Full file path copied to the clipboard." : "Saved to \(destination.path)"
                } catch { self.status.stringValue = error.localizedDescription }
                self.savePath.isEnabled = true; self.save.isEnabled = true
            }
        }
    }
}
