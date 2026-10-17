import AppKit

/// A recording boundary is display chrome, never part of the captured content.
/// CaptureEngine excludes this process from display streams; window streams
/// capture only their chosen window. The curtain itself passes all input through.
@MainActor
final class RecordingOverlay {
    enum Presentation { case desktop, offscreen }
    private let presentation: Presentation
    private(set) var panels: [NSPanel] = []
    private(set) var controls: NSPanel?
    private(set) var region: CGRect = .zero
    private var windowID: CGWindowID?
    private var geometryTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private let elapsed = NSTextField(labelWithString: "00:00")
    private var stopButton: NSButton?
    var onStop: (() -> Void)?

    init(presentation: Presentation = .desktop) { self.presentation = presentation }

    func show(region: CGRect, windowID: CGWindowID? = nil) {
        hide()
        self.region = region; self.windowID = windowID
        rebuildCurtains()
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 184, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(panel, identifier: "RecordingStopControls")
        panel.hasShadow = true; panel.isMovableByWindowBackground = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        let material = NSVisualEffectView(); material.material = .hudWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 11; material.layer?.masksToBounds = true
        let dot = NSImageView(image: NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")!)
        dot.contentTintColor = .systemRed
        elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        elapsed.stringValue = "Starting…"
        let stop = NSButton(title: "Stop", image: NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)!, target: self, action: #selector(stopRecording))
        stop.bezelStyle = .rounded; stop.setAccessibilityLabel("Stop recording")
        stop.isEnabled = false; stopButton = stop
        let row = NSStackView(views: [dot, elapsed, stop]); row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false; material.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: material.centerXAnchor), row.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14), dot.heightAnchor.constraint(equalToConstant: 14)
        ])
        panel.contentView = material; controls = panel; placeControls(); panel.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildCurtains(); self?.placeControls() }
        }
        if windowID != nil {
            // External windows have no AppKit move notification. Refresh only
            // their geometry; the desktop and area variants need no polling.
            geometryTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshWindowBounds() }
            }
        }
    }

    private func configure(_ panel: NSPanel, identifier: String) {
        panel.identifier = NSUserInterfaceItemIdentifier(identifier); panel.title = identifier
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
    private func rebuildCurtains() {
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: displayed(screen.frame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(panel, identifier: "RecordingBoundary")
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            panel.ignoresMouseEvents = true
            let view = RecordingCurtainView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.region = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            panel.contentView = view; panels.append(panel); panel.orderFrontRegardless()
        }
    }
    private func displayed(_ rect: CGRect) -> CGRect {
        presentation == .desktop ? rect : rect.offsetBy(dx: -30000, dy: -30000)
    }
    private func placeControls() {
        guard let controls else { return }
        let screen = NSScreen.screens.max { $0.frame.intersection(region).area < $1.frame.intersection(region).area } ?? NSScreen.underPointer
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12), size = controls.frame.size
        let x = min(visible.maxX-size.width, max(visible.minX, region.midX-size.width/2))
        var y = region.minY-size.height-12
        if y < visible.minY { y = region.maxY+12 }
        y = min(visible.maxY-size.height, max(visible.minY, y))
        controls.setFrameOrigin(displayed(CGRect(origin: CGPoint(x: x, y: y), size: size)).origin)
    }
    func updateElapsed(_ text: String) { elapsed.stringValue = text }
    func didStart() { elapsed.stringValue = "00:00"; stopButton?.isEnabled = true }
    private func refreshWindowBounds() {
        guard let windowID, let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let bounds = records.first?[kCGWindowBounds as String] as? [String: Any],
              let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary), let primary = NSScreen.screens.first else { return }
        let next = CGRect(x: rectangle.minX, y: primary.frame.maxY-rectangle.maxY, width: rectangle.width, height: rectangle.height)
        guard next != region else { return }; region = next
        for (panel, screen) in zip(panels, NSScreen.screens) {
            (panel.contentView as? RecordingCurtainView)?.region = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        }
        placeControls()
    }
    @objc private func stopRecording() { onStop?() }
    func hide() {
        geometryTimer?.invalidate(); geometryTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        controls?.orderOut(nil); controls = nil
        stopButton = nil
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

final class RecordingCurtainView: NSView {
    var region: CGRect = .zero { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let curtain = NSBezierPath(rect: bounds)
        curtain.appendRect(region); curtain.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill(); curtain.fill()
        let border = NSBezierPath(rect: region.insetBy(dx: 1.5, dy: 1.5))
        NSColor.black.withAlphaComponent(0.75).setStroke(); border.lineWidth = 3; border.stroke()
        NSColor.white.withAlphaComponent(0.95).setStroke(); border.lineWidth = 1; border.stroke()
    }
}
