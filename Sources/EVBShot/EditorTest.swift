import AppKit
import ImageIO
import PixelCore

@MainActor
enum EditorTest {
    static func run(folder: URL) async throws {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let width = 640, height = 480
        var rgba = Data(count:width*height*4)
        rgba.withUnsafeMutableBytes { bytes in
            let p = bytes.bindMemory(to:UInt8.self)
            for y in 0..<height { for x in 0..<width { let i = (y*width+x)*4
                p[i] = UInt8(x%127); p[i+1] = UInt8(64+y%127); p[i+2] = 180; p[i+3] = 255
            } }
        }
        let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:CGDataProvider(data:rgba as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let source = folder.appendingPathComponent("original.png")
        try CaptureEngine.writePNG(image,to:source)
        try rgba.write(to:folder.appendingPathComponent("reference.rgba"))
        let original = try Data(contentsOf:source)
        let artifact = CaptureArtifact(url:source,kind:.image,width:width,height:height,hasAudio:false,preview:NSImage(cgImage:image,size:CGSize(width:width,height:height)))
        let controller = ResultController(artifact,editingWorkspace:folder.appendingPathComponent("project"))
        let canvas = controller.canvas!, document = controller.editDocument!
        let toolbarItems = controller.window!.toolbar!.items
        print("EDITOR TOOLBAR \(toolbarItems.map { "\($0.itemIdentifier.rawValue):\(String(describing:$0.view?.frame))" })")
        try SelfTest.check(Set(["tools","style","history","save"]).isSubset(of:Set(toolbarItems.filter { $0.view != nil }.map { $0.itemIdentifier.rawValue })),"annotation, style, history and save toolbar groups exist before display")
        let unedited = try await document.export()
        try SelfTest.check(unedited == source,"unedited export keeps the original file")
        controller.window!.contentView!.layoutSubtreeIfNeeded(); canvas.relayout()
        func drag(_ tool:EditorTool,_ start:CGPoint,_ end:CGPoint) {
            canvas.setTool(tool); canvas.beginGesture(at:canvas.pointInView(start))
            canvas.continueGesture(at:canvas.pointInView(end)); canvas.endGesture(at:canvas.pointInView(end))
        }
        drag(.arrow,CGPoint(x:100,y:100),CGPoint(x:240,y:180))
        drag(.rectangle,CGPoint(x:300,y:100),CGPoint(x:480,y:260))
        canvas.setTool(.text); canvas.beginGesture(at:canvas.pointInView(CGPoint(x:90,y:320))); canvas.commitText("Native pixels")
        try SelfTest.check(document.state.marks.count == 3,"text/arrow/rectangle mouse routes")
        canvas.beginGesture(at:canvas.pointInView(CGPoint(x:100,y:330)),clickCount:2); canvas.commitText("Edited label")
        try SelfTest.check(document.state.marks[2].text == "Edited label","double-click edits existing text")
        document.history.undo()
        canvas.deleteSelection(); try SelfTest.check(document.state.marks.count == 2,"delete selected annotation")
        document.history.undo(); try SelfTest.check(document.state.marks[2].text == "Native pixels","undo restores deleted editable text")
        drag(.select,CGPoint(x:150,y:130),CGPoint(x:180,y:140))
        try SelfTest.check(abs(document.state.marks[0].start.x-130)<0.01,"select and move arrow")
        canvas.setTool(.select); canvas.beginGesture(at:canvas.pointInView(CGPoint(x:330,y:150))); canvas.endGesture(at:canvas.pointInView(CGPoint(x:330,y:150)))
        canvas.beginGesture(at:canvas.pointInView(CGPoint(x:480,y:260))); canvas.endGesture(at:canvas.pointInView(CGPoint(x:520,y:280)))
        try SelfTest.check(abs(document.state.marks[1].end.x-520)<0.01,"resize rectangle handle")
        document.history.undo(); try SelfTest.check(abs(document.state.marks[1].end.x-480)<0.01,"native undo")
        document.history.redo(); try SelfTest.check(abs(document.state.marks[1].end.x-520)<0.01,"native redo")
        drag(.crop,CGPoint(x:50,y:60),CGPoint(x:600,y:430))
        try SelfTest.check(document.state.crop.width == 640,"crop requires explicit Apply")
        canvas.setTool(.select)
        try SelfTest.check(canvas.pendingCrop == nil && document.state.crop.width == 640,"Cancel leaves original crop unchanged")
        drag(.crop,CGPoint(x:50,y:60),CGPoint(x:600,y:430))
        canvas.applyCrop()
        try SelfTest.check(document.state.crop == CGRect(x:50,y:60,width:550,height:370),"crop in native image coordinates")
        document.history.undo(); try SelfTest.check(document.state.crop.width == 640,"undo crop restores full image")
        document.history.redo()
        let exported = try await document.export()
        try CaptureFiles.atomicCopy(from:exported,to:folder.appendingPathComponent("edited.png"))
        let board = NSPasteboard(name:NSPasteboard.Name("com.evb.shot.editor-test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let saved = folder.appendingPathComponent("Saved annotated capture.png")
        try await saveCaptureFile(from:exported,to:saved,copyFilePath:true,pasteboard:board)
        try SelfTest.check(board.string(forType:.string) == saved.path,"edited image saves and copies its full file path")
        let outputSource = CGImageSourceCreateWithURL(exported as CFURL,nil)!
        let decoded = CGImageSourceCreateImageAtIndex(outputSource,0,nil)!
        try SelfTest.check(decoded.width == 550 && decoded.height == 370,"exported crop dimensions")
        let pixels = try PixelFrame(image:decoded)
        func pixel(_ x:Int,_ y:Int) -> [UInt8] { Array(pixels.rgba[((y*550+x)*4)..<((y*550+x)*4+4)]) }
        try SelfTest.check(pixel(250,90)[0] > 200,"native rectangle raster appears at the expected top-left coordinate")
        let baseOffset = ((70*640+60)*4)
        try SelfTest.check(pixel(10,10) == Array(rgba[baseOffset..<baseOffset+4]),"unmarked pixels are unchanged after crop")
        let restored = try ImageEditDocument(source:source,width:width,height:height,workspace:folder.appendingPathComponent("project"))
        try SelfTest.check(restored.state == document.state,"editable objects and crop survive reopening")
        let retained = try Data(contentsOf:source); try SelfTest.check(retained == original,"original file remains byte-identical")
        try await render(controller,name:"editor",folder:folder)
        canvas.setTool(.crop)
        drag(.crop,CGPoint(x:80,y:90),CGPoint(x:560,y:400))
        try await render(controller,name:"crop",folder:folder)
        controller.close()
        print("PASS canvas gestures: text, arrow, rectangle, selection/move, resize handles, crop Apply/Cancel, native undo/redo, editable draft persistence, exact native export coordinates")
        try await longImage(folder:folder)
        try await alphaImage(folder:folder)
        let versioned = folder.appendingPathComponent("versioned.png")
        try CaptureFiles.atomicCopy(from:source,to:versioned)
        let project = folder.appendingPathComponent("version-project")
        let version = try ImageEditDocument(source:versioned,width:width,height:height,workspace:project)
        version.add(ImageMark(kind:.arrow,start:.zero,end:CGPoint(x:50,y:50)))
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:10)],ofItemAtPath:versioned.path)
        let changed = try ImageEditDocument(source:versioned,width:width,height:height,workspace:project)
        try SelfTest.check(!changed.hasEdits,"replacing a source does not reapply stale annotations")
        print("PASS transparent/translucent native pixels, save and copy edited image path, source-version guard")
    }
    static func render(_ controller:ResultController,name:String,folder:URL) async throws {
        guard let view = controller.window?.contentView?.superview else { throw ShotError("Missing editor frame") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ShotError("Cannot render editor frame") }
        view.cacheDisplay(in:view.bounds,to:image)
        guard let png = image.representation(using:.png,properties:[:]) else { throw ShotError("Cannot encode editor frame") }
        try png.write(to:folder.appendingPathComponent("\(name)-content.png"))
    }
    static func alphaImage(folder:URL) async throws {
        let raw = folder.appendingPathComponent("alpha-reference.rgba")
        var bytes = Data()
        for y in 0..<64 { for _ in 0..<64 { bytes.append(contentsOf:[80,90,100,y < 32 ? 0 : 128]) } }
        try bytes.write(to:raw)
        let source = folder.appendingPathComponent("alpha-original.png")
        var message = [CChar](repeating:0,count:512)
        try SelfTest.check(evb_write_png(raw.path,source.path,64,64,&message,message.count)==0,String(cString:message))
        let document = try ImageEditDocument(source:source,width:64,height:64,workspace:folder.appendingPathComponent("alpha-project"))
        document.add(ImageMark(kind:.rectangle,start:CGPoint(x:10,y:10),end:CGPoint(x:50,y:50),color:MarkColor(red:1,green:0,blue:0,alpha:0.5),thickness:4))
        try CaptureFiles.atomicCopy(from:await document.export(),to:folder.appendingPathComponent("alpha-edited.png"))
    }
    static func longImage(folder:URL) async throws {
        let width = 257, height = 70001
        let raw = folder.appendingPathComponent("long-reference.rgba")
        FileManager.default.createFile(atPath:raw.path,contents:nil)
        let handle = try FileHandle(forWritingTo:raw)
        for y in 0..<height {
            var row = Data(count:width*4)
            row.withUnsafeMutableBytes { bytes in
                let p = bytes.bindMemory(to:UInt8.self)
                for x in 0..<width { let i = x*4; p[i]=UInt8(x%127);p[i+1]=UInt8(y%127+64);p[i+2]=180;p[i+3]=255 }
            }
            try handle.write(contentsOf:row)
        }
        try handle.close()
        let source = folder.appendingPathComponent("long-original.png")
        var error = [CChar](repeating:0,count:512)
        try SelfTest.check(evb_write_png(raw.path,source.path,UInt32(width),UInt32(height),&error,error.count)==0,String(cString:error))
        let document = try ImageEditDocument(source:source,width:width,height:height,workspace:folder.appendingPathComponent("long-project"))
        document.add(ImageMark(kind:.rectangle,start:CGPoint(x:30,y:69920),end:CGPoint(x:180,y:69980),thickness:4))
        let native = try await document.export()
        try CaptureFiles.atomicCopy(from:native,to:folder.appendingPathComponent("long-annotated.png"))
        document.crop(CGRect(x:10,y:30,width:220,height:69950))
        let cropped = try await document.export()
        try CaptureFiles.atomicCopy(from:cropped,to:folder.appendingPathComponent("long-cropped.png"))
        let tile = try await document.pixels.tile(CGRect(x:0,y:69900,width:257,height:101),maximum:CGSize(width:257,height:101))
        try SelfTest.check(tile.width == 257 && tile.height == 101,"native tile at bottom of long image")
        print("PASS 257×70001 annotation and 220×69950 crop exports with bounded strips and bottom viewport access; independent PNG pixel check required")
    }
}
