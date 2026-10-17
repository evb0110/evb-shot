import AppKit
import AVFoundation

@MainActor
final class RecordingController: NSWindowController, NSWindowDelegate {
    enum Phase { case configuring, selecting, preparing, recording, finishing, closed }
    static let frameRates = [15,24,30,60]
    private(set) var phase:Phase = .configuring
    var selectedFrameRate:Int { Self.frameRates[fps.indexOfSelectedItem] }
    var selectedSourceIndex:Int { sourceMode.selectedSegment }
    private(set) var source:CaptureSource
    private var picker:WindowPicker?
    private let selector = AreaSelector()
    private let sourceMode = NSSegmentedControl(labels:["Screen","Area","Window"],trackingMode:.selectOne,target:nil,action:nil)
    private let sourceLabel = NSTextField(labelWithString:"Full screen")
    private let resolution = NSPopUpButton()
    private let fps = NSPopUpButton()
    private let microphone = NSButton(checkboxWithTitle:"Microphone",target:nil,action:nil)
    private let systemAudio = NSButton(checkboxWithTitle:"Computer audio",target:nil,action:nil)
    private let camera = NSButton(checkboxWithTitle:"Selfie camera",target:nil,action:nil)
    private let devices = NSPopUpButton()
    private let corner = NSPopUpButton()
    private let audioOnly = NSButton(checkboxWithTitle:"Audio only",target:nil,action:nil)
    private let status = NSTextField(wrappingLabelWithString:"Audio and camera are off.")
    private let startButton = NSButton(title:"Start Recording",target:nil,action:nil)
    private let cancelButton = NSButton(title:"Cancel",target:nil,action:nil)
    private let cameraRow = NSStackView()
    private var configurationViews:[NSControl] = []
    private var cameraDevices:[AVCaptureDevice] = []
    private var session:RecordingSession?
    private var timer:Timer?
    private var startedAt:Date?
    private var selectionBounds:CGRect?
    private var regionOutline:NSPanel?
    private var pendingFailure:Error?
    private var initialSelection = false
    var onFinish:((CaptureArtifact)->Void)?
    var onClose:(()->Void)?
    var onState:((Bool)->Void)?
    var onElapsed:((String)->Void)?
    var isRecording:Bool { phase == .recording }
    var hasActiveWork:Bool { phase == .preparing || phase == .recording || phase == .finishing }

    init(display:CGDirectDisplayID) {
        source = .display(display,nil)
        let panel = NSPanel(contentRect:CGRect(x:0,y:0,width:520,height:190),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title = "Record with EVB Shot"; panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        super.init(window:panel); panel.delegate = self
        let material = NSVisualEffectView(); material.material = .popover; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 12; material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1; material.layer?.borderColor = NSColor.separatorColor.cgColor
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo:material.leadingAnchor,constant:16),
            stack.trailingAnchor.constraint(equalTo:material.trailingAnchor,constant:-16),
            stack.topAnchor.constraint(equalTo:material.topAnchor,constant:14),
            stack.bottomAnchor.constraint(equalTo:material.bottomAnchor,constant:-14),
            stack.widthAnchor.constraint(equalToConstant:488)
        ])
        sourceMode.target = self; sourceMode.action = #selector(changeSource)
        sourceMode.segmentStyle = .rounded; sourceMode.selectedSegment = 0
        sourceMode.setAccessibilityLabel("Recording source")
        for (index,symbol) in ["display","viewfinder","macwindow"].enumerated() {
            sourceMode.setImage(NSImage(systemSymbolName:symbol,accessibilityDescription:nil),forSegment:index)
            sourceMode.setWidth(83,forSegment:index)
        }
        sourceLabel.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular)
        sourceLabel.textColor = .secondaryLabelColor; sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let header = NSStackView(views:[sourceMode,sourceLabel]); header.spacing = 12
        header.widthAnchor.constraint(equalToConstant:488).isActive = true
        stack.addArrangedSubview(header)
        resolution.addItems(withTitles:["Native resolution","50% resolution","Fit within 1920 × 1080"])
        resolution.setAccessibilityLabel("Recording resolution")
        fps.addItems(withTitles:Self.frameRates.map { "\($0) FPS" }); fps.selectItem(at:2)
        fps.setAccessibilityLabel("Recording FPS")
        let quality = NSStackView(views:[resolution,fps,audioOnly]); quality.spacing = 10
        quality.widthAnchor.constraint(equalToConstant:488).isActive = true
        resolution.setContentHuggingPriority(.defaultLow,for:.horizontal)
        stack.addArrangedSubview(quality)
        for control in [camera,microphone,systemAudio,audioOnly] { control.target = self; control.action = #selector(updateOptions) }
        let inputs = NSStackView(views:[microphone,systemAudio,camera]); inputs.spacing = 18
        stack.addArrangedSubview(inputs)
        corner.addItems(withTitles:CameraCorner.allCases.map(\.rawValue)); corner.setAccessibilityLabel("Selfie position")
        cameraDevices = AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.external,.continuityCamera],mediaType:.video,position:.unspecified).devices
        devices.addItems(withTitles:cameraDevices.map(\.localizedName))
        if cameraDevices.isEmpty { devices.addItem(withTitle:"No camera connected") }
        devices.setAccessibilityLabel("Selfie camera device")
        devices.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        cameraRow.addArrangedSubview(devices); cameraRow.addArrangedSubview(corner); cameraRow.spacing = 10
        cameraRow.widthAnchor.constraint(equalToConstant:488).isActive = true
        stack.addArrangedSubview(cameraRow)
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize:11)
        status.preferredMaxLayoutWidth = 250
        status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        startButton.target = self; startButton.action = #selector(startRecording)
        startButton.bezelStyle = .rounded; startButton.bezelColor = .controlAccentColor
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        let actions = NSStackView(views:[status,cancelButton,startButton]); actions.spacing = 10
        actions.widthAnchor.constraint(equalToConstant:488).isActive = true
        status.setContentHuggingPriority(.defaultLow,for:.horizontal)
        stack.addArrangedSubview(actions)
        configurationViews = [sourceMode,resolution,fps,microphone,systemAudio,camera,devices,corner,audioOnly]
        panel.contentView = material
        updateOptions(); placeControls()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender:Any?) {
        guard phase == .configuring else { return }
        super.showWindow(sender)
    }

    @objc private func updateOptions() {
        let isAudio = audioOnly.state == .on
        resolution.isEnabled = !isAudio; fps.isEnabled = !isAudio
        sourceMode.isEnabled = !isAudio
        camera.isEnabled = !isAudio && !cameraDevices.isEmpty
        devices.isEnabled = !isAudio && camera.state == .on; corner.isEnabled = devices.isEnabled
        cameraRow.isHidden = !devices.isEnabled
        if !hasActiveWork {
            var sources:[String] = []
            if microphone.state == .on { sources.append("mic") }
            if systemAudio.state == .on { sources.append("computer audio") }
            if !isAudio && camera.state == .on { sources.append("camera") }
            status.stringValue = sources.isEmpty ? (isAudio ? "Choose an audio source." : "Audio and camera are off.") : sources.joined(separator:" + ")
            startButton.isEnabled = !isAudio || microphone.state == .on || systemAudio.state == .on
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        if let size = window?.contentView?.fittingSize { window?.setContentSize(size) }
    }
    // Enter capture selection directly from the menu, rather than opening a settings dialog first.
    func beginSelection() { initialSelection = true; selectArea() }
    @objc private func changeSource() {
        switch sourceMode.selectedSegment {
        case 0: acceptSelection(.display(NSScreen.underPointer.displayID,nil))
        case 1: selectArea()
        case 2: selectWindow()
        default: break
        }
    }
    private func sourceIndex(_ source:CaptureSource) -> Int {
        switch source { case .window: return 2; case .display(_,nil): return 0; case .display: return 1 }
    }
    // Both picker completions use this path. Cancellation retains the previous source and its highlight.
    func acceptSelection(_ selected:CaptureSource?, present:Bool = true) {
        if initialSelection, selected == nil { cancel(); return }
        initialSelection = false
        if let selected { source = selected }
        sourceMode.selectedSegment = sourceIndex(source)
        selectionBounds = nil
        switch source {
        case let .display(id,rect):
            sourceLabel.stringValue = rect.map { "\(Int($0.width)) × \(Int($0.height)) pt" } ?? "Full screen"
            if let rect, let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
                selectionBounds = CGRect(x:screen.frame.minX+rect.minX,y:screen.frame.maxY-rect.maxY,width:rect.width,height:rect.height)
            }
        case .window: sourceLabel.stringValue = "Selected window"
        }
        phase = .configuring; window?.makeFirstResponder(nil)
        regionOutline?.orderOut(nil); regionOutline = nil
        if let region = selectionBounds, present {
            let outline = NSPanel(contentRect:region.insetBy(dx:-2,dy:-2),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            outline.isOpaque = false; outline.backgroundColor = .clear; outline.hasShadow = false
            outline.level = .floating; outline.ignoresMouseEvents = true; outline.hidesOnDeactivate = false
            outline.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            outline.contentView = RecordingRegionView(); outline.orderFrontRegardless(); regionOutline = outline
        }
        placeControls(); if present { showWindow(nil) }
    }
    private func placeControls() {
        let screen:NSScreen
        if case let .display(id,_) = source { screen = NSScreen.screens.first(where: { $0.displayID == id }) ?? NSScreen.underPointer }
        else { screen = NSScreen.underPointer }
        guard let window else { return }
        let bounds = screen.visibleFrame.insetBy(dx:16,dy:16), size = window.frame.size
        var origin = CGPoint(x:bounds.midX-size.width/2,y:bounds.minY+30)
        if let region = selectionBounds {
            origin.x = min(bounds.maxX-size.width,max(bounds.minX,region.midX-size.width/2))
            if region.minY-size.height-12 >= bounds.minY { origin.y = region.minY-size.height-12 }
            else if region.maxY+size.height+12 <= bounds.maxY { origin.y = region.maxY+12 }
        }
        window.setFrameOrigin(origin)
    }
    private func selectArea() {
        guard !hasActiveWork else { return }
        phase = .selecting; regionOutline?.orderOut(nil); window?.orderOut(nil)
        selector.select(title:"Drag to select the area to record") { [weak self] source in self?.acceptSelection(source) }
    }
    private func selectWindow() {
        guard !hasActiveWork else { return }
        phase = .selecting; regionOutline?.orderOut(nil); window?.orderOut(nil)
        Task { [self] in
            do {
                picker = WindowPicker(content:try await CaptureEngine.content()) { [weak self] source in
                    guard let self else { return }; self.picker = nil; self.acceptSelection(source)
                }
                picker?.showWindow(nil)
            } catch { status.stringValue = error.localizedDescription; acceptSelection(nil) }
        }
    }
    @objc private func startRecording() {
        guard phase == .configuring else { return }
        phase = .preparing; pendingFailure = nil
        startButton.isEnabled = false; cancelButton.isEnabled = false
        configurationViews.forEach { $0.isEnabled = false }
        // Hide before resolving content or asking the writer to start. Setup never enters a recording.
        regionOutline?.orderOut(nil); window?.orderOut(nil)
        Task { [self] in
            do {
                let surface = try await CaptureEngine.surface(for:source)
                var options = RecordingOptions()
                options.fps = selectedFrameRate
                options.scale = resolution.indexOfSelectedItem == 1 ? 0.5 : resolution.indexOfSelectedItem == 2 ? min(1,min(1920/Double(surface.width),1080/Double(surface.height))) : 1
                options.microphone = microphone.state == .on; options.systemAudio = systemAudio.state == .on
                options.audioOnly = audioOnly.state == .on
                if !options.audioOnly, camera.state == .on, cameraDevices.indices.contains(devices.indexOfSelectedItem) { options.camera = cameraDevices[devices.indexOfSelectedItem] }
                options.corner = CameraCorner.allCases[corner.indexOfSelectedItem]
                let recording = RecordingSession(); session = recording
                recording.onFailure = { [weak self] error in
                    guard let self else { return }
                    if self.phase == .preparing { self.pendingFailure = error }
                    else if self.phase == .recording { self.pendingFailure = error; self.stop() }
                }
                try await recording.start(surface:surface,options:options)
                phase = .recording; startedAt = Date(); onState?(true); onElapsed?("00:00")
                if pendingFailure != nil { stop(); return }
                timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.phase == .recording, let start = self.startedAt else { return }
                        let elapsed = Int(Date().timeIntervalSince(start))
                        self.onElapsed?(String(format:"%02d:%02d",elapsed/60,elapsed%60))
                    }
                }
            } catch { session = nil; restoreAfterFailure(error) }
        }
    }
    func stop() {
        guard let session, phase == .recording else { return }
        phase = .finishing; timer?.invalidate(); timer = nil
        onElapsed?("Saving…")
        Task { [self] in
            do {
                var artifact = try await session.stop()
                if let pendingFailure { artifact.notice = "Recording ended early: \(pendingFailure.localizedDescription)" }
                self.session = nil; phase = .closed; onState?(false)
                close(); onFinish?(artifact)
            } catch { self.session = nil; restoreAfterFailure(error) }
        }
    }
    private func restoreAfterFailure(_ error:Error) {
        phase = .configuring; timer?.invalidate(); timer = nil
        onState?(false); configurationViews.forEach { $0.isEnabled = true }; cancelButton.isEnabled = true
        updateOptions(); status.stringValue = error.localizedDescription
        placeControls(); showWindow(nil)
    }
    @objc private func cancel() { guard !hasActiveWork else { return }; phase = .closed; close() }
    func windowShouldClose(_ sender:NSWindow) -> Bool { !hasActiveWork }
    func windowWillClose(_ notification:Notification) { phase = .closed; regionOutline?.orderOut(nil); regionOutline = nil; timer?.invalidate(); timer = nil; onClose?() }
}

private final class RecordingRegionView:NSView {
    override func draw(_ dirtyRect:NSRect) {
        let border = NSBezierPath(rect:bounds.insetBy(dx:2,dy:2))
        NSColor.black.withAlphaComponent(0.65).setStroke(); border.lineWidth = 3; border.stroke()
        NSColor.white.setStroke(); border.lineWidth = 1; border.stroke()
    }
}
