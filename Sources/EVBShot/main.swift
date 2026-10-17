import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let selector = AreaSelector()
    private var picker: WindowPicker?
    private var scrolling: ScrollController?
    private var recording: RecordingController?
    private var results: [ResultController] = []
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder.circle.fill", accessibilityDescription: "EVBShot")
        rebuildMenu()
        if CommandLine.arguments.contains("--show-recorder") { showRecorder() }
    }
    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; return item
    }
    private func rebuildMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        let title = NSMenuItem(title: "EVBShot", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        for entry in [item("Capture Area…", #selector(captureArea)), item("Capture Full Screen", #selector(captureFull)), item("Capture Window…", #selector(captureWindow)), item("Scrolling Capture…", #selector(captureScrolling))] {
            entry.isEnabled = !busy; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let record = item(recording?.isRecording == true ? "Stop Recording & Review" : "Record Screen / Audio…", #selector(showRecorder))
        record.isEnabled = !busy || recording != nil; menu.addItem(record)
        menu.addItem(.separator())
        menu.addItem(item("Open Captures Folder", #selector(openDrafts)))
        menu.addItem(item("About EVBShot", #selector(about)))
        let quit = item("Quit EVBShot", #selector(quit)); quit.isEnabled = !busy; menu.addItem(quit)
        statusItem.menu = menu
    }
    private func setBusy(_ value: Bool) { busy = value; rebuildMenu() }
    @objc private func captureFull() { capture(.display(NSScreen.underPointer.displayID, nil)) }
    @objc private func captureArea() {
        setBusy(true)
        selector.select { [weak self] source in
            guard let self else { return }
            if let source { self.capture(source) } else { self.setBusy(false) }
        }
    }
    @objc private func captureWindow() {
        setBusy(true)
        Task { [self] in
            do {
                picker = WindowPicker(content: try await CaptureEngine.content()) { [weak self] source in
                    guard let self else { return }; self.picker = nil
                    if let source { self.capture(source) } else { self.setBusy(false) }
                }
                picker?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
            } catch { setBusy(false); presentError(error) }
        }
    }
    private func capture(_ source: CaptureSource) {
        setBusy(true)
        Task { [self] in
            do { showResult(try await CaptureEngine.screenshot(source)) }
            catch { presentError(error) }
            setBusy(false)
        }
    }
    @objc private func captureScrolling() {
        setBusy(true)
        selector.select { [weak self] source in
            guard let self else { return }
            guard let source else { self.setBusy(false); return }
            Task { [self] in
                do {
                    let spool = try LongCapture(folder: CaptureFiles.newSession())
                    let controller = ScrollController(source: source, spool: spool) { [weak self] artifact in
                        self?.scrolling = nil; self?.setBusy(false); self?.showResult(artifact)
                    }
                    controller.onCancel = { [weak self] in self?.scrolling = nil; self?.setBusy(false) }
                    self.scrolling = controller; controller.start()
                } catch { self.setBusy(false); presentError(error) }
            }
        }
    }
    @objc private func showRecorder() {
        if let recording {
            if recording.isRecording { recording.stop() }
            else { recording.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
            return
        }
        let controller = RecordingController(display: NSScreen.underPointer.displayID)
        controller.onFinish = { [weak self] in self?.showResult($0) }
        controller.onClose = { [weak self] in self?.recording = nil; self?.setBusy(false) }
        controller.onState = { [weak self] active in
            self?.statusItem.button?.image = NSImage(systemSymbolName: active ? "record.circle.fill" : "viewfinder.circle.fill", accessibilityDescription: active ? "EVBShot recording" : "EVBShot")
            self?.rebuildMenu()
        }
        recording = controller; setBusy(true); controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showResult(_ artifact: CaptureArtifact) {
        let result = ResultController(artifact); results.append(result)
        result.onClose = { [weak self, weak result] in self?.results.removeAll { $0 === result } }
        result.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openDrafts() {
        do { try FileManager.default.createDirectory(at: CaptureFiles.root, withIntermediateDirectories: true); NSWorkspace.shared.open(CaptureFiles.root) }
        catch { presentError(error) }
    }
    @objc private func about() {
        let alert = NSAlert(); alert.messageText = "EVBShot · Native Prototype"
        alert.informativeText = "Native-resolution screenshots and vertical scrolling capture. Screen/audio recording with optional selfie camera. No keyboard shortcuts. Captures stay on this Mac."
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if CommandLine.arguments.contains("--request-screen-access") {
        app.setActivationPolicy(.accessory)
        print("Screen capture access: \(CGRequestScreenCaptureAccess())")
        exit(0)
    } else if CommandLine.arguments.contains("--permission-status") {
        print("Screen capture access: \(CGPreflightScreenCaptureAccess())")
        exit(0)
    } else if let index = CommandLine.arguments.firstIndex(where: { $0 == "--self-test" || $0 == "--capture-smoke" }), CommandLine.arguments.indices.contains(index + 1) {
        app.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        Task {
            do {
                if CommandLine.arguments[index] == "--capture-smoke" { try await SelfTest.captureSmoke(folder: folder) }
                else { try await SelfTest.run(folder: folder) }
                exit(0)
            }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }
    app.run()
}
