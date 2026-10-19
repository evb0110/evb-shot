import AppKit
import CoreImage

/// Bottom-left coordinates shared by the desktop preview and encoded frames.
struct SelfiePlacement: Equatable, Sendable {
    var x:CGFloat
    var y:CGFloat
    var width:CGFloat
    func rect(in size:CGSize) -> CGRect {
        let w = max(1,min(width*size.width,size.width,size.height*4/3)), h = w*0.75
        return CGRect(x:min(max(0,x*size.width),max(0,size.width-w)),
                      y:min(max(0,y*size.height),max(0,size.height-h)),width:w,height:h)
    }
    init(rect:CGRect,in size:CGSize) { x = rect.minX/size.width; y = rect.minY/size.height; width = rect.width/size.width }
    static func initial(size:CGSize,corner:CameraCorner) -> SelfiePlacement {
        let w = min(max(64,size.width*0.22),480,size.width,size.height*4/3), h = w*0.75
        let margin = min(max(12,size.width*0.012),max(0,min((size.width-w)/2,(size.height-h)/2)))
        let left = corner == .bottomLeft || corner == .topLeft, top = corner == .topLeft || corner == .topRight
        return SelfiePlacement(rect:CGRect(x:left ? margin : size.width-w-margin,
            y:top ? size.height-h-margin : margin,width:w,height:h),in:size)
    }
}

final class CameraFrame: @unchecked Sendable {
    let buffer:CVPixelBuffer
    init(_ buffer:CVPixelBuffer) { self.buffer = buffer }
}

@MainActor
final class SelfieOverlay {
    private let presentation:RecordingOverlay.Presentation
    private(set) var panel:NSPanel?
    private(set) var placement:SelfiePlacement?
    private var region:CGRect = .zero
    private let preview = SelfiePreviewView()
    var onChange:((SelfiePlacement)->Void)?
    init(presentation:RecordingOverlay.Presentation) { self.presentation = presentation }
    func show(region:CGRect,placement:SelfiePlacement) {
        hide(); self.region = region; self.placement = placement
        let panel = NSPanel(contentRect:displayed(placement.rect(in:region.size).offsetBy(dx:region.minX,dy:region.minY)),
            styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.identifier = NSUserInterfaceItemIdentifier("RecordingSelfiePreview"); panel.title = "Selfie preview"
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+2)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        preview.onDrag = { [weak self] frame,resizing in self?.setFrame(frame,resizing:resizing) }
        panel.contentView = preview; self.panel = panel; panel.orderFrontRegardless()
    }
    func update(_ frame:CameraFrame) { guard panel != nil else { return }; preview.update(frame) }
    func updateRegion(_ region:CGRect) {
        self.region = region
        guard let placement else { return }
        panel?.setFrame(displayed(placement.rect(in:region.size).offsetBy(dx:region.minX,dy:region.minY)),display:true)
    }
    /// The same path is used by actual native drag/resize gestures and UI checks.
    func setFrame(_ frame:CGRect,resizing:Bool = false) {
        guard let panel else { return }
        var frame = presentation == .offscreen ? frame.offsetBy(dx:30000,dy:30000) : frame
        let width = min(max(min(72,region.width),frame.width),region.width,region.height*4/3)
        let top = frame.maxY
        frame.size = CGSize(width:width,height:width*0.75)
        if resizing { frame.origin.y = top-frame.height }
        frame.origin.x = min(max(region.minX,frame.minX),region.maxX-frame.width)
        frame.origin.y = min(max(region.minY,frame.minY),region.maxY-frame.height)
        let next = SelfiePlacement(rect:frame.offsetBy(dx:-region.minX,dy:-region.minY),in:region.size)
        placement = next; panel.setFrame(displayed(frame),display:true); onChange?(next)
    }
    private func displayed(_ frame:CGRect) -> CGRect { presentation == .offscreen ? frame.offsetBy(dx:-30000,dy:-30000) : frame }
    func hide() { panel?.orderOut(nil); panel = nil; preview.clear(); placement = nil }
}

final class SelfiePreviewView:NSView {
    private lazy var context = CIContext(options:[.cacheIntermediates:false])
    private var image:CGImage?
    private var startPoint:CGPoint?, startFrame:CGRect = .zero
    private var resizing = false
    var onDrag:((CGRect,Bool)->Void)?
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override init(frame:CGRect) {
        super.init(frame:frame)
        setAccessibilityLabel("Live selfie preview. Drag to move; drag the lower-right handle to resize.")
        toolTip = "Drag to move · Drag the corner to resize"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func clear() { image = nil; needsDisplay = true }
    func update(_ frame:CameraFrame) {
        let source = CIImage(cvPixelBuffer:frame.buffer)
        let targetWidth = max(640,bounds.width*(window?.backingScaleFactor ?? 2))
        let scale = min(1,targetWidth/source.extent.width)
        let mirrored = source.transformed(by:CGAffineTransform(scaleX:-scale,y:scale))
            .transformed(by:CGAffineTransform(translationX:source.extent.width*scale,y:0))
        image = context.createCGImage(mirrored,from:mirrored.extent); needsDisplay = true
    }
    override func draw(_ dirtyRect:NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:12,yRadius:12); path.addClip()
        NSColor.black.setFill(); bounds.fill()
        if let image, let context = NSGraphicsContext.current?.cgContext {
            let scale = max(bounds.width/CGFloat(image.width),bounds.height/CGFloat(image.height))
            let size = CGSize(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
            context.draw(image,in:CGRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height))
        } else {
            ("Starting camera…" as NSString).draw(at:CGPoint(x:10,y:bounds.midY-6),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.65).setStroke(); path.lineWidth = 1; path.stroke()
        let handle = NSBezierPath()
        for offset in [CGFloat(5),9,13] { handle.move(to:CGPoint(x:bounds.maxX-offset,y:4)); handle.line(to:CGPoint(x:bounds.maxX-4,y:offset)) }
        NSColor.white.setStroke(); handle.lineWidth = 1.5; handle.stroke()
    }
    override func mouseDown(with event:NSEvent) {
        guard let window else { return }
        startPoint = window.convertPoint(toScreen:event.locationInWindow); startFrame = window.frame
        let point = convert(event.locationInWindow,from:nil)
        resizing = point.x > bounds.maxX-22 && point.y < bounds.minY+22
    }
    override func mouseDragged(with event:NSEvent) {
        guard let startPoint, let window else { return }
        let point = window.convertPoint(toScreen:event.locationInWindow)
        let dx = point.x-startPoint.x, dy = point.y-startPoint.y
        if resizing {
            let delta = abs(dx) > abs(dy/0.75) ? dx : -dy/0.75
            let width = max(1,startFrame.width+delta)
            onDrag?(CGRect(x:startFrame.minX,y:startFrame.maxY-width*0.75,width:width,height:width*0.75),true)
        } else { onDrag?(startFrame.offsetBy(dx:dx,dy:dy),false) }
    }
    override func mouseUp(with event:NSEvent) { startPoint = nil }
}
