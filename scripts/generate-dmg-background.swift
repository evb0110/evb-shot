// Same geometry and colors as EVB Viewer. The two representations are combined
// into a Retina TIFF by dmgbuild; all coordinates below are logical points.
import AppKit

let folder = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for scale in [1,2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:600*scale,pixelsHigh:450*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    bitmap.size = CGSize(width:600,height:450)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    let context = NSGraphicsContext.current!.cgContext
    // NSGraphicsContext already applies pixelsWide / bitmap.size.width.
    context.translateBy(x:0,y:450); context.scaleBy(x:1,y:-1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
    let top = NSColor(srgbRed:234/255,green:238/255,blue:244/255,alpha:1)
    let bottom = NSColor(srgbRed:213/255,green:219/255,blue:228/255,alpha:1)
    NSGradient(starting:top,ending:bottom)!.draw(in:CGRect(x:0,y:0,width:600,height:450),angle:90)
    let title = "EVB Shot" as NSString
    let titleAttributes:[NSAttributedString.Key:Any] = [.font:NSFont(name:"HelveticaNeue-Medium",size:26)!, .foregroundColor:NSColor(srgbRed:30/255,green:58/255,blue:95/255,alpha:1)]
    let titleSize = title.size(withAttributes:titleAttributes)
    title.draw(at:CGPoint(x:(600-titleSize.width)/2,y:62-titleSize.height/2),withAttributes:titleAttributes)
    let blue = NSColor(srgbRed:59/255,green:130/255,blue:246/255,alpha:1)
    blue.setStroke(); blue.setFill()
    let shaft = NSBezierPath(); shaft.lineWidth = 11; shaft.lineCapStyle = .round
    shaft.move(to:CGPoint(x:250,y:185)); shaft.line(to:CGPoint(x:332,y:185)); shaft.stroke()
    let head = NSBezierPath(); head.move(to:CGPoint(x:352,y:185)); head.line(to:CGPoint(x:326,y:168)); head.line(to:CGPoint(x:326,y:202)); head.close(); head.fill()
    let help = "Drag EVB Shot to Applications" as NSString
    let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:15), .foregroundColor:NSColor(srgbRed:70/255,green:85/255,blue:108/255,alpha:1)]
    let size = help.size(withAttributes:attributes)
    help.draw(at:CGPoint(x:(600-size.width)/2,y:335),withAttributes:attributes)
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name))
}
