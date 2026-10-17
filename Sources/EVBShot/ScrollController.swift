import AppKit

@MainActor
final class ScrollController: NSWindowController {
    private let source: CaptureSource
    private let spool: LongCapture
    private let onFinish: (CaptureArtifact) -> Void
    private let dimensions = NSTextField(labelWithString: "Preparing native pixels…")
    private let status = NSTextField(wrappingLabelWithString: "Scroll the selected content downward. Keep some overlap visible.")
    private let toggle = NSButton(title: "Pause", target: nil, action: nil)
    private let finishButton = NSButton(title: "Finish & Save…", target: nil, action: nil)
    private var sampling: Task<Void, Never>?
    private var feed: ScrollFrameFeed?
    private var paused = false
    var isPaused:Bool { paused }
    private var finishing = false
    private var preview: NSImage?
    var onCancel: (() -> Void)?

    init(source: CaptureSource, spool: LongCapture, onFinish: @escaping (CaptureArtifact) -> Void) {
        self.source = source; self.spool = spool; self.onFinish = onFinish
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 370, height: 142), styleMask: [.titled,.nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Scrolling Capture"; window.level = .floating; window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false; window.becomesKeyOnlyIfNeeded = true
        super.init(window: window)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top:14,left:16,bottom:14,right:16)
        dimensions.font = .monospacedDigitSystemFont(ofSize:14,weight:.semibold)
        status.preferredMaxLayoutWidth = 338; status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor
        toggle.target = self; toggle.action = #selector(togglePause)
        finishButton.target = self; finishButton.action = #selector(finish)
        finishButton.bezelStyle = .rounded; finishButton.bezelColor = .controlAccentColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        for view in [dimensions, status, NSStackView(views: [toggle, finishButton, cancel])] { stack.addArrangedSubview(view) }
        stack.wantsLayer = true; stack.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = stack
        let screen = NSScreen.underPointer, bounds = screen.visibleFrame.insetBy(dx:16,dy:16)
        var position = CGPoint(x:bounds.maxX-window.frame.width,y:bounds.minY)
        if case let .display(id,selection?) = source, let display = NSScreen.screens.first(where: { $0.displayID == id }) {
            let region = CGRect(x:display.frame.minX+selection.minX,y:display.frame.maxY-selection.maxY,width:selection.width,height:selection.height)
            if region.minY-window.frame.height-12 >= bounds.minY { position = CGPoint(x:max(bounds.minX,min(bounds.maxX-window.frame.width,region.minX)),y:region.minY-window.frame.height-12) }
            else if region.maxY+window.frame.height+12 <= bounds.maxY { position = CGPoint(x:max(bounds.minX,min(bounds.maxX-window.frame.width,region.minX)),y:region.maxY+12) }
            else if region.maxX+window.frame.width+12 <= bounds.maxX { position = CGPoint(x:region.maxX+12,y:bounds.maxY-window.frame.height) }
        }
        window.setFrameOrigin(position)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func start() {
        showWindow(nil)
        sampling = Task { [weak self] in
            guard let self else { return }
            do {
                let surface = try await CaptureEngine.surface(for:self.source)
                guard surface.height >= 48 else { throw ShotError("Choose a scrolling area at least 48 native pixels tall.") }
                let feed = ScrollFrameFeed(onFrame:{ [weak self] image in await self?.receive(image) },onError:{ [weak self] error in await self?.streamFailed(error) })
                self.feed = feed; try await feed.start(surface)
            } catch { await feed?.stop(); feed = nil; captureFailed(error) }
        }
    }
    func receive(_ image:CGImage) async {
        guard !paused, !finishing else { return }
        do {
            if preview == nil { preview = NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height)) }
            let frame = try await Task.detached(priority:.userInitiated) { try PixelFrame(image:image) }.value
            _ = try await spool.append(frame)
            let size = await spool.dimensions()
            dimensions.stringValue = "\(size.0.formatted()) × \(size.1.formatted()) pixels"
            status.stringValue = "Capturing at full resolution. Scroll downward to add content."
        } catch let error as ScrollAlignmentError {
            // Animation and intermediate scroll frames are not committed. The next
            // matching frame continues from the last good native viewport.
            status.stringValue = error.localizedDescription
        } catch { captureFailed(error) }
    }
    private func captureFailed(_ error:Error) { paused = true; toggle.title = "Resume"; status.stringValue = error.localizedDescription }
    private func streamFailed(_ error:Error) { captureFailed(error); toggle.isEnabled = false }
    @objc private func togglePause() {
        paused.toggle(); toggle.title = paused ? "Resume" : "Pause"
        if !paused, feed == nil { start() }
    }
    @objc private func finish() {
        guard !finishing else { return }
        finishing = true; sampling?.cancel()
        toggle.isEnabled = false; finishButton.isEnabled = false
        status.stringValue = "Writing the full-resolution PNG. Original pixels are streamed from disk…"
        Task {
            await sampling?.value
            await feed?.stop(); feed = nil
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
            Task { await sampling?.value; await feed?.stop(); feed = nil; try? FileManager.default.removeItem(at: spool.folder); close(); onCancel?() }
        }
    }
}
