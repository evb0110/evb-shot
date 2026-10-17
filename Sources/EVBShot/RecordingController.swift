import AppKit
import AVFoundation

@MainActor
final class RecordingController: NSWindowController, NSWindowDelegate {
    static let frameRates = [15,24,30,60]
    var selectedFrameRate:Int { Self.frameRates[fps.indexOfSelectedItem] }
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
    var hasActiveWork:Bool { preparing || finishing || session != nil }

    init(display: CGDirectDisplayID) {
        source = .display(display, nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 330), styleMask: [.titled, .closable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "Record with EVBShot"; window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        super.init(window: window); window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top:20,left:20,bottom:20,right:20)
        sourceLabel.font = .systemFont(ofSize:12,weight:.semibold)
        let sourceIcon = NSImageView(image:NSImage(systemSymbolName:"display",accessibilityDescription:nil)!)
        stack.addArrangedSubview(NSStackView(views:[sourceIcon,sourceLabel]))
        let full = NSButton(title: "Full Screen", target: self, action: #selector(fullScreen))
        let area = NSButton(title: "Select Area…", target: self, action: #selector(selectArea))
        let windowButton = NSButton(title: "Choose Window…", target: self, action: #selector(selectWindow))
        for button in [full,area,windowButton] { button.bezelStyle = .texturedRounded }
        let sourceButtons = NSStackView(views:[full,area,windowButton]); sourceButtons.distribution = .fillEqually
        sourceButtons.widthAnchor.constraint(equalToConstant:480).isActive = true
        stack.addArrangedSubview(sourceButtons)
        resolution.addItems(withTitles: ["Native resolution", "50% resolution", "Fit within 1920 × 1080"])
        resolution.setAccessibilityLabel("Recording resolution")
        fps.addItems(withTitles:Self.frameRates.map { "\($0) FPS" }); fps.selectItem(at:Self.frameRates.firstIndex(of:30)!)
        fps.setAccessibilityLabel("Recording FPS")
        let quality = NSStackView(views:[resolution,fps]); quality.spacing = 12
        resolution.setContentHuggingPriority(.defaultLow,for:.horizontal)
        quality.widthAnchor.constraint(equalToConstant:452).isActive = true
        camera.target = self; camera.action = #selector(updateOptions)
        microphone.target = self; microphone.action = #selector(updateOptions)
        systemAudio.target = self; systemAudio.action = #selector(updateOptions)
        audioOnly.target = self; audioOnly.action = #selector(updateOptions)
        corner.addItems(withTitles: CameraCorner.allCases.map(\.rawValue))
        cameraDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        devices.addItems(withTitles: cameraDevices.map(\.localizedName))
        if cameraDevices.isEmpty { devices.addItem(withTitle: "No camera connected"); camera.isEnabled = false }
        devices.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        devices.widthAnchor.constraint(lessThanOrEqualToConstant:200).isActive = true
        corner.setAccessibilityLabel("Selfie position")
        let settings = NSStackView(); settings.orientation = .vertical; settings.alignment = .leading; settings.spacing = 14
        settings.addArrangedSubview(quality)
        settings.addArrangedSubview(NSStackView(views:[microphone,systemAudio,audioOnly]))
        settings.addArrangedSubview(NSStackView(views:[camera,devices,corner]))
        let card = NSBox(); card.boxType = .custom; card.cornerRadius = 10
        card.borderWidth = 1; card.borderColor = .separatorColor; card.fillColor = .controlBackgroundColor
        card.contentViewMargins = NSSize(width:14,height:14); card.contentView = settings
        card.widthAnchor.constraint(equalToConstant:480).isActive = true
        card.heightAnchor.constraint(equalToConstant:134).isActive = true
        stack.addArrangedSubview(card)
        status.preferredMaxLayoutWidth = 480; status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize:11)
        status.widthAnchor.constraint(equalToConstant:480).isActive = true
        stack.addArrangedSubview(status)
        startButton.target = self; startButton.action = #selector(startOrStop)
        startButton.bezelStyle = .rounded; startButton.bezelColor = .controlAccentColor
        let spacer = NSView(), buttons = NSStackView(views:[spacer,startButton]); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        buttons.widthAnchor.constraint(equalToConstant:480).isActive = true
        stack.addArrangedSubview(buttons)
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
        if !hasActiveWork {
            var sources:[String] = []
            if microphone.state == .on { sources.append("microphone") }
            if systemAudio.state == .on { sources.append("computer audio") }
            if !isAudio && camera.state == .on { sources.append("selfie camera") }
            status.stringValue = sources.isEmpty ? "Audio and camera are off. Choose the sources you want to include." : "Included: " + sources.joined(separator:", ") + "."
        }
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
                options.fps = selectedFrameRate
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
