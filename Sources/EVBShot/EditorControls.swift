import AppKit

// Key equivalents stay in the editor window, so capture tools have no global hotkeys.
@MainActor
final class EditorWindow: NSWindow {
    var historyCommand: ((Bool) -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
        Self.active = self
        let panel = NSColorPanel.shared
        panel.color = color; panel.showsAlpha = false; panel.setTarget(self); panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }
    @objc private func changed(_ panel:NSColorPanel) { color = panel.color; colorChanged?() }
    func detachPanel() { if Self.active === self { Self.active = nil; NSColorPanel.shared.setTarget(nil); NSColorPanel.shared.orderOut(nil) } }
}
