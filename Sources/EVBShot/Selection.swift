import AppKit
import ScreenCaptureKit

@MainActor
final class AreaSelector {
    private var panels: [NSPanel] = []
    private var completion: ((CaptureSource?) -> Void)?

    func select(completion: @escaping (CaptureSource?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.level = .screenSaver; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.finished = { [weak self] rect in
                let source = rect.map { selected in
                    CaptureSource.display(screen.displayID,
                        CGRect(x: selected.minX, y: screen.frame.height - selected.maxY,
                               width: selected.width, height: selected.height))
                }
                self?.finish(source)
            }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSCursor.crosshair.push()
    }

    private func finish(_ source: CaptureSource?) {
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        NSCursor.pop()
        let callback = completion; completion = nil
        callback?(source)
    }
}

private final class SelectionView: NSView {
    var finished: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var rectangle: CGRect?
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        cancel.bezelStyle = .rounded
        cancel.frame = CGRect(x: frame.width / 2 - 40, y: frame.height - 100, width: 80, height: 30)
        addSubview(cancel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func cancelSelection() { finished?(nil) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill()
        let mask = NSBezierPath(rect: bounds)
        if let rectangle { mask.appendRect(rectangle); mask.windingRule = .evenOdd }
        mask.fill()
        if let rectangle {
            NSColor.systemOrange.setStroke()
            let border = NSBezierPath(rect: rectangle); border.lineWidth = 2; border.stroke()
            let text = "\(Int(rectangle.width)) × \(Int(rectangle.height)) points"
            text.draw(at: CGPoint(x: rectangle.minX + 8, y: rectangle.maxY + 8), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        }
        let title = "Drag to select the area to capture"
        title.draw(at: CGPoint(x: bounds.midX - 145, y: bounds.height - 55), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) { anchor = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        rectangle = CGRect(x: min(p.x, anchor.x), y: min(p.y, anchor.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if let rectangle, rectangle.width >= 2, rectangle.height >= 2 { finished?(rectangle) }
    }
}

@MainActor
final class WindowPicker: NSWindowController, NSWindowDelegate {
    private let popup = NSPopUpButton()
    private let windows: [SCWindow]
    private var completion: ((CaptureSource?) -> Void)?

    init(content: SCShareableContent, completion: @escaping (CaptureSource?) -> Void) {
        windows = content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 &&
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
        self.completion = completion
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Choose a window"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        let label = NSTextField(labelWithString: "Capture the window itself, with no added background or shadow.")
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        popup.addItems(withTitles: windows.map { "\($0.owningApplication?.applicationName ?? "App") · \($0.title?.isEmpty == false ? $0.title! : "Untitled window")" })
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [NSButton(title: "Cancel", target: self, action: #selector(cancel)), NSButton(title: "Choose Window", target: self, action: #selector(choose))])
        stack.addArrangedSubview(label); stack.addArrangedSubview(popup); stack.addArrangedSubview(buttons)
        stack.wantsLayer = true; stack.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = stack; window.center()
        if windows.isEmpty { buttons.arrangedSubviews.last?.isHidden = true; label.stringValue = "No available windows. Open a window and try again." }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func choose() {
        guard windows.indices.contains(popup.indexOfSelectedItem) else { return }
        let callback = completion; completion = nil; close()
        callback?(.window(windows[popup.indexOfSelectedItem].windowID))
    }
    @objc private func cancel() { let callback = completion; completion = nil; close(); callback?(nil) }
    func windowWillClose(_ notification: Notification) { let callback = completion; completion = nil; callback?(nil) }
}
