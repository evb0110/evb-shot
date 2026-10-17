import AppKit
import ImageIO

@MainActor
enum StatusIcon {
    static func image(recording: Bool = false) -> NSImage {
        let image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "viewfinder.circle.fill", accessibilityDescription: recording ? "EVB Shot recording" : "EVB Shot")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))!
        image.size = NSSize(width: 18, height: 18); image.isTemplate = true
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let selector = AreaSelector()
    private var picker: WindowPicker?
    private var scrolling: ScrollController?
    private var recording: RecordingController?
    private var results: [ResultController] = []
    private var settings: SettingsController?
    private weak var aboutWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let icon = Bundle.main.image(forResource:"AppIcon") { NSApp.applicationIconImage = icon }
        let mainMenu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(item("About EVB Shot",#selector(about),symbol:"info.circle"))
        appMenu.addItem(item("Settings…",#selector(showSettings),symbol:"gearshape"))
        appMenu.addItem(.separator()); appMenu.addItem(item("Quit EVB Shot",#selector(quit),symbol:"power"))
        appItem.submenu = appMenu; mainMenu.addItem(appItem); NSApp.mainMenu = mainMenu
        closeObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:nil,queue:.main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.aboutWindow else { return }
                self.aboutWindow = nil; self.updateActivationPolicy()
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.image = StatusIcon.image()
        rebuildMenu()
        if CommandLine.arguments.contains("--show-recorder") { showRecorder() }
        for index in CommandLine.arguments.indices where CommandLine.arguments[index] == "--show-capture" && CommandLine.arguments.indices.contains(index + 1) {
            do {
                let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                      let width = info[kCGImagePropertyPixelWidth as String] as? Int,
                      let height = info[kCGImagePropertyPixelHeight as String] as? Int,
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary) else {
                    throw ShotError("Cannot open this capture.")
                }
                let preview = NSImage(cgImage: thumbnail, size: NSSize(width: width, height: height))
                showResult(CaptureArtifact(url: url, kind: .image, width: width, height: height, hasAudio: false, preview: preview))
            } catch { presentError(error) }
        }
    }
    private func item(_ title: String, _ action: Selector, symbol:String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
        if let symbol { item.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil); item.image?.size = NSSize(width:16,height:16) }
        return item
    }
    private func updateActivationPolicy() {
        let hasWorkspace = !results.isEmpty || recording != nil || picker != nil || aboutWindow != nil || settings != nil
        NSApp.setActivationPolicy(hasWorkspace ? .regular : .accessory)
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        if let result = results.last { result.window?.deminiaturize(nil); result.showWindow(nil) }
        else if let recording { recording.showWindow(nil) }
        else if let settings { settings.showWindow(nil) }
        else if let aboutWindow { aboutWindow.makeKeyAndOrderFront(nil) }
        else { statusItem.button?.performClick(nil) }
        return true
    }
    private func rebuildMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        let title = NSMenuItem(title: "EVB Shot", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        for entry in [item("Capture Area…", #selector(captureArea),symbol:"viewfinder"), item("Capture Full Screen", #selector(captureFull),symbol:"display"), item("Capture Window…", #selector(captureWindow),symbol:"macwindow"), item("Scrolling Capture…", #selector(captureScrolling),symbol:"arrow.down.square")] {
            entry.isEnabled = !busy; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let record = item(recording?.isRecording == true ? "Stop Recording & Review" : "Record Screen / Audio…", #selector(showRecorder),symbol:recording?.isRecording == true ? "stop.circle" : "record.circle")
        record.isEnabled = !busy || recording != nil; menu.addItem(record)
        menu.addItem(.separator())
        menu.addItem(item("Open Captures Folder", #selector(openCaptures),symbol:"folder"))
        menu.addItem(item("Open Drafts Folder", #selector(openDrafts),symbol:"tray.full"))
        menu.addItem(item("Settings…", #selector(showSettings),symbol:"gearshape"))
        menu.addItem(item("About EVB Shot", #selector(about),symbol:"info.circle"))
        let quit = item("Quit EVB Shot", #selector(quit),symbol:"power"); quit.isEnabled = !busy; menu.addItem(quit)
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
                    guard let self else { return }; self.picker = nil; self.updateActivationPolicy()
                    if let source { self.capture(source) } else { self.setBusy(false) }
                }
                updateActivationPolicy(); picker?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
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
        let targetApp = NSWorkspace.shared.frontmostApplication
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
                    if targetApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier { targetApp?.activate() }
                } catch { self.setBusy(false); presentError(error) }
            }
        }
    }
    @objc private func showRecorder() {
        if let recording {
            if recording.isRecording { recording.stop() }
            else if !recording.hasActiveWork { recording.showWindow(nil) }
            return
        }
        let controller = RecordingController(display: NSScreen.underPointer.displayID)
        controller.onFinish = { [weak self] in self?.showResult($0) }
        controller.onClose = { [weak self] in self?.recording = nil; self?.setBusy(false); self?.updateActivationPolicy() }
        controller.onState = { [weak self] active in
            self?.statusItem.button?.image = StatusIcon.image(recording: active)
            self?.statusItem.length = active ? NSStatusItem.variableLength : NSStatusItem.squareLength
            self?.statusItem.button?.imagePosition = active ? .imageLeading : .imageOnly
            if !active { self?.statusItem.button?.title = "" }
            self?.rebuildMenu()
        }
        controller.onElapsed = { [weak self] time in
            self?.statusItem.button?.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium)
            self?.statusItem.button?.imagePosition = .imageLeading
            self?.statusItem.button?.title = " " + time
        }
        recording = controller; setBusy(true); updateActivationPolicy(); controller.beginSelection()
    }
    private func showResult(_ artifact: CaptureArtifact) {
        let result = ResultController(artifact); results.append(result)
        result.onClose = { [weak self, weak result] in self?.results.removeAll { $0 === result }; self?.updateActivationPolicy() }
        updateActivationPolicy()
        if artifact.kind == .image { result.showWindow(nil); NSApp.activate(ignoringOtherApps:true) }
        else { result.window?.orderFrontRegardless() }
    }
    @objc private func openDrafts() {
        do { try FileManager.default.createDirectory(at: CaptureFiles.root, withIntermediateDirectories: true); NSWorkspace.shared.open(CaptureFiles.root) }
        catch { presentError(error) }
    }
    @objc private func openCaptures() {
        do {
            let folder = CaptureSaveSettings().folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch { presentError(error) }
    }
    @objc private func showSettings() {
        if settings == nil {
            let controller = SettingsController()
            controller.onClose = { [weak self] in self?.settings = nil; self?.updateActivationPolicy() }
            settings = controller
        }
        updateActivationPolicy(); settings?.window?.deminiaturize(nil); settings?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func about() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
        let credits = NSMutableAttributedString(string:"Eugene Barsky\n\nNative screenshots and screen recording.\nYour captures stay on this Mac.\n\n",attributes:[.font:NSFont.systemFont(ofSize:12)])
        credits.append(NSAttributedString(string:"Source code",attributes:[.link:URL(string:"https://github.com/evb0110/evb-shot")!]))
        credits.append(NSAttributedString(string:"  ·  "))
        if let license = Bundle.main.url(forResource:"libpng-LICENSE",withExtension:"txt") { credits.append(NSAttributedString(string:"libpng license",attributes:[.link:license])) }
        NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"EVB Shot",.applicationVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.1.0",.version:"Beta",.credits:credits,.applicationIcon:NSApp.applicationIconImage!])
        aboutWindow = NSApp.keyWindow; aboutWindow?.hidesOnDeactivate = false
        updateActivationPolicy(); NSApp.activate(ignoringOtherApps:true)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard recording?.hasActiveWork != true, scrolling == nil, !results.contains(where: { $0.isSaving }), !(busy && recording == nil && picker == nil) else { return .terminateCancel }
        for result in results {
            result.canvas?.commitText()
            if let error = result.editDocument?.persistenceError { presentError(error); return .terminateCancel }
        }
        return .terminateNow
    }
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
    } else if let index = CommandLine.arguments.firstIndex(where: { $0 == "--self-test" || $0 == "--capture-smoke" || $0 == "--result-layout-test" || $0 == "--editor-test" || $0 == "--recording-ui-test" || $0 == "--landing-preview" }), CommandLine.arguments.indices.contains(index + 1) {
        app.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        Task {
            do {
                if CommandLine.arguments[index] == "--capture-smoke" { try await SelfTest.captureSmoke(folder: folder) }
                else if CommandLine.arguments[index] == "--result-layout-test" { try SelfTest.resultLayout(folder: folder) }
                else if CommandLine.arguments[index] == "--editor-test" { try await EditorTest.run(folder: folder) }
                else if CommandLine.arguments[index] == "--recording-ui-test" { try await EditorTest.recordingWorkflow(folder: folder) }
                else if CommandLine.arguments[index] == "--landing-preview" { try await EditorTest.landingPreview(folder: folder) }
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
