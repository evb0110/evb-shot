import AppKit
import ImageIO
import PixelCore

@MainActor
enum EditorTest {
    static func run(folder: URL) async throws {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try await retinaRendering(folder:folder)
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
        let board = NSPasteboard(name:NSPasteboard.Name("com.evb.shot.editor-test.\(UUID().uuidString)"))
        let suite = "com.evb.shot.settings-test.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite) }
        let settings = CaptureSaveSettings(defaults: defaults)
        try SelfTest.check(settings.folder == CaptureSaveSettings.defaultFolder, "new installations default to Pictures/EVBShot")
        let preferences = SettingsController(settings: settings)
        preferences.setSaveFolder(folder.appendingPathComponent("Saved captures - հայերեն",isDirectory:true))
        try SelfTest.check(CaptureSaveSettings(defaults: UserDefaults(suiteName: suite)!).folder == settings.folder, "save folder survives settings reconstruction")
        let controller = ResultController(artifact,editingWorkspace:folder.appendingPathComponent("project"),saveSettings:settings,pasteboard:board)
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
        try await render(controller,name:"selected-arrow",folder:folder)
        let arrowBitmap = canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds)!
        canvas.cacheDisplay(in:canvas.bounds,to:arrowBitmap)
        let arrowPixels = try PixelFrame(image:arrowBitmap.cgImage!)
        let bluePixels = arrowPixels.rgba.withUnsafeBytes { data -> Int in
            let bytes = data.bindMemory(to:UInt8.self)
            return stride(from:0,to:bytes.count,by:4).filter { bytes[$0] < 80 && bytes[$0+1] > 80 && bytes[$0+1] < 210 && bytes[$0+2] > 220 }.count
        }
        func shortcut(_ redo:Bool, modifiers:NSEvent.ModifierFlags? = nil) -> Bool {
            let flags = modifiers ?? (redo ? [.command,.shift] : [.command])
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:redo ? "Z" : "z",charactersIgnoringModifiers:"z",isARepeat:false,keyCode:6)!
            return controller.window!.performKeyEquivalent(with:event)
        }
        let handledUndo = shortcut(false), undoCount = document.state.marks.count
        let handledRedo = shortcut(true), redoCount = document.state.marks.count
        print("EDITOR REGRESSION arrow blue pixels=\(bluePixels); Cmd-Z handled=\(handledUndo) marks=\(undoCount); Shift-Cmd-Z handled=\(handledRedo) marks=\(redoCount)")
        try SelfTest.check(handledUndo && undoCount == 0 && handledRedo && redoCount == 1,"window key equivalents must undo and redo the arrow")
        try SelfTest.check(bluePixels < 400,"selected arrow must have only endpoint handles, no blue bounding box")
        let beforeUnrelated = document.state
        _ = shortcut(false,modifiers:[.command,.option])
        try SelfTest.check(document.state == beforeUnrelated,"other modifier combinations must not invoke undo")
        drag(.rectangle,CGPoint(x:300,y:100),CGPoint(x:480,y:260))
        canvas.setTool(.text); canvas.beginGesture(at:canvas.pointInView(CGPoint(x:90,y:320)))
        guard let fieldEditor = controller.window!.firstResponder as? NSTextView, fieldEditor.isFieldEditor else { throw ShotError("Annotation text must use the native field editor") }
        fieldEditor.insertText("Native pixels",replacementRange:NSRange(location:NSNotFound,length:0))
        _ = shortcut(false)
        try SelfTest.check(fieldEditor.string.isEmpty && document.state.marks.count == 2,"Cmd-Z while typing undoes text, preserving image annotations")
        _ = shortcut(true)
        try SelfTest.check(fieldEditor.string == "Native pixels","Shift-Cmd-Z restores typed text")
        canvas.commitText()
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
        func saveController() -> ResultController {
            ResultController(artifact,editingWorkspace:folder.appendingPathComponent("project"),saveSettings:settings,pasteboard:board)
        }
        let firstSave = saveController()
        let saved = try await saveAndCheck(firstSave,copy:true)!
        try SelfTest.check(saved.deletingLastPathComponent() == settings.folder && board.string(forType:.string) == saved.path,"edited image saves in the configured folder and copies its full path")
        let buttonOutput = try Data(contentsOf:saved), expectedOutput = try Data(contentsOf:exported)
        try SelfTest.check(buttonOutput == expectedOutput,"button saves the cropped, annotated native export")
        let secondSave = saveController()
        preferences.setSaveFolder(folder.appendingPathComponent("Second save folder",isDirectory:true))
        let second = try await saveAndCheck(secondSave,copy:false)!
        try SelfTest.check(second.deletingLastPathComponent() == settings.folder && second != saved && board.string(forType:.string) == saved.path,"Save uses changed settings immediately and preserves the clipboard")
        let third = try await saveAndCheck(saveController(),copy:false)!
        try SelfTest.check(third != second && FileManager.default.fileExists(atPath:second.path),"repeated Save preserves prior captures")
        let sentinel = "clipboard must survive failed Save"
        board.clearContents(); board.setString(sentinel,forType:.string)
        preferences.setSaveFolder(source.appendingPathComponent("not-a-directory"))
        let failedSave = saveController()
        _ = try await saveAndCheck(failedSave,copy:true,expectSuccess:false)
        _ = try await saveAndCheck(failedSave,copy:false,expectSuccess:false)
        try SelfTest.check(failedSave.lastSavedURL == nil && board.string(forType:.string) == sentinel && failedSave.canvas!.editingEnabled,"failed direct save preserves edits and clipboard, then re-enables editing")
        // The same editor must recover from a failed save and dismiss on success.
        preferences.setSaveFolder(saved.deletingLastPathComponent())
        _ = try await saveAndCheck(failedSave,copy:false)
        preferences.setSaveFolder(saved.deletingLastPathComponent())
        try await renderWindow(preferences.window!,name:"save-settings",folder:folder)
        try SelfTest.check(preferences.window!.frame.width == 480,"long save folder paths keep Settings compact")
        let settingsButtons = preferences.window!.contentView!.subviews[0].subviews.compactMap { $0 as? NSStackView }.flatMap { $0.subviews }.compactMap { $0 as? NSButton }
        settingsButtons.first { $0.title == "Use Default Folder" }!.performClick(nil)
        try SelfTest.check(settings.folder.path == CaptureSaveSettings.defaultFolder.path,"Use Default Folder restores Pictures/EVBShot")
        try await renderWindow(preferences.window!,name:"default-save-settings",folder:folder)
        print("PASS actual Save/Save & Copy Path buttons: stable toolbar while saving, close exactly once after success, stay open on failure, persistent folder, native edited pixels and clipboard preservation")
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
        restored.history.undo(); try SelfTest.check(restored.state.crop.width == 640 && restored.state.marks.count == 3,"reopened draft can undo its crop")
        restored.history.undo(); try SelfTest.check(restored.state.marks.count == 2,"reopened draft can undo restored annotations")
        restored.history.redo(); restored.history.redo()
        try SelfTest.check(restored.state == document.state,"reopened draft redo restores exact objects and crop")
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
        let recorder = RecordingController(display:CGMainDisplayID())
        func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let fps = descendants(recorder.window!.contentView!).compactMap({ $0 as? NSPopUpButton }).first(where:{ $0.itemTitles.contains("24 FPS") }) else { throw ShotError("Recording UI must expose 24 FPS") }
        try SelfTest.check(recorder.selectedFrameRate == 30,"default frame rate remains 30 FPS")
        fps.selectItem(withTitle:"24 FPS"); try SelfTest.check(recorder.selectedFrameRate == 24,"24 FPS popup maps to the recording configuration")
        try await renderRecorder(recorder,folder:folder)
        recorder.close()
        let scrollFolder = folder.appendingPathComponent("scroll-panel")
        try FileManager.default.createDirectory(at:scrollFolder,withIntermediateDirectories:true)
        let spool = try LongCapture(folder:scrollFolder)
        let scroll = ScrollController(source:.display(CGMainDisplayID(),CGRect(x:100,y:100,width:600,height:400)),spool:spool) { _ in }
        try SelfTest.check(scroll.window!.hidesOnDeactivate == false && scroll.window!.styleMask.contains(.nonactivatingPanel),"scroll controls remain available without stealing focus")
        let firstFrame = try SelfTest.fixture(width:401,height:512,start:0)
        func cgImage(_ frame:PixelFrame) -> CGImage {
            CGImage(width:frame.width,height:frame.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:frame.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:frame.rgba as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        }
        await scroll.receive(cgImage(firstFrame))
        var flash = firstFrame.rgba
        flash.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to:UInt8.self)
            for y in 30..<190 { for x in 150..<310 where hypot(Double(x-230),Double(y-110)) < 80 {
                let offset = (y*401+x)*4; bytes[offset] = 255; bytes[offset+1] = 50; bytes[offset+2] = 30
            } }
        }
        await scroll.receive(cgImage(try PixelFrame(width:401,height:512,rgba:flash)))
        let afterFlash = await spool.dimensions()
        try SelfTest.check(!scroll.isPaused && afterFlash.1 == 512,"a click highlight or animated frame must not freeze scrolling capture or commit uncertain pixels")
        await scroll.receive(cgImage(try SelfTest.fixture(width:401,height:512,start:173)))
        let recovered = await spool.dimensions()
        let recoveredPixels = try Data(contentsOf:spool.rawURL)
        try SelfTest.check(!scroll.isPaused && recovered.1 == 685,"scrolling automatically continues when a valid overlapping frame arrives")
        let expectedPixels = try SelfTest.fixture(width:401,height:685,start:0).rgba
        try SelfTest.check(recoveredPixels == expectedPixels,"continuous scrolling recovery retains every original native pixel")
        scroll.close()
        print("PASS actual 24 FPS popup mapping, nonactivating scrolling panel, animation rejection followed by automatic pixel-exact scroll recovery through the live frame receiver")
    }
    static func retinaRendering(folder:URL) async throws {
        let width = 4096, height = 512
        var bytes = Data(count:width*height*4)
        bytes.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to:UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let i = (y*width+x)*4, value:UInt8 = x%2 == 0 ? 0 : 255
                p[i] = value; p[i+1] = value; p[i+2] = value; p[i+3] = 255
            } }
        }
        let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let source = folder.appendingPathComponent("retina-stripes.png")
        try CaptureEngine.writePNG(image,to:source)
        let document = try ImageEditDocument(source:source,width:width,height:height,workspace:folder.appendingPathComponent("retina-project"))
        let tile = try await document.pixels.tile(CGRect(x:0,y:0,width:width,height:height),maximum:CGSize(width:width,height:height))
        print("RETINA native viewport requested=4096×512, returned=\(tile.width)×\(tile.height)")
        try SelfTest.check(tile.width == width && tile.height == height,"4K viewport must not be reduced to 2048 pixels")
        let native = try PixelFrame(image:tile)
        try SelfTest.check(native.rgba == bytes,"native viewport preserves every source pixel")
        let portrait = CGImage(width:height,height:width,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:height*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let portraitSource = folder.appendingPathComponent("retina-portrait.png")
        try CaptureEngine.writePNG(portrait,to:portraitSource)
        let portraitDocument = try ImageEditDocument(source:portraitSource,width:height,height:width,workspace:folder.appendingPathComponent("retina-portrait-project"))
        let portraitTile = try await portraitDocument.pixels.tile(CGRect(x:0,y:0,width:height,height:width),maximum:CGSize(width:height,height:width))
        let portraitPixels = try PixelFrame(image:portraitTile)
        try SelfTest.check(portraitTile.height == 4096 && portraitPixels.rgba == bytes,"portrait 4K viewport preserves native resolution and exact pixels")
        let window = DensityTestWindow(contentRect:CGRect(x:0,y:0,width:1500,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame:CGRect(x:0,y:0,width:1500,height:600))
        let canvas = ImageCanvas(document:document,preview:NSImage(cgImage:image,size:CGSize(width:width,height:height)))
        scroll.documentView = canvas; window.contentView = scroll
        window.contentView!.layoutSubtreeIfNeeded(); scroll.tile(); canvas.relayout()
        func renderCanvas() -> NSBitmapImageRep {
            let bitmap = canvas.bitmapImageRepForCachingDisplay(in:canvas.visibleRect)!
            canvas.cacheDisplay(in:canvas.visibleRect,to:bitmap); return bitmap
        }
        _ = renderCanvas(); await canvas.tileTask?.value
        let singleDensityWidth = canvas.tileImage!.width
        window.density = 2; canvas.viewDidChangeBackingProperties()
        try SelfTest.check(canvas.tileImage == nil,"moving to a Retina display discards the lower-density tile")
        _ = renderCanvas(); await canvas.tileTask?.value
        let doubleDensityWidth = canvas.tileImage!.width
        try SelfTest.check(doubleDensityWidth == width && doubleDensityWidth > singleDensityWidth,"Retina Fit uses native 4K pixels instead of magnifying an undersampled tile")
        canvas.setZoom(3)
        try SelfTest.check(abs(canvas.zoom * window.backingScaleFactor - 1) < 0.00001,"100% means one original pixel per display pixel")
        _ = renderCanvas(); await canvas.tileTask?.value
        let bitmap = renderCanvas(), raster = try PixelFrame(image:bitmap.cgImage!)
        let rect = canvas.visibleRect, point = canvas.pointInView(CGPoint(x:200,y:128))
        let scale = Double(bitmap.pixelsWide) / rect.width
        let x = Int(((point.x-rect.minX)*scale).rounded()), y = Int(((point.y-rect.minY)*scale).rounded())
        var contrast = 0
        for offset in 0..<255 {
            let a = ((y*raster.width+x+offset)*4), b = a+4
            contrast += abs(Int(raster.rgba[a])-Int(raster.rgba[b]))
        }
        let meanContrast = Double(contrast)/255
        print("RETINA 1x Fit tile=\(singleDensityWidth), 2x Fit tile=\(doubleDensityWidth), raster scale=\(scale), native stripe contrast=\(meanContrast)")
        try SelfTest.check(abs(scale-2) < 0.001 && meanContrast > 245,"native 2x canvas resolves adjacent black/white source pixels without blur")
        try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("retina-100-percent.png"))
        window.density = 1; canvas.viewDidChangeBackingProperties()
        try SelfTest.check(canvas.zoom == 1 && canvas.tileImage == nil,"100% zoom tracks display-density changes and invalidates the old tile")
        window.close()
        print("PASS 4096-pixel native viewport, Retina cache refinement, physical-pixel 100% zoom and pixel-aligned native canvas")
    }
    static func saveAndCheck(_ controller:ResultController,copy:Bool,expectSuccess:Bool = true) async throws -> URL? {
        let window = controller.window!
        var closed = 0
        controller.onClose = { closed += 1 }
        window.contentView!.superview!.layoutSubtreeIfNeeded()
        let toolbar = window.toolbar!.items
        let buttons = toolbar.first { $0.itemIdentifier.rawValue == "save" }!.view!.subviews.compactMap { $0 as? NSButton }
        let button = buttons.first { $0.title == (copy ? "Save & Copy Path" : "Save") }!
        let swatch = toolbar.first { $0.itemIdentifier.rawValue == "style" }?.view?.subviews.first { $0 is AnnotationColorButton }
        func pixels(_ view:NSView?) throws -> Data? {
            guard let view else { return nil }
            let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            return try PixelFrame(image:bitmap.cgImage!).rgba
        }
        let before = try pixels(swatch)
        button.performClick(nil)
        try SelfTest.check(controller.isSaving && window.attachedSheet == nil,"save starts immediately without a dialog")
        let during = try pixels(swatch)
        await controller.saveTask?.value
        print("SAVE REGRESSION copy=\(copy) success=\(expectSuccess) toolbar pixels stable=\(before == during) close callbacks=\(closed)")
        try SelfTest.check(before == during,"saving must not dim and restore the annotation toolbar")
        try SelfTest.check(closed == (expectSuccess ? 1 : 0),"successful save must close exactly once; failed save must leave the editor open")
        try SelfTest.check(!controller.isSaving,"save lifecycle completes")
        if expectSuccess { try SelfTest.check(controller.lastSavedURL != nil,"successful dismissal follows a completed file save") }
        else { try SelfTest.check(button.isEnabled,"failed saving leaves the editor usable") }
        return controller.lastSavedURL
    }
    static func renderRecorder(_ recorder:RecordingController,folder:URL) async throws {
        let view = recorder.window!.contentView!.superview!
        view.layoutSubtreeIfNeeded(); let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("recording-controls.png"))
    }
    static func render(_ controller:ResultController,name:String,folder:URL) async throws {
        try await renderWindow(controller.window!,name:name,folder:folder)
    }
    static func renderWindow(_ window:NSWindow,name:String,folder:URL) async throws {
        guard let view = window.contentView?.superview else { throw ShotError("Missing window frame") }
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

@MainActor
private final class DensityTestWindow: NSWindow {
    var density: CGFloat = 1
    override var backingScaleFactor: CGFloat { density }
}
