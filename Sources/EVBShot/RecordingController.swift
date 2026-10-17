import AppKit
import AVFoundation

@MainActor
final class RecordingController: NSWindowController, NSWindowDelegate {
    private var source: CaptureSource
    private var picker: WindowPicker?
    private let selector = AreaSelector()
    private let sourceLabel = NSTextField(labelWithString: "Full screen")
    private let resolution = NSPopUpButton()
    private let fps = NSPopUpButton()
    private let microphone = NSButton(checkboxWithTitle: "Microphone", target: nil, action: nil)
    private let systemAudio = NSButton(checkboxWithTitle: "Computer audio", target: nil, action: nil)
    private let camera = NSButton(checkboxWithTitle: "Selfie camera", target: nil, action: nil)
    private let devices = NSPopUpButton()
    private let corner = NSPopUpButton()
    private let audioOnly = NSButton(checkboxWithTitle: "Record audio only", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Audio and camera are off. Choose the sources you want to include.")
    private let startButton = NSButton(title: "Start Recording", target: nil, action: nil)
    private var configurationViews: [NSControl] = []
    private var cameraDevices: [AVCaptureDevice] = []
    private var session: RecordingSession?
    private var preparing = false
    private var finishing = false
    private var timer: Timer?
    private var startedAt: Date?
    var onFinish: ((CaptureArtifact) -> Void)?
    var onClose: (() -> Void)?
    var onState: ((Bool) -> Void)?
    var isRecording: Bool { session != nil }

    init(display: CGDirectDisplayID) {
        source = .display(display, nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Record with EVBShot"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let heading = NSTextField(labelWithString: "Screen recording"); heading.font = .systemFont(ofSize: 23, weight: .bold)
        stack.addArrangedSubview(heading)
        sourceLabel.font = .systemFont(ofSize: 13, weight: .semibold); stack.addArrangedSubview(sourceLabel)
        let full = NSButton(title: "Full Screen", target: self, action: #selector(fullScreen))
        let area = NSButton(title: "Select Area…", target: self, action: #selector(selectArea))
        let windowButton = NSButton(title: "Choose Window…", target: self, action: #selector(selectWindow))
        stack.addArrangedSubview(NSStackView(views: [full, area, windowButton]))
        resolution.addItems(withTitles: ["Native resolution", "50% resolution", "Fit within 1920 × 1080"])
        fps.addItems(withTitles: ["15 FPS", "30 FPS", "60 FPS"]); fps.selectItem(at: 1)
        stack.addArrangedSubview(NSStackView(views: [resolution, fps]))
        stack.addArrangedSubview(NSStackView(views: [microphone, systemAudio]))
        camera.target = self; camera.action = #selector(updateOptions)
        audioOnly.target = self; audioOnly.action = #selector(updateOptions)
        corner.addItems(withTitles: CameraCorner.allCases.map(\.rawValue))
        cameraDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        devices.addItems(withTitles: cameraDevices.map(\.localizedName))
        if cameraDevices.isEmpty { devices.addItem(withTitle: "No camera connected"); camera.isEnabled = false }
        stack.addArrangedSubview(NSStackView(views: [camera, devices]))
        stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Selfie position"), corner, audioOnly]))
        status.preferredMaxLayoutWidth = 470; status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(status)
        startButton.target = self; startButton.action = #selector(startOrStop)
        startButton.bezelStyle = .rounded
        stack.addArrangedSubview(startButton)
        configurationViews = [full, area, windowButton, resolution, fps, microphone, systemAudio, camera, devices, corner, audioOnly]
        stack.wantsLayer = true; stack.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = stack; window.center(); updateOptions()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func updateOptions() {
        let isAudio = audioOnly.state == .on
        resolution.isEnabled = !isAudio; fps.isEnabled = !isAudio
        camera.isEnabled = !isAudio && !cameraDevices.isEmpty
        devices.isEnabled = !isAudio && camera.state == .on
        corner.isEnabled = devices.isEnabled
    }
    @objc private func fullScreen() { source = .display(NSScreen.underPointer.displayID, nil); sourceLabel.stringValue = "Full screen" }
    @objc private func selectArea() {
        window?.orderOut(nil)
        selector.select { [weak self] source in
            guard let self else { return }
            if let source { self.source = source; self.sourceLabel.stringValue = "Selected area" }
            self.showWindow(nil)
        }
    }
    @objc private func selectWindow() {
        Task { [self] in
            do {
                picker = WindowPicker(content: try await CaptureEngine.content()) { [weak self] source in
                    guard let self else { return }
                    if let source { self.source = source; self.sourceLabel.stringValue = "Selected window" }
                    self.picker = nil
                }
                picker?.showWindow(nil)
            } catch { presentError(error) }
        }
    }
    @objc private func startOrStop() {
        if session != nil { stop(); return }
        guard !preparing else { return }
        preparing = true; startButton.isEnabled = false
        configurationViews.forEach { $0.isEnabled = false }
        status.stringValue = "Preparing capture. macOS may request screen, microphone, or camera access…"
        Task { [self] in
            do {
                let surface = try await CaptureEngine.surface(for: source)
                var options = RecordingOptions()
                options.fps = [15, 30, 60][fps.indexOfSelectedItem]
                options.scale = resolution.indexOfSelectedItem == 1 ? 0.5 : resolution.indexOfSelectedItem == 2 ? min(1, min(1920 / Double(surface.width), 1080 / Double(surface.height))) : 1
                options.microphone = microphone.state == .on; options.systemAudio = systemAudio.state == .on
                options.audioOnly = audioOnly.state == .on
                if !options.audioOnly, camera.state == .on, cameraDevices.indices.contains(devices.indexOfSelectedItem) { options.camera = cameraDevices[devices.indexOfSelectedItem] }
                options.corner = CameraCorner.allCases[corner.indexOfSelectedItem]
                let recording = RecordingSession()
                recording.onFailure = { [weak self] error in
                    guard let self, !self.finishing else { return }
                    self.status.stringValue = "Capture stopped: \(error.localizedDescription). Finalizing the available media…"
                    self.stop()
                }
                // Keep the session before start so failure callbacks refer to this recording.
                session = recording
                try await recording.start(surface: surface, options: options)
                startedAt = Date(); onState?(true)
                startButton.title = "Stop & Review"; startButton.isEnabled = true
                status.stringValue = "Recording · 00:00 · \(options.fps) FPS"
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let start = self.startedAt, !self.finishing else { return }
                        let elapsed = Int(Date().timeIntervalSince(start))
                        self.status.stringValue = String(format: "Recording · %02d:%02d · %d FPS", elapsed / 60, elapsed % 60, options.fps)
                    }
                }
            } catch {
                session = nil; status.stringValue = error.localizedDescription
                configurationViews.forEach { $0.isEnabled = true }; updateOptions()
                startButton.isEnabled = true
            }
            preparing = false
        }
    }
    func stop() {
        guard let session, !finishing, !preparing else { return }
        finishing = true; timer?.invalidate(); timer = nil
        startButton.isEnabled = false; status.stringValue = "Finishing recording and mixing the selected audio sources…"
        Task { [self] in
            do {
                let artifact = try await session.stop()
                self.session = nil; onState?(false); close(); onFinish?(artifact)
            } catch {
                self.session = nil; onState?(false)
                status.stringValue = error.localizedDescription
                startButton.title = "Start Recording"; startButton.isEnabled = true
                configurationViews.forEach { $0.isEnabled = true }; updateOptions()
            }
            finishing = false
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !preparing && session == nil }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); onClose?() }
}
