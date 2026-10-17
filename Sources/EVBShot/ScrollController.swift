import AppKit

@MainActor
final class ScrollController: NSWindowController {
    private let source: CaptureSource
    private let spool: LongCapture
    private let onFinish: (CaptureArtifact) -> Void
    private let dimensions = NSTextField(labelWithString: "Preparing native pixels…")
    private let status = NSTextField(wrappingLabelWithString: "Scroll downward slowly. Keep fixed headers and scrollbars outside the selected area.")
    private let toggle = NSButton(title: "Pause", target: nil, action: nil)
    private let finishButton = NSButton(title: "Finish & Save…", target: nil, action: nil)
    private var sampling: Task<Void, Never>?
    private var paused = false
    private var finishing = false
    private var preview: NSImage?
    var onCancel: (() -> Void)?

    init(source: CaptureSource, spool: LongCapture, onFinish: @escaping (CaptureArtifact) -> Void) {
        self.source = source; self.spool = spool; self.onFinish = onFinish
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Scrolling Capture"; window.level = .floating; window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
        status.preferredMaxLayoutWidth = 375; status.textColor = .secondaryLabelColor
        toggle.target = self; toggle.action = #selector(togglePause)
        finishButton.target = self; finishButton.action = #selector(finish)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        for view in [dimensions, status, NSStackView(views: [toggle, finishButton, cancel])] { stack.addArrangedSubview(view) }
        stack.wantsLayer = true; stack.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = stack; window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func start() {
        showWindow(nil)
        sampling = Task { [weak self] in
            // Discover the content after this panel exists so our whole app,
            // including this panel, is excluded from subsequent screenshots.
            var surface: CaptureSurface?
            while !Task.isCancelled {
                guard let self, !self.finishing else { return }
                if !self.paused {
                    do {
                        if surface == nil { surface = try await CaptureEngine.surface(for: self.source) }
                        guard let surface else { return }
                        guard surface.height >= 48 else { throw ShotError("Choose a scrolling area at least 48 native pixels tall.") }
                        let image = try await CaptureEngine.image(surface)
                        if Task.isCancelled { return }
                        if self.preview == nil { self.preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
                        let frame = try await Task.detached(priority: .userInitiated) { try PixelFrame(image: image) }.value
                        _ = try await self.spool.append(frame)
                        let size = await self.spool.dimensions()
                        self.dimensions.stringValue = "\(size.0.formatted()) × \(size.1.formatted()) pixels"
                        self.status.stringValue = "Capturing at native resolution. Scroll downward, keeping some overlap visible."
                    } catch {
                        self.paused = true; self.toggle.title = "Resume"
                        self.status.stringValue = error.localizedDescription
                    }
                }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
        }
    }
    @objc private func togglePause() { paused.toggle(); toggle.title = paused ? "Resume" : "Pause" }
    @objc private func finish() {
        guard !finishing else { return }
        finishing = true; sampling?.cancel()
        toggle.isEnabled = false; finishButton.isEnabled = false
        status.stringValue = "Writing the full-resolution PNG. Original pixels are streamed from disk…"
        Task {
            await sampling?.value
            do {
                let size = await spool.dimensions()
                let url = try await spool.finish()
                close()
                onFinish(CaptureArtifact(url: url, kind: .image, width: size.0, height: size.1, hasAudio: false, preview: preview))
            } catch {
                finishing = false; paused = true; toggle.title = "Resume"
                toggle.isEnabled = true; finishButton.isEnabled = true
                status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func cancel() {
        guard !finishing else { return }
        let alert = NSAlert(); alert.messageText = "Discard this scrolling capture?"
        alert.informativeText = "The captured pixels will be removed."
        alert.addButton(withTitle: "Keep Capturing"); alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertSecondButtonReturn {
            finishing = true
            sampling?.cancel()
            Task { await sampling?.value; try? FileManager.default.removeItem(at: spool.folder); close(); onCancel?() }
        }
    }
}
