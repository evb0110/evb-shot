import AppKit

@MainActor
final class VideoCropView:NSView {
    var sourceSize:CGSize = .zero { didSet { needsDisplay = true } }
    var selection:CGRect = .zero { didSet { needsDisplay = true; onChange?(selection) } }
    var onChange:((CGRect)->Void)?
    private var anchor:CGPoint = .zero
    private var original:CGRect = .zero
    private var handle:Int? = nil
    private var moving = false
    override var isFlipped:Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    var videoRect:CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let scale = min(bounds.width/sourceSize.width,bounds.height/sourceSize.height)
        let size = CGSize(width:sourceSize.width*scale,height:sourceSize.height*scale)
        return CGRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height)
    }
    private func viewRect(_ rect:CGRect)->CGRect {
        let video = videoRect, scale = video.width/sourceSize.width
        return CGRect(x:video.minX+rect.minX*scale,y:video.minY+rect.minY*scale,width:rect.width*scale,height:rect.height*scale)
    }
    private func pixelPoint(_ event:NSEvent)->CGPoint {
        let point = convert(event.locationInWindow,from:nil), video = videoRect
        return CGPoint(x:min(sourceSize.width,max(0,(point.x-video.minX)*sourceSize.width/video.width)),
                       y:min(sourceSize.height,max(0,(point.y-video.minY)*sourceSize.height/video.height)))
    }
    private func corners(_ rect:CGRect)->[CGPoint] {
        [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY)]
    }
    override func draw(_ dirtyRect:NSRect) {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let rect = viewRect(selection), shade = NSBezierPath(rect:bounds)
        shade.appendRect(rect); shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill(); shade.fill()
        let outline = NSBezierPath(rect:rect); outline.lineWidth = 1.5; NSColor.white.setStroke(); outline.stroke()
        for corner in corners(rect) {
            NSColor.white.setFill(); NSBezierPath(roundedRect:CGRect(x:corner.x-4,y:corner.y-4,width:8,height:8),xRadius:2,yRadius:2).fill()
        }
    }
    override func mouseDown(with event:NSEvent) {
        anchor = pixelPoint(event); original = selection
        let point = convert(event.locationInWindow,from:nil)
        handle = corners(viewRect(selection)).firstIndex { hypot($0.x-point.x,$0.y-point.y)<12 }
        moving = handle == nil && selection.contains(anchor)
        if !moving && handle == nil { selection = CGRect(origin:anchor,size:.zero) }
    }
    override func mouseDragged(with event:NSEvent) {
        let point = pixelPoint(event)
        if moving {
            var rect = original.offsetBy(dx:point.x-anchor.x,dy:point.y-anchor.y)
            rect.origin.x = min(max(0,rect.minX),sourceSize.width-rect.width)
            rect.origin.y = min(max(0,rect.minY),sourceSize.height-rect.height); selection = rect
        } else {
            let origin = handle.map { corners(original)[($0+2)%4] } ?? anchor
            selection = CGRect(x:min(origin.x,point.x),y:min(origin.y,point.y),width:abs(point.x-origin.x),height:abs(point.y-origin.y))
        }
    }
    override func mouseUp(with event:NSEvent) {
        if selection.width < 2 || selection.height < 2 { selection = original }
        else { selection = VideoEdits.pixelCrop(selection,in:sourceSize) }
    }
}
