import AppKit

// Key equivalents stay in the editor window, so capture tools have no global hotkeys.
@MainActor
final class EditorWindow: NSWindow {
    var historyCommand: ((Bool) -> Void)?
    var interactionBlocked = false
    override func sendEvent(_ event: NSEvent) {
        if interactionBlocked {
            switch event.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                 .otherMouseDown, .otherMouseUp, .otherMouseDragged, .keyDown, .keyUp, .scrollWheel,
                 .magnify, .rotate, .swipe, .smartMagnify:
                return
            default: break
            }
        }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if interactionBlocked { return true }
        let modifiers = event.modifierFlags.intersection([.command,.shift,.option,.control])
        guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "z",
              modifiers == [.command] || modifiers == [.command,.shift], attachedSheet == nil else {
            return super.performKeyEquivalent(with:event)
        }
        let redo = modifiers.contains(.shift)
        if let editor = firstResponder as? NSTextView, editor.isEditable {
            if let history = editor.undoManager {
                editor.breakUndoCoalescing()
                if redo { if history.canRedo { history.redo() } }
                else if history.canUndo { history.undo() }
            }
            return true
        }
        guard let historyCommand else { return super.performKeyEquivalent(with:event) }
        historyCommand(redo); return true
    }
}

@MainActor
final class AnnotationColorButton: NSButton {
    private static weak var active: AnnotationColorButton?
    private var popover: NSPopover?
    var color = MarkColor.red.nsColor { didSet { needsDisplay = true } }
    var colorChanged: (() -> Void)?
    override init(frame:NSRect) {
        super.init(frame:frame)
        isBordered = false; target = self; action = #selector(showColors)
        setAccessibilityLabel("Annotation color"); toolTip = "Annotation color"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect:NSRect) {
        color.withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:6,yRadius:6).fill()
        let symbol = NSImage(systemSymbolName:"chevron.down",accessibilityDescription:nil)!
        let size = CGSize(width:11,height:7)
        let rect = CGRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height)
        let tinted = NSImage(size:size,flipped:false) { target in
            symbol.draw(in:target); NSColor.white.setFill(); target.fill(using:.sourceAtop); return true
        }
        tinted.draw(in:rect,from:.zero,operation:.sourceOver,fraction:isEnabled ? 1 : 0.5,respectFlipped:true,hints:nil)
    }
    @objc private func showColors() {
        if let popover, popover.isShown { popover.performClose(nil); return }
        Self.active?.detachPanel()
        Self.active = self
        let palette = makePalette()
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
        popover.contentViewController = palette; self.popover = popover
        popover.show(relativeTo:bounds,of:self,preferredEdge:.minY)
    }
    func makePalette() -> AnnotationPaletteController {
        let palette = AnnotationPaletteController(color:color)
        palette.onPick = { [weak self] color in
            self?.color = color; self?.colorChanged?(); self?.popover?.performClose(nil)
        }
        palette.onMore = { [weak self] in self?.popover?.performClose(nil); self?.showCustomColors() }
        return palette
    }
    private func showCustomColors() {
        guard let window else { return }
        let panel = NSColorPanel.shared
        panel.color = color; panel.showsAlpha = false; panel.setTarget(self); panel.setAction(#selector(changed(_:)))
        let anchor = window.convertToScreen(convert(bounds,to:nil))
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x:anchor.midX,y:anchor.midY)) } ?? window.screen ?? NSScreen.main
        if let screen { panel.setFrame(Self.customPanelFrame(anchor:anchor,size:panel.frame.size,visibleFrame:screen.visibleFrame),display:false) }
        // Keep the optional system picker with its editor when the window moves.
        panel.parent?.removeChildWindow(panel); window.addChildWindow(panel,ordered:.above)
        panel.orderFront(nil)
    }
    static func customPanelFrame(anchor:CGRect,size:CGSize,visibleFrame:CGRect) -> CGRect {
        let available = visibleFrame.insetBy(dx:8,dy:8)
        let x = min(max(anchor.midX-size.width/2,available.minX),max(available.minX,available.maxX-size.width))
        let y = min(max(anchor.minY-size.height-10,available.minY),max(available.minY,available.maxY-size.height))
        return CGRect(origin:CGPoint(x:x,y:y),size:size)
    }
    @objc private func changed(_ panel:NSColorPanel) { color = panel.color; colorChanged?() }
    func detachPanel() {
        popover?.performClose(nil); popover = nil
        if Self.active === self {
            Self.active = nil
            let panel = NSColorPanel.shared
            panel.setTarget(nil); panel.parent?.removeChildWindow(panel); panel.orderOut(nil)
        }
    }
}

@MainActor
final class AnnotationPaletteController: NSViewController {
    static let choices:[(String,NSColor)] = [
        ("Red",MarkColor.red.nsColor),
        ("Orange",.systemOrange),("Yellow",.systemYellow),("Green",.systemGreen),
        ("Blue",.systemBlue),("Purple",.systemPurple),
        ("Pink",.systemPink),("Cyan",.systemTeal),("Indigo",.systemIndigo),
        ("White",.white),("Gray",.gray),("Black",.black)
    ]
    var onPick:((NSColor)->Void)?
    var onMore:(()->Void)?
    private let color:NSColor
    init(color:NSColor) { self.color = color; super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top:14,left:14,bottom:12,right:14)
        let title = NSTextField(labelWithString:"Annotation color"); title.font = .systemFont(ofSize:12,weight:.medium)
        stack.addArrangedSubview(title)
        for row in 0..<2 {
            let buttons = (0..<6).map { column -> NSView in
                let index = row*6+column, choice = Self.choices[index]
                let button = AnnotationSwatch(frame:.zero); button.swatch = choice.1; button.tag = index
                button.state = MarkColor(choice.1) == MarkColor(color) ? .on : .off
                button.target = self; button.action = #selector(pick(_:)); button.toolTip = choice.0
                button.setAccessibilityLabel(choice.0); button.isBordered = false
                button.widthAnchor.constraint(equalToConstant:26).isActive = true
                button.heightAnchor.constraint(equalToConstant:26).isActive = true
                return button
            }
            let line = NSStackView(views:buttons); line.spacing = 8; stack.addArrangedSubview(line)
        }
        let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant:196).isActive = true
        let more = NSButton(title:"More Colors…",target:self,action:#selector(moreColors)); more.bezelStyle = .rounded
        more.controlSize = .small; more.font = .systemFont(ofSize:12); stack.addArrangedSubview(more)
        let material = NSVisualEffectView(); material.material = .popover; material.state = .active
        material.blendingMode = .withinWindow
        stack.translatesAutoresizingMaskIntoConstraints = false; material.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:material.leadingAnchor),stack.trailingAnchor.constraint(equalTo:material.trailingAnchor),stack.topAnchor.constraint(equalTo:material.topAnchor),stack.bottomAnchor.constraint(equalTo:material.bottomAnchor)])
        view = material; preferredContentSize = stack.fittingSize
    }
    @objc private func pick(_ sender:NSButton) { onPick?(Self.choices[sender.tag].1) }
    @objc private func moreColors() { onMore?() }
}

@MainActor
private final class AnnotationSwatch: NSButton {
    var swatch = NSColor.red
    override func draw(_ dirtyRect:NSRect) {
        let circle = NSBezierPath(ovalIn:bounds.insetBy(dx:2,dy:2))
        swatch.setFill(); circle.fill()
        NSColor.labelColor.withAlphaComponent(0.2).setStroke(); circle.lineWidth = 1; circle.stroke()
        if state == .on {
            NSColor.labelColor.setStroke(); let ring = NSBezierPath(ovalIn:bounds.insetBy(dx:0.5,dy:0.5)); ring.lineWidth = 1; ring.stroke()
        }
    }
}
