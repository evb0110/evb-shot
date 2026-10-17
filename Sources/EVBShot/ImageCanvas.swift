import AppKit

enum EditorTool: String, CaseIterable {
    case select = "Select", rectangle = "Rectangle", arrow = "Arrow", text = "Text", crop = "Crop"
    var symbol: String { switch self { case .select: return "cursorarrow"; case .rectangle: return "rectangle"; case .arrow: return "arrow.up.right"; case .text: return "textformat"; case .crop: return "crop" } }
}

@MainActor
final class ImageCanvas: NSView, NSTextFieldDelegate {
    let document: ImageEditDocument
    var onInteraction: (() -> Void)?
    var onError: ((Error) -> Void)?
    var editingEnabled = true
    var color = MarkColor.red
    var thickness: CGFloat = 6
    var fontSize: CGFloat = 48
    private(set) var tool: EditorTool = .select
    private(set) var selected: UUID?
    private(set) var pendingCrop: CGRect?
    private(set) var zoom: CGFloat = 1
    private var fitMode = 0
    private var imageOrigin = CGPoint.zero
    private var tileImage: CGImage?
    private var tileRect = CGRect.zero
    private var requested = CGRect.zero
    private var tileTask: Task<Void, Never>?
    private var dragAnchor: CGPoint?
    private var dragMark: ImageMark?
    private var originalMark: ImageMark?
    private var resizeHandle: Int?
    private var cropAtDrag: CGRect?
    private var movingCrop = false
    private var textInput: NSTextField?
    private var textMark: ImageMark?
    private var preview: NSImage?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    init(document: ImageEditDocument, preview: NSImage?) {
        self.document = document; self.preview = preview
        super.init(frame: .zero)
        setAccessibilityLabel("Screenshot canvas")
        setAccessibilityRole(.group)
        fitMode = document.state.crop.height > document.state.crop.width * 3 ? 1 : 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var selectedMark: ImageMark? { document.state.marks.first { $0.id == selected } }
    func setTool(_ tool: EditorTool) {
        commitText(); self.tool = tool
        pendingCrop = tool == .crop ? document.state.crop : nil
        selected = nil; needsDisplay = true; onInteraction?()
        window?.makeFirstResponder(self)
    }
    func refresh() {
        if let selected, !document.state.marks.contains(where: { $0.id == selected }) { self.selected = nil }
        relayout(); needsDisplay = true
    }
    func setZoom(_ index: Int) {
        commitText()
        fitMode = index < 2 ? index : -1
        if index >= 2 { zoom = [0.5, 1, 2, 4][min(3, index - 2)] }
        tileImage = nil; requested = .zero; relayout(); onInteraction?()
    }
    func relayout() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let visible = clip.bounds.size, crop = document.state.crop
        let previousZoom = zoom
        if fitMode >= 0 {
            let horizontal = max(0.00001, (visible.width - 40) / crop.width)
            zoom = fitMode == 1 ? horizontal : min(horizontal, max(0.00001, (visible.height - 40) / crop.height))
            zoom = min(2, zoom)
        }
        if abs(previousZoom-zoom) > 0.00001 { tileTask?.cancel(); tileImage = nil; tileRect = .zero; requested = .zero }
        let size = CGSize(width: max(visible.width, crop.width * zoom + 40), height: max(visible.height, crop.height * zoom + 40))
        setFrameSize(size)
        imageOrigin = CGPoint(x: max(20, (size.width - crop.width * zoom) / 2), y: max(20, (size.height - crop.height * zoom) / 2))
        needsDisplay = true
    }
    private var displayRect: CGRect { CGRect(origin: imageOrigin, size: CGSize(width: document.state.crop.width * zoom, height: document.state.crop.height * zoom)) }
    func pointInImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - imageOrigin.x) / zoom + document.state.crop.minX, y: (point.y - imageOrigin.y) / zoom + document.state.crop.minY)
    }
    func pointInView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageOrigin.x + (point.x - document.state.crop.minX) * zoom, y: imageOrigin.y + (point.y - document.state.crop.minY) * zoom)
    }
    private func rectInView(_ rect: CGRect) -> CGRect { CGRect(origin: pointInView(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom)) }
    private func clamped(_ point: CGPoint) -> CGPoint {
        let crop = document.state.crop
        return CGPoint(x: min(crop.maxX, max(crop.minX, point.x)), y: min(crop.maxY, max(crop.minY, point.y)))
    }

    override func draw(_ dirtyRect: NSRect) {
        (tool == .crop ? NSColor.darkGray : NSColor.controlBackgroundColor).setFill(); dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill(); displayRect.fill()
        context.saveGState(); context.clip(to: displayRect)
        if let preview { preview.draw(in: rectInView(CGRect(origin: .zero, size: preview.size)), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]) }
        if let tileImage {
            let rect = rectInView(tileRect)
            context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = zoom >= 1 ? .none : .high
            context.draw(tileImage, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
        }
        context.translateBy(x: imageOrigin.x - document.state.crop.minX * zoom, y: imageOrigin.y - document.state.crop.minY * zoom)
        context.scaleBy(x: zoom, y: zoom)
        for mark in document.state.marks where mark.id != textMark?.id {
            MarkRenderer.draw(dragMark?.id == mark.id ? dragMark! : mark, in: context)
        }
        if let dragMark, originalMark == nil { MarkRenderer.draw(dragMark, in: context) }
        context.restoreGState()
        NSColor.separatorColor.setStroke(); NSBezierPath(rect: displayRect).stroke()
        if let pendingCrop { drawCrop(pendingCrop) }
        else if let mark = dragMark ?? selectedMark { drawSelection(mark) }
        requestTile()
    }
    private func requestTile() {
        let visible = visibleRect.intersection(displayRect)
        guard !visible.isEmpty else { return }
        let a = pointInImage(visible.origin), b = pointInImage(CGPoint(x: visible.maxX, y: visible.maxY))
        let region = CGRect(x: a.x, y: a.y, width: b.x-a.x, height: b.y-a.y).insetBy(dx: -32 / zoom, dy: -32 / zoom).integral.intersection(document.state.crop)
        if tileRect.contains(region) && tileImage != nil { return }
        guard requested != region else { return }
        requested = region; tileTask?.cancel()
        let scale = window?.backingScaleFactor ?? 2
        let maximum = CGSize(width: region.width * zoom * scale, height: region.height * zoom * scale)
        tileTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let image = try await document.pixels.tile(region, maximum: maximum)
                guard !Task.isCancelled, requested == region else { return }
                tileImage = image; tileRect = region; needsDisplay = true
            } catch { if !Task.isCancelled { onError?(error) } }
        }
    }
    private func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX,y: rect.minY), CGPoint(x: rect.maxX,y: rect.minY), CGPoint(x: rect.maxX,y: rect.maxY), CGPoint(x: rect.minX,y: rect.maxY)]
    }
    private func drawHandle(_ point: CGPoint) {
        let p = pointInView(point), r = CGRect(x: p.x-4, y: p.y-4, width: 8, height: 8)
        NSColor.white.setFill(); NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2); path.lineWidth = 1.5; path.fill(); path.stroke()
    }
    private func drawSelection(_ mark: ImageMark) {
        let rect = rectInView(MarkRenderer.bounds(mark)).insetBy(dx: -3, dy: -3)
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: rect); border.setLineDash([4, 3], count: 2, phase: 0); border.stroke()
        if mark.kind == .arrow { [mark.start,mark.end].forEach(drawHandle) }
        else if mark.kind == .rectangle {
            handles(CGRect(x: min(mark.start.x,mark.end.x),y: min(mark.start.y,mark.end.y),width: abs(mark.end.x-mark.start.x),height: abs(mark.end.y-mark.start.y))).forEach(drawHandle)
        }
    }
    private func drawCrop(_ crop: CGRect) {
        let rect = rectInView(crop)
        let mask = NSBezierPath(rect: displayRect); mask.appendRect(rect); mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill(); mask.fill()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        for n in 1...2 {
            let path = NSBezierPath()
            let x = rect.minX + rect.width * CGFloat(n) / 3, y = rect.minY + rect.height * CGFloat(n) / 3
            path.move(to: CGPoint(x: x,y: rect.minY)); path.line(to: CGPoint(x: x,y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX,y: y)); path.line(to: CGPoint(x: rect.maxX,y: y)); path.stroke()
        }
        NSBezierPath(rect: rect).stroke(); handles(crop).forEach(drawHandle)
    }
    override func mouseDown(with event: NSEvent) { beginGesture(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount) }
    override func mouseDragged(with event: NSEvent) { continueGesture(at: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { endGesture(at: convert(event.locationInWindow, from: nil)) }

    // Mouse dispatch and deterministic UI checks use this same gesture interface.
    func beginGesture(at viewPoint: CGPoint, clickCount: Int = 1) {
        guard editingEnabled else { return }
        commitText(); window?.makeFirstResponder(self)
        guard displayRect.contains(viewPoint) else { selected = nil; onInteraction?(); needsDisplay = true; return }
        let point = clamped(pointInImage(viewPoint)); dragAnchor = point; resizeHandle = nil; originalMark = nil
        if tool == .crop {
            let crop = pendingCrop ?? document.state.crop; cropAtDrag = crop
            resizeHandle = handles(crop).firstIndex { hypot($0.x-point.x,$0.y-point.y) * zoom < 10 }
            movingCrop = resizeHandle == nil && crop != document.state.crop && crop.contains(point)
            if resizeHandle == nil && !movingCrop { pendingCrop = CGRect(origin: point, size: .zero) }
        } else if tool == .select {
            if let mark = selectedMark, mark.kind != .text {
                let points = mark.kind == .arrow ? [mark.start,mark.end] : handles(CGRect(x:min(mark.start.x,mark.end.x),y:min(mark.start.y,mark.end.y),width:abs(mark.end.x-mark.start.x),height:abs(mark.end.y-mark.start.y)))
                resizeHandle = points.firstIndex { hypot($0.x-point.x,$0.y-point.y) * zoom < 10 }
                if resizeHandle != nil { originalMark = mark; dragMark = mark; return }
            }
            let hit = document.state.marks.reversed().first { MarkRenderer.bounds($0).insetBy(dx: -6/zoom,dy: -6/zoom).contains(point) }
            selected = hit?.id
            if let hit, hit.kind == .text, clickCount > 1 { editText(hit); return }
            originalMark = hit; dragMark = hit
        } else if tool == .text {
            editText(ImageMark(kind: .text, start: point, end: point, color: color, thickness: thickness, fontSize: fontSize)); return
        } else {
            selected = nil
            dragMark = ImageMark(kind: tool == .arrow ? .arrow : .rectangle, start: point, end: point, color: color, thickness: thickness, fontSize: fontSize)
        }
        onInteraction?(); needsDisplay = true
    }
    func continueGesture(at viewPoint: CGPoint) {
        guard editingEnabled, let anchor = dragAnchor else { return }
        let p = clamped(pointInImage(viewPoint))
        if tool == .crop {
            var rect = cropAtDrag ?? document.state.crop
            if let resizeHandle { rect = resized(rect, corner: resizeHandle, point: p) }
            else if movingCrop {
                let bounds = document.state.crop
                rect.origin.x = min(bounds.maxX-rect.width,max(bounds.minX,rect.minX+p.x-anchor.x))
                rect.origin.y = min(bounds.maxY-rect.height,max(bounds.minY,rect.minY+p.y-anchor.y))
            } else { rect = CGRect(x:min(anchor.x,p.x),y:min(anchor.y,p.y),width:abs(p.x-anchor.x),height:abs(p.y-anchor.y)) }
            pendingCrop = rect.standardized.intersection(document.state.crop)
        } else if let originalMark {
            if let resizeHandle {
                var mark = originalMark
                if mark.kind == .arrow { if resizeHandle == 0 { mark.start = p } else { mark.end = p } }
                else {
                    let rect = CGRect(x:min(mark.start.x,mark.end.x),y:min(mark.start.y,mark.end.y),width:abs(mark.end.x-mark.start.x),height:abs(mark.end.y-mark.start.y))
                    let changed = resized(rect, corner: resizeHandle, point: p)
                    mark.start = changed.origin; mark.end = CGPoint(x:changed.maxX,y:changed.maxY)
                }
                dragMark = mark
            } else { dragMark = originalMark.moved(CGSize(width:p.x-anchor.x,height:p.y-anchor.y)) }
        } else if dragMark != nil { dragMark?.end = p }
        onInteraction?(); needsDisplay = true
    }
    private func resized(_ rect: CGRect, corner: Int, point: CGPoint) -> CGRect {
        let opposite = handles(rect)[(corner+2)%4]
        return CGRect(x:min(point.x,opposite.x),y:min(point.y,opposite.y),width:abs(point.x-opposite.x),height:abs(point.y-opposite.y))
    }
    func endGesture(at point: CGPoint) {
        continueGesture(at: point)
        if tool != .crop, let mark = dragMark {
            if originalMark != nil { document.replace(mark) }
            else if hypot(mark.end.x-mark.start.x,mark.end.y-mark.start.y) >= 2 { document.add(mark); selected = mark.id }
        }
        dragAnchor = nil; dragMark = nil; originalMark = nil; resizeHandle = nil
        onInteraction?(); needsDisplay = true
    }
    func applyCrop() { commitText(); if let pendingCrop { document.crop(pendingCrop) }; setTool(.select); tileRect = .zero; refresh() }
    func deleteSelection() { commitText(); if let selected { document.remove(selected) }; selected = nil; onInteraction?() }
    func updateStyle() {
        if var mark = selectedMark { mark.color = color; mark.thickness = thickness; mark.fontSize = fontSize; document.replace(mark) }
        needsDisplay = true
    }
    private func editText(_ mark: ImageMark) {
        textMark = mark; selected = mark.id
        let p = pointInView(mark.start)
        let field = NSTextField(frame: CGRect(x:p.x-4,y:p.y-4,width:max(180,MarkRenderer.bounds(mark).width * zoom + 24),height:max(28,mark.fontSize * zoom * 1.4)))
        field.stringValue = mark.text; field.placeholderString = "Type a label"
        field.font = .systemFont(ofSize: max(10,mark.fontSize * zoom),weight: .bold)
        field.textColor = mark.color.nsColor; field.backgroundColor = .textBackgroundColor
        field.isBordered = true; field.delegate = self
        addSubview(field); textInput = field; window?.makeFirstResponder(field); needsDisplay = true
    }
    func commitText(_ replacement: String? = nil) {
        guard let field = textInput, var mark = textMark else { return }
        let text = replacement ?? field.currentEditor()?.string ?? field.stringValue
        textInput = nil; textMark = nil; field.delegate = nil
        window?.makeFirstResponder(self); field.removeFromSuperview()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mark.text = text
            if document.state.marks.contains(where: { $0.id == mark.id }) { document.replace(mark) } else { document.add(mark) }
            selected = mark.id; tool = .select
        }
        onInteraction?(); needsDisplay = true
    }
    func controlTextDidEndEditing(_ obj: Notification) { commitText() }
}
