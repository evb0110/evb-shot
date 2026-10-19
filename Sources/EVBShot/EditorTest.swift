import AppKit
import AVKit
import ImageIO
import PixelCore

@MainActor
enum EditorTest {
    static func recordingWorkflow(folder:URL) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw ShotError("Recording workflow test requires existing screen capture permission.") }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let recorder = RecordingController(display:CGMainDisplayID(),overlayPresentation:.offscreen,
            permissionAccess:RecordingPermissionAccess(status:{ _ in .denied },request:{ _ in false }))
        let region = CaptureSource.display(CGMainDisplayID(),CGRect(x:80,y:100,width:640,height:360))
        let expected = try await CaptureEngine.surface(for:region)
        if #available(macOS 15.2, *) {
            try SelfTest.check(!expected.filter.includedApplications.contains { $0.processID == ProcessInfo.processInfo.processIdentifier },"ScreenCaptureKit excludes this process, including recording curtains and controls")
        }
        recorder.acceptSelection(region,present:false)
        try SelfTest.check(recorder.selectedSourceIndex == 1,"actual selected recording region highlights Area")
        recorder.window!.setFrameOrigin(CGPoint(x:-20000,y:-20000))
        recorder.showWindow(nil)
        func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(recorder.window!.contentView!)
        controls.compactMap { $0 as? NSPopUpButton }.first(where: { $0.itemTitles.contains("Fit within 1920 × 1080") })?.selectItem(withTitle:"Fit within 1920 × 1080")
        guard let start = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Start Recording" }) else { throw ShotError("Missing Start Recording action") }
        var result:CaptureArtifact?
        recorder.onFinish = { result = $0 }
        let camera = controls.compactMap { $0 as? NSButton }.first { $0.title == "Selfie camera" }!
        try SelfTest.check(camera.state == .off,"camera remains opt-in")
        camera.state = .on
        start.performClick(nil)
        await recorder.preparationTask?.value
        try SelfTest.check(recorder.phase == .configuring && recorder.window!.isVisible && recorder.selectedSourceIndex == 1,"camera denial keeps the selected area and recording setup")
        let without = descendants(recorder.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Record Without Camera" }!
        without.performClick(nil)
        for _ in 0..<100 where !recorder.isRecording { try await Task.sleep(nanoseconds:100_000_000) }
        try SelfTest.check(recorder.isRecording,"Start launches the real screen recorder")
        try SelfTest.check(!recorder.window!.isVisible,"recording setup must disappear when Start is pressed")
        recorder.showWindow(nil)
        try SelfTest.check(!recorder.window!.isVisible,"app switching cannot reopen configuration during recording")
        let boundaries = NSApp.windows.filter { $0.identifier?.rawValue == "RecordingBoundary" }
        try SelfTest.check(boundaries.count == NSScreen.screens.count,"recording retains a frame and outside dimming on every display")
        try SelfTest.check(recorder.recordingOverlay.region == expected.screenRect,"the clear recording region matches the actual native capture geometry")
        try SelfTest.check(boundaries.allSatisfy { $0.isVisible && $0.ignoresMouseEvents && !$0.hidesOnDeactivate && $0.frame.maxX < -10000 },"curtains pass clicks through, survive app switching, and tests remain offscreen")
        try await Task.sleep(nanoseconds:700_000_000)
        guard let overlayControls = recorder.recordingOverlay.controls,
              let stop = descendants(overlayControls.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Stop" }) else { throw ShotError("Recording needs a visible Stop control") }
        stop.performClick(nil)
        try SelfTest.check(recorder.recordingOverlay.panels.isEmpty && recorder.recordingOverlay.controls == nil,"Stop removes every curtain and the control bar immediately")
        for _ in 0..<100 where result == nil { try await Task.sleep(nanoseconds:100_000_000) }
        guard let result else { throw ShotError("Stop must produce the recording without reopening setup") }
        try SelfTest.check(result.width == expected.width && result.height == expected.height && !result.hasAudio,"selected area geometry is retained and audio stays off")
        try SelfTest.check(!recorder.window!.isVisible && !recorder.hasActiveWork,"Stop leaves setup closed")
        defer { try? FileManager.default.removeItem(at:result.url.deletingLastPathComponent()) }
        try await mediaResults(video:result,folder:folder)
        try FileManager.default.copyItem(at:result.url,to:folder.appendingPathComponent("recording.mov"))
        print("PASS denied-camera recovery button starts a real silent area recording, keeps the frame while recording, and Stop opens review")
    }

    static func mediaResults(video:CaptureArtifact,audio:CaptureArtifact? = nil,folder:URL) async throws {
        let suite = "com.evb.shot.media-result-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!, settings = CaptureSaveSettings(defaults:UserDefaults(suiteName:suite)!)
        let board = NSPasteboard(name:NSPasteboard.Name(suite))
        defer { defaults.removePersistentDomain(forName:suite); board.releaseGlobally() }
        settings.folder = folder.appendingPathComponent("media-review-saves")
        func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func action(_ controller:ResultController,_ title:String) throws -> NSButton {
            let views = controller.window!.toolbar!.items.compactMap(\.view).flatMap(descendants)
            guard let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw ShotError("Missing result action: \(title)") }
            return button
        }
        let controller = ResultController(video,saveSettings:settings,pasteboard:board,mutePlayback:true)
        defer { controller.close() }
        let available = NSScreen.underPointer.visibleFrame.insetBy(dx:16,dy:16)
        try SelfTest.check(controller.window!.styleMask.contains(.resizable) && controller.window!.frame.width >= min(900,available.width) && available.contains(controller.window!.frame),"video review is large, resizable, and bounded to one display")
        controller.window!.setFrameOrigin(CGPoint(x:-20000,y:-20000))
        controller.showWindow(nil)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        try SelfTest.check(controller.window!.frame.width <= available.width && controller.window!.frame.height <= available.height,"native player stays within one display after showing")
        await controller.videoTask?.value
        let views = descendants(controller.window!.contentView!)
        guard let poster = views.compactMap({ $0 as? NSImageView }).first(where: { $0.identifier?.rawValue == "RecordingPoster" }) else { throw ShotError("Video review needs a first-frame preview") }
        for _ in 0..<100 where poster.image == nil { try await Task.sleep(nanoseconds:20_000_000) }
        try SelfTest.check(poster.image != nil && !poster.isHidden,"paused preview displays a decoded frame, not a black player")
        try await render(controller,name:"recording-review",folder:folder)
        guard let view = views.compactMap({ $0 as? AVPlayerView }).first else { throw ShotError("Missing native playback controls") }
        guard let play = views.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "VideoPlayback" }) else { throw ShotError("Missing visible preview Play button") }
        play.performClick(nil)
        for _ in 0..<100 where !poster.isHidden { try await Task.sleep(nanoseconds:20_000_000) }
        try SelfTest.check(poster.isHidden,"playing removes the first-frame poster")
        view.player?.pause()
        try SelfTest.check(poster.isHidden,"pausing retains the current video frame")
        if let player = view.player, let item = player.currentItem {
            await player.seek(to:item.duration,toleranceBefore:.zero,toleranceAfter:.zero)
            try action(controller,"Crop Frame").performClick(nil); await controller.videoTask?.value
            try SelfTest.check(controller.videoCropView?.isHidden == false && view.isHidden,"cropping at the end of playback decodes the last available frame")
            try action(controller,"Cancel").performClick(nil); await controller.videoTask?.value
            try SelfTest.check(!view.isHidden && controller.videoEdits == VideoEdits(),"Cancel restores playback without changing the crop or time range")
        }
        if video.hasAudio {
            guard let include = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Include audio" }) else { throw ShotError("Video review must expose Include audio") }
            include.state = .off
        }
        try action(controller,"Save & Copy Path").performClick(nil); await controller.saveTask?.value
        guard let saved = controller.lastSavedURL else { throw ShotError("Video preview must save through its native button") }
        try SelfTest.check(!controller.window!.isVisible && board.string(forType:.string) == "'\(saved.path)'","video save closes and copies its quoted path")
        let audioTracks = try await AVURLAsset(url:saved).loadTracks(withMediaType:.audio)
        try SelfTest.check(audioTracks.isEmpty,"Include audio off produces a silent saved video")
        if let audio {
            let audioController = ResultController(audio,saveSettings:settings,pasteboard:board,mutePlayback:true)
            defer { audioController.close() }
            try SelfTest.check(audioController.window!.frame.width <= 500 && audioController.window!.frame.height <= 280,"audio recording uses a compact playback card")
            audioController.window!.setFrameOrigin(CGPoint(x:-20000,y:-20000))
            audioController.showWindow(nil)
            audioController.window!.contentView!.layoutSubtreeIfNeeded()
            try SelfTest.check(audioController.window!.frame.width <= 500 && audioController.window!.frame.height <= 280,"audio card stays compact after first show")
            guard let play = descendants(audioController.window!.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "AudioPlayback" }) else { throw ShotError("Missing audio Play button") }
            play.performClick(nil)
            for _ in 0..<100 where play.title != "Pause" { try await Task.sleep(nanoseconds:20_000_000) }
            try SelfTest.check(play.title == "Pause","audio Play starts native playback")
            play.performClick(nil)
            for _ in 0..<100 where play.title != "Play" { try await Task.sleep(nanoseconds:20_000_000) }
            try SelfTest.check(play.title == "Play","audio Pause stops native playback")
            try await render(audioController,name:"audio-review",folder:folder)
            board.clearContents(); board.setString("keep clipboard",forType:.string)
            try action(audioController,"Save").performClick(nil); await audioController.saveTask?.value
            try SelfTest.check(audioController.lastSavedURL != nil && !audioController.window!.isVisible && board.string(forType:.string) == "keep clipboard","compact audio Save closes and preserves the clipboard")
        }
        print("PASS large resizable video review, compact audio card, decoded poster, playback, audio removal, and immediate save buttons")
    }

    static func videoEditing(video:CaptureArtifact,folder:URL) async throws {
        let suite = "com.evb.shot.video-edit-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        let settings = CaptureSaveSettings(defaults:defaults)
        defer { defaults.removePersistentDomain(forName:suite) }
        settings.folder = folder.appendingPathComponent("video-edit-saves")
        let board = NSPasteboard(name:NSPasteboard.Name(suite)); defer { board.releaseGlobally() }
        let controller = ResultController(video,saveSettings:settings,pasteboard:board,mutePlayback:true)
        defer { controller.close() }
        controller.window!.setFrameOrigin(CGPoint(x:-20000,y:-20000)); controller.showWindow(nil)
        await controller.videoTask?.value
        func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
        let buttons = controller.window!.toolbar!.items.compactMap(\.view).flatMap(descendants).compactMap { $0 as? NSButton }
        func button(_ title:String)throws->NSButton {
            guard let button = buttons.first(where: { $0.title == title }) else { throw ShotError("Missing video action \(title)") }; return button
        }
        guard let view = controller.videoPlayerView, let item = view.player?.currentItem else { throw ShotError("Missing native video player") }
        for _ in 0..<100 where !view.canBeginTrimming { try await Task.sleep(for:.milliseconds(20)) }
        try SelfTest.check(view.canBeginTrimming,"loaded video supports native QuickTime trimming")
        try button("Trim").performClick(nil)
        try await Task.sleep(for:.milliseconds(150))
        try await render(controller,name:"video-trim",folder:folder)
        let nativeButtons = descendants(view).compactMap { $0 as? NSButton }
        guard let trim = nativeButtons.first(where: { $0.title == "Trim" }) else { throw ShotError("Native trim UI missing confirmation; buttons: \(nativeButtons.map(\.title))") }
        item.reversePlaybackEndTime = CMTime(seconds:0.5,preferredTimescale:60000)
        item.forwardPlaybackEndTime = CMTime(seconds:1.5,preferredTimescale:60000)
        trim.performClick(nil)
        for _ in 0..<100 where !(try button("Crop Frame")).isEnabled { try await Task.sleep(for:.milliseconds(20)) }
        try SelfTest.check(abs(controller.videoEdits.start-0.5)<0.001 && controller.videoEdits.end == 1.5,"native trimming commits its selected range to export")
        let cropButton = try button("Crop Frame")
        try SelfTest.check(cropButton.isEnabled,"AVKit trim completion restores the video editing actions")
        try button("Crop Frame").performClick(nil)
        await controller.videoTask?.value
        guard let crop = controller.videoCropView, !crop.isHidden else { throw ShotError("Crop Frame needs a visible crop overlay") }
        try SelfTest.check(view.isHidden,"crop uses a clean paused frame without AVKit controls or frame analysis overlays")
        func point(_ pixel:CGPoint)->CGPoint {
            let rect = crop.videoRect
            return CGPoint(x:rect.minX+pixel.x*rect.width/crop.sourceSize.width,y:rect.minY+pixel.y*rect.height/crop.sourceSize.height)
        }
        func drag(_ from:CGPoint,_ to:CGPoint) {
            func event(_ type:NSEvent.EventType,_ pixel:CGPoint)->NSEvent {
                NSEvent.mouseEvent(with:type,location:crop.convert(point(pixel),to:nil),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            }
            crop.mouseDown(with:event(.leftMouseDown,from)); crop.mouseDragged(with:event(.leftMouseDragged,to)); crop.mouseUp(with:event(.leftMouseUp,to))
        }
        drag(.zero,CGPoint(x:400,y:200)); drag(CGPoint(x:640,y:360),CGPoint(x:600,y:340))
        try SelfTest.check(crop.selection == CGRect(x:400,y:200,width:200,height:140),"native crop handles map display points to exact original video pixels")
        try await render(controller,name:"video-crop",folder:folder)
        try button("Crop").performClick(nil); await controller.videoTask?.value
        try SelfTest.check(crop.isHidden && view.player?.currentItem?.videoComposition?.renderSize == CGSize(width:200,height:140),"Apply previews the same pixel crop used by export")
        let reset = try button("Reset")
        try SelfTest.check(reset.isEnabled,"applied video edits can be reset")
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        item.add(output)
        let previewTime = CMTime(seconds:0.75,preferredTimescale:60000)
        await view.player!.seek(to:previewTime,toleranceBefore:.zero,toleranceAfter:.zero)
        var preview:CVPixelBuffer?
        for _ in 0..<100 where preview == nil {
            preview = output.copyPixelBuffer(forItemTime:previewTime,itemTimeForDisplay:nil)
            if preview == nil { try await Task.sleep(for:.milliseconds(20)) }
        }
        try SelfTest.check(preview.map { CVPixelBufferGetWidth($0) == 200 && CVPixelBufferGetHeight($0) == 140 } == true,"the native player actually renders the selected crop at its pixel dimensions")
        if let preview, let image = CIContext().createCGImage(CIImage(cvPixelBuffer:preview),from:CGRect(x:0,y:0,width:200,height:140)) {
            let bitmap = NSBitmapImageRep(cgImage:image), pixel = bitmap.colorAt(x:158,y:95)?.usingColorSpace(.deviceRGB)
            try SelfTest.check((pixel?.redComponent ?? 0)>0.75 && (pixel?.blueComponent ?? 1)<0.4,"native player renders the selected source pixels, not just a crop-sized surface")
            try CaptureEngine.writePNG(image,to:folder.appendingPathComponent("native-player-cropped-frame.png"))
        } else { throw ShotError("Native player did not provide a decoded crop frame") }
        item.remove(output)
        try await render(controller,name:"video-cropped-preview",folder:folder)
        try button("Save & Copy Path").performClick(nil); await controller.saveTask?.value
        guard let saved = controller.lastSavedURL else { throw ShotError("Edited video save failed") }
        let asset = AVURLAsset(url:saved), tracks = try await asset.loadTracks(withMediaType:.video)
        let savedSize = try await tracks[0].load(.naturalSize), savedDuration = try await asset.load(.duration)
        try SelfTest.check(savedSize == CGSize(width:200,height:140),"native Save exports the previewed crop")
        try SelfTest.check(abs(savedDuration.seconds-1)<0.05 && !controller.window!.isVisible && board.string(forType:.string) == "'\(saved.path)'","edited Save keeps temporal trim, closes, and copies its quoted full path")
        print("PASS native AVKit trim confirmation, crop handle gestures, matching preview/export, and edited Save & Copy Path")
    }

    static func landingPreview(folder:URL) async throws {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let width = 1440, height = 900
        let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray:0.99,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.translateBy(x:0,y:CGFloat(height)); context.scaleBy(x:1,y:-1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
        func text(_ value:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ weight:NSFont.Weight = .regular,_ color:NSColor = .labelColor) {
            (value as NSString).draw(at:CGPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color])
        }
        text("FIELD NOTES / 018",100,80,20,.medium,.secondaryLabelColor)
        text("A little context goes a long way.",100,160,55,.semibold)
        text("Capture the idea. Point out the detail. Keep the conversation moving.",100,245,25,.regular,.secondaryLabelColor)
        let rows = [("01", "Capture only what matters", "An area, a window, or a whole screen."),("02", "Make the next step obvious", "A short note and an arrow are often enough."),("03", "Share the path and get back to work", "Save in one click. Your original stays on your Mac.")]
        for (index,row) in rows.enumerated() {
            let y = CGFloat(365+index*145)
            NSColor(calibratedWhite:0.91,alpha:1).setFill(); NSBezierPath(rect:CGRect(x:100,y:y-25,width:1240,height:1)).fill()
            text(row.0,105,y,20,.medium,.secondaryLabelColor); text(row.1,180,y,31,.medium); text(row.2,180,y+48,22,.regular,.secondaryLabelColor)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()!, source = folder.appendingPathComponent("sample.png")
        try CaptureEngine.writePNG(image,to:source)
        let artifact = CaptureArtifact(url:source,kind:.image,width:width,height:height,hasAudio:false,preview:NSImage(cgImage:image,size:CGSize(width:width,height:height)))
        let controller = ResultController(artifact,editingWorkspace:folder.appendingPathComponent("edits"))
        let document = controller.editDocument!, canvas = controller.canvas!
        document.add(ImageMark(kind:.rectangle,start:CGPoint(x:168,y:492),end:CGPoint(x:805,y:590),thickness:4))
        document.add(ImageMark(kind:.arrow,start:CGPoint(x:1150,y:430),end:CGPoint(x:838,y:529),thickness:5))
        canvas.setTool(.arrow)
        controller.window!.setFrameOrigin(CGPoint(x:-20000,y:-20000)); controller.window!.contentView!.layoutSubtreeIfNeeded()
        canvas.relayout(); _ = canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds)
        canvas.displayIfNeeded(); await canvas.tileTask?.value; canvas.displayIfNeeded()
        try await render(controller,name:"editor",folder:folder)
        controller.close()
    }
    static func mediaWarning(_ artifact:CaptureArtifact,folder:URL) async throws {
        let suite = "com.evb.shot.warning-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let board = NSPasteboard(name:NSPasteboard.Name(suite)); defer { board.releaseGlobally() }
        let controller = ResultController(artifact,saveSettings:CaptureSaveSettings(defaults:defaults),pasteboard:board,mutePlayback:true)
        defer { controller.close() }
        let window = controller.window!; window.setFrameOrigin(CGPoint(x:-20000,y:-20000)); controller.showWindow(nil)
        window.contentView!.layoutSubtreeIfNeeded()
        let warning = window.contentView!.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "CaptureWarning" }
        try SelfTest.check(warning?.stringValue.lowercased().contains("microphone") == true && (warning?.frame.height ?? 0)>12,"missing microphone has a readable warning in review")
        try SelfTest.check(window.frame.height <= (artifact.kind == .audio ? 280 : NSScreen.underPointer.visibleFrame.height),"warnings preserve bounded media window limits")
        try await renderWindow(window,name:artifact.kind == .audio ? "audio-input-warning" : "microphone-warning",folder:folder)
    }
    static func liveSelfieControls(folder:URL) async throws {
        let region = CGRect(x:-1400,y:200,width:960,height:540)
        let selfie = SelfieOverlay(presentation:.offscreen)
        var changed:SelfiePlacement?
        selfie.onChange = { changed = $0 }
        selfie.show(region:region,placement:.initial(size:CGSize(width:1920,height:1080),corner:.bottomRight))
        defer { selfie.hide() }
        let panel = selfie.panel!, view = panel.contentView!
        try SelfTest.check(view.acceptsFirstMouse(for:nil),"selfie drag/resize accepts the first click while another app is active")
        try SelfTest.check(panel.isVisible && !panel.hidesOnDeactivate && panel.frame.maxX < -10000,"camera has a persistent visible native preview; tests stay offscreen")
        func mouse(_ type:NSEvent.EventType,_ point:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:panel.convertPoint(fromScreen:point),modifierFlags:[],timestamp:0,
                windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        let original = panel.frame, start = CGPoint(x:original.midX,y:original.midY)
        view.mouseDown(with:mouse(.leftMouseDown,start))
        let moved = CGPoint(x:start.x-180,y:start.y+110)
        view.mouseDragged(with:mouse(.leftMouseDragged,moved)); view.mouseUp(with:mouse(.leftMouseUp,moved))
        try SelfTest.check(panel.frame.minX < original.minX-150 && panel.frame.minY > original.minY+90 && changed != nil,"dragging the actual selfie view moves its window and updates encoded placement")
        let beforeResize = panel.frame, handle = CGPoint(x:beforeResize.maxX-8,y:beforeResize.minY+8)
        view.mouseDown(with:mouse(.leftMouseDown,handle))
        let smaller = CGPoint(x:handle.x-60,y:handle.y+45)
        view.mouseDragged(with:mouse(.leftMouseDragged,smaller)); view.mouseUp(with:mouse(.leftMouseUp,smaller))
        try SelfTest.check(panel.frame.width < beforeResize.width-50 && abs(panel.frame.height/panel.frame.width-0.75)<0.001,"native resize handle shrinks the camera and preserves its aspect ratio")
        let placement = changed!, encoded = placement.rect(in:CGSize(width:1920,height:1080))
        let displayed = panel.frame.offsetBy(dx:30000-region.minX,dy:30000-region.minY)
        try SelfTest.check(abs(encoded.minX-displayed.minX*2)<0.001 && abs(encoded.minY-displayed.minY*2)<0.001 && abs(encoded.width-displayed.width*2)<0.001,"preview and encoded selfie match on a negative-origin Retina display")
        let screen = CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:1920,height:1080))
        let camera = CIImage(color:CIColor(red:1,green:0.5,blue:0)).cropped(to:CGRect(x:0,y:0,width:320,height:240))
        let composite = SelfieCompositor.image(screen:screen,camera:camera,size:CGSize(width:1920,height:1080),placement:placement)
        let context = CIContext()
        let frame = try PixelFrame(image:context.createCGImage(composite,from:composite.extent)!)
        let x = Int(encoded.midX), y = 1080-Int(encoded.midY)-1, offset = (y*1920+x)*4
        try SelfTest.check(frame.rgba[offset] > 240 && frame.rgba[offset+1] > 100,"moved and resized placement composites camera pixels at the expected encoded location")
        var buffer:CVPixelBuffer?
        CVPixelBufferCreate(nil,320,240,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer)
        context.render(camera,to:buffer!); selfie.update(CameraFrame(buffer!))
        var deliveries = 0, delivered:CameraFrame?
        let newest = CameraFrame(buffer!)
        await withCheckedContinuation { pending in
            let delivery = CameraPreviewDelivery { frame in
                deliveries += 1; delivered = frame; pending.resume()
            }
            for _ in 0..<100 { delivery.submit(CameraFrame(buffer!)) }
            delivery.submit(newest)
        }
        try SelfTest.check(deliveries == 1 && delivered === newest,"a blocked UI receives only the newest camera frame, without a growing buffer queue")
        try await renderWindow(panel,name:"selfie-preview",folder:folder)
        selfie.setFrame(panel.frame.offsetBy(dx:-10000,dy:10000))
        let clamped = panel.frame.offsetBy(dx:30000,dy:30000)
        try SelfTest.check(region.contains(clamped),"moving camera past a capture edge keeps the whole image inside the recording")
        let overlay = RecordingOverlay(presentation:.offscreen)
        overlay.show(region:region,microphone:MicrophoneDevice(uid:"fixture-system",name:"System USB microphone"))
        defer { overlay.hide() }
        overlay.didStart(); overlay.updateMicrophoneLevel(0.8)
        let row = overlay.controls!.contentView!.subviews.first as! NSStackView
        try SelfTest.check(row.arrangedSubviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("System USB microphone") },"recording bar identifies the selected system microphone")
        try SelfTest.check(abs((row.arrangedSubviews.compactMap { $0 as? NSLevelIndicator }.first?.doubleValue ?? 0)-0.8)<0.001,"recording bar exposes incoming microphone level")
        try await renderWindow(overlay.controls!,name:"microphone-recording-controls",folder:folder)
        let tone = try SelfTest.audioSample(index:0,frequency:880)
        try SelfTest.check(RecordingSession.microphoneLevel(tone) > 0.7,"actual PCM microphone samples drive the meter")
        selfie.hide(); try SelfTest.check(selfie.panel == nil && !panel.isVisible,"Stop removes the selfie preview")
        print("PASS live selfie preview native drag/resize, Retina/negative-origin placement parity, edge clamping, compositor pixels and system microphone meter")
    }
    static func run(folder: URL) async throws {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try await liveSelfieControls(folder:folder)
        try await recordingPermissionRegression(folder:folder)
        try statusIcon(folder:folder)
        try recordingCurtain(folder:folder)
        try await annotationPalette(folder:folder)
        try AppUpdates.verifyLifecycle()
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
        try SelfTest.check(settings.folder == CaptureSaveSettings.defaultFolder, "new installations default to Pictures/EVB Shot")
        let preferences = SettingsController(settings: settings)
        preferences.setSaveFolder(folder.appendingPathComponent("Saved captures - հայերեն",isDirectory:true))
        try SelfTest.check(CaptureSaveSettings(defaults: UserDefaults(suiteName: suite)!).folder == settings.folder, "save folder survives settings reconstruction")
        let updatePreferences = SettingsController(settings:settings,updates:AppUpdates())
        updatePreferences.window!.setFrameOrigin(CGPoint(x:-20000,y:-20000)); updatePreferences.showWindow(nil)
        let updateButtons = updatePreferences.window!.contentView!.subviews.flatMap { view -> [NSView] in
            @MainActor func children(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
            return children(view)
        }.compactMap { $0 as? NSButton }
        try SelfTest.check(updateButtons.contains { $0.title == "Check for Updates…" && !$0.isEnabled },"Settings disables update checks until Sparkle is ready")
        try await renderWindow(updatePreferences.window!,name:"update-settings",folder:folder); updatePreferences.close()
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
        func selectionBluePixels() throws -> Int {
            let bitmap = canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds)!
            canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
            let frame = try PixelFrame(image:bitmap.cgImage!)
            return frame.rgba.withUnsafeBytes { data -> Int in
                let bytes = data.bindMemory(to:UInt8.self)
                return stride(from:0,to:bytes.count,by:4).filter { bytes[$0] < 80 && bytes[$0+1] > 80 && bytes[$0+1] < 210 && bytes[$0+2] > 220 }.count
            }
        }
        let bluePixels = try selectionBluePixels()
        let colorButton = toolbarItems.first { $0.itemIdentifier.rawValue == "style" }!.view!.subviews.compactMap { $0 as? AnnotationColorButton }.first!
        let palette = colorButton.makePalette()
        func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let blueSwatch = descendants(palette.view).compactMap { $0 as? NSButton }.first { $0.toolTip == "Blue" }!
        blueSwatch.performClick(nil)
        try SelfTest.check(document.state.marks[0].color == MarkColor(.systemBlue),"palette selection reaches the editor's selected annotation")
        document.history.undo()
        try SelfTest.check(document.state.marks[0].color == .red,"palette color changes participate in native undo")
        func shortcut(_ redo:Bool, modifiers:NSEvent.ModifierFlags? = nil) -> Bool {
            let flags = modifiers ?? (redo ? [.command,.shift] : [.command])
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:redo ? "Z" : "z",charactersIgnoringModifiers:"z",isARepeat:false,keyCode:6)!
            return controller.window!.performKeyEquivalent(with:event)
        }
        let handledUndo = shortcut(false), undoCount = document.state.marks.count
        let handledRedo = shortcut(true), redoCount = document.state.marks.count
        print("EDITOR REGRESSION arrow blue pixels=\(bluePixels); Cmd-Z handled=\(handledUndo) marks=\(undoCount); Shift-Cmd-Z handled=\(handledRedo) marks=\(redoCount)")
        try SelfTest.check(handledUndo && undoCount == 0 && handledRedo && redoCount == 1,"window key equivalents must undo and redo the arrow")
        try SelfTest.check(bluePixels == 0,"drawing an arrow leaves no blue outlines or endpoint boxes")
        let beforeUnrelated = document.state
        _ = shortcut(false,modifiers:[.command,.option])
        try SelfTest.check(document.state == beforeUnrelated,"other modifier combinations must not invoke undo")
        drag(.rectangle,CGPoint(x:300,y:100),CGPoint(x:480,y:260))
        let rectangleBlue = try selectionBluePixels()
        try SelfTest.check(rectangleBlue == 0,"drawing a rectangle leaves no blue border or corner boxes")
        try await render(controller,name:"drawn-shapes",folder:folder)
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
        canvas.beginGesture(at:canvas.pointInView(CGPoint(x:270,y:190)))
        canvas.endGesture(at:canvas.pointInView(CGPoint(x:290,y:205)))
        try SelfTest.check(document.state.marks[0].end == CGPoint(x:290,y:205),"neutral arrow endpoint remains resizable")
        let selectedArrowBlue = try selectionBluePixels()
        try SelfTest.check(selectedArrowBlue == 0,"selected arrow has neutral handles without blue decorations")
        document.history.undo()
        canvas.setTool(.select); canvas.beginGesture(at:canvas.pointInView(CGPoint(x:330,y:150))); canvas.endGesture(at:canvas.pointInView(CGPoint(x:330,y:150)))
        let selectedRectangleBlue = try selectionBluePixels()
        try SelfTest.check(selectedRectangleBlue == 0,"selected rectangle has neutral handles without a blue bounding box")
        try await render(controller,name:"selected-rectangle",folder:folder)
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
        try SelfTest.check(saved.deletingLastPathComponent() == settings.folder && board.string(forType:.string) == "'\(saved.path)'","edited image saves in the configured folder and copies its full path")
        let buttonOutput = try Data(contentsOf:saved), expectedOutput = try Data(contentsOf:exported)
        try SelfTest.check(buttonOutput == expectedOutput,"button saves the cropped, annotated native export")
        let secondSave = saveController()
        preferences.setSaveFolder(folder.appendingPathComponent("Second save folder",isDirectory:true))
        let second = try await saveAndCheck(secondSave,copy:false)!
        try SelfTest.check(second.deletingLastPathComponent() == settings.folder && second != saved && board.string(forType:.string) == "'\(saved.path)'","Save uses changed settings immediately and preserves the clipboard")
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
        try SelfTest.check(settings.folder.path == CaptureSaveSettings.defaultFolder.path,"Use Default Folder restores Pictures/EVB Shot")
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
        let recorder = RecordingController(display:CGMainDisplayID(),overlayPresentation:.offscreen)
        guard let fps = descendants(recorder.window!.contentView!).compactMap({ $0 as? NSPopUpButton }).first(where:{ $0.itemTitles.contains("24 FPS") }) else { throw ShotError("Recording UI must expose 24 FPS") }
        try SelfTest.check(recorder.selectedFrameRate == 30,"default frame rate remains 30 FPS")
        fps.selectItem(withTitle:"24 FPS"); try SelfTest.check(recorder.selectedFrameRate == 24,"24 FPS popup maps to the recording configuration")
        recorder.acceptSelection(.display(CGMainDisplayID(),CGRect(x:80,y:100,width:640,height:480)),present:false)
        try SelfTest.check(recorder.selectedSourceIndex == 1,"area selection highlights Area, not Screen")
        recorder.acceptSelection(nil,present:false)
        try SelfTest.check(recorder.selectedSourceIndex == 1,"cancelled reselection retains Area")
        recorder.acceptSelection(.window(123),present:false)
        try SelfTest.check(recorder.selectedSourceIndex == 2,"window selection highlights Window")
        recorder.acceptSelection(.display(CGMainDisplayID(),nil),present:false)
        try SelfTest.check(recorder.selectedSourceIndex == 0,"full screen selection highlights Screen")
        try SelfTest.check(recorder.window!.styleMask.contains(.nonactivatingPanel) && !recorder.window!.hidesOnDeactivate,"recording controls float without stealing focus")
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
    static func recordingPermissionRegression(folder:URL) async throws {
        func children(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        for permission in RecordingPermission.allCases {
            var recorder:RecordingController?, access:AVAuthorizationStatus = .notDetermined
            var requests = 0, remainedVisible = false, opened:URL?
            let permissions = RecordingPermissionAccess(status:{ _ in access },request:{ requested in
                requests += 1
                remainedVisible = recorder?.window?.isVisible == true && recorder?.selectedSourceIndex == 1 && NSApp.windows.contains { $0.identifier?.rawValue == "RecordingRegionPreview" && $0.isVisible }
                access = .denied
                return false
            })
            let controller = RecordingController(display:CGMainDisplayID(),overlayPresentation:.offscreen,
                permissionAccess:permissions,openSettings:{ opened = $0 })
            recorder = controller
            controller.acceptSelection(.display(CGMainDisplayID(),CGRect(x:80,y:100,width:640,height:360)))
            let originalOutline = NSApp.windows.first { $0.identifier?.rawValue == "RecordingRegionPreview" && $0.isVisible }!
            let controls = children(controller.window!.contentView!)
            let buttons = controls.compactMap { $0 as? NSButton }
            let input = buttons.first { $0.title == (permission == .camera ? "Selfie camera" : "Microphone") }!
            input.state = .on
            if permission == .microphone { buttons.first { $0.title == "Audio only" }!.state = .on }
            let start = buttons.first { $0.title == "Start Recording" }!
            start.performClick(nil)
            try SelfTest.check(controller.window!.isVisible,"recording controls must stay visible while camera permission is being checked")
            await controller.preparationTask?.value
            try SelfTest.check(remainedVisible && requests == 1,"macOS authorization is requested once with the selected area still visible")
            try SelfTest.check(controller.phase == .configuring && controller.window!.isVisible && controller.selectedSourceIndex == 1,"denial returns to the same setup without losing the selected area")
            let outline = NSApp.windows.first { $0.identifier?.rawValue == "RecordingRegionPreview" && $0.isVisible }
            try SelfTest.check(outline === originalOutline && outline!.frame.maxX < -10000,"permission failure keeps the same selection frame visible; native tests stay offscreen")
            let settings = buttons.first { $0.title == "Open \(permission.rawValue) Settings…" }!
            settings.performClick(nil)
            try SelfTest.check(opened == permission.settingsURL,"recovery button opens the correct macOS privacy category")
            let without = buttons.first { $0.title == "Record Without \(permission.rawValue)" }!
            try SelfTest.check(without.isEnabled == (permission == .camera),"audio-only recording cannot continue without its only audio source")
            if permission == .microphone {
                try SelfTest.check(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("choose Computer audio") },"audio-only recovery explains how to retain a valid audio source")
            }
            start.performClick(nil); await controller.preparationTask?.value
            try SelfTest.check(requests == 1 && controller.window!.isVisible,"retrying a denied permission never re-prompts or hides setup")
            try await renderWindow(controller.window!,name:"\(permission.rawValue.lowercased())-permission",folder:folder)
            controller.close(); recorder = nil
        }
        print("PASS camera/microphone permission preflight keeps setup and region visible, settings actions target the correct category, and denied retries do not blink or re-prompt")
    }
    static func annotationPalette(folder:URL) async throws {
        let palette = AnnotationPaletteController(color:MarkColor.red.nsColor)
        let window = NSWindow(contentRect:CGRect(x:-20000,y:-20000,width:224,height:158),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentViewController = palette
        window.contentView!.layoutSubtreeIfNeeded()
        func children(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        let buttons = children(palette.view).compactMap { $0 as? NSButton }
        let swatches = buttons.filter { $0.toolTip != nil }
        try SelfTest.check(swatches.count == 12 && Set(swatches.compactMap(\.toolTip)).count == 12,"annotation palette contains twelve distinct usable colors, without empty saved-color boxes")
        try SelfTest.check(swatches.first!.state == .on,"the current annotation color is marked")
        try await renderWindow(window,name:"annotation-palette",folder:folder)
        var chosen:NSColor?, more = false
        palette.onPick = { chosen = $0 }; palette.onMore = { more = true }
        swatches.first(where: { $0.toolTip == "Blue" })!.performClick(nil)
        try SelfTest.check(chosen == NSColor.systemBlue,"clicking a swatch selects its real annotation color")
        buttons.first(where: { $0.title == "More Colors…" })!.performClick(nil)
        try SelfTest.check(more,"advanced system colors remain available explicitly")
        for screen in [CGRect(x:0,y:0,width:1920,height:1080),CGRect(x:-2560,y:120,width:2560,height:1440)] {
            for x in [screen.minX+20,screen.midX,screen.maxX-20] {
                let anchor = CGRect(x:x-15,y:screen.maxY-80,width:30,height:26)
                let frame = AnnotationColorButton.customPanelFrame(anchor:anchor,size:CGSize(width:260,height:470),visibleFrame:screen)
                try SelfTest.check(screen.contains(frame) && frame.maxY < anchor.minY && abs(frame.midX-anchor.midX)<140,"optional system picker is anchored beside the editor and clamped to its display")
            }
        }
        window.close()
        print("PASS compact annotation palette actions and anchored custom picker on primary/negative-origin displays")
    }
    static func statusIcon(folder:URL) throws {
        for recording in [false,true] {
            let icon = StatusIcon.image(recording:recording)
            try SelfTest.check(icon.size == CGSize(width:18,height:18) && icon.isTemplate,"menu icon has an 18-point template box with a 16-point symbol")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:36,pixelsHigh:36,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            bitmap.size = icon.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
            NSGraphicsContext.current!.cgContext.clear(CGRect(origin:.zero,size:icon.size))
            icon.draw(in:CGRect(origin:.zero,size:icon.size))
            NSGraphicsContext.restoreGraphicsState()
            let frame = try PixelFrame(image:bitmap.cgImage!)
            var minX = 36, minY = 36, maxX = -1, maxY = -1
            for y in 0..<36 { for x in 0..<36 where frame.rgba[(y*36+x)*4+3] > 32 {
                minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y)
            } }
            try SelfTest.check((28...34).contains(maxX-minX+1) && (28...34).contains(maxY-minY+1),"menu icon stays within 28–34 physical pixels, matching neighboring Retina menu icons")
            try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(recording ? "status-recording.png" : "status-idle.png"))
            print("PASS menu icon recording=\(recording), visible ink=\(maxX-minX+1)×\(maxY-minY+1) Retina pixels")
        }
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
        guard let singleDensityTile = canvas.tileImage else { throw ShotError("Initial native tile must finish rendering") }
        let singleDensityWidth = singleDensityTile.width
        window.density = 2; canvas.viewDidChangeBackingProperties()
        try SelfTest.check(canvas.tileImage == nil,"moving to a Retina display discards the lower-density tile")
        _ = renderCanvas()
        guard let densityRender = canvas.tileTask else { throw ShotError("Retina drawing must request a native tile") }
        canvas.viewDidChangeBackingProperties()
        try SelfTest.check(!densityRender.isCancelled,"duplicate backing-property notifications at the same density must preserve the in-flight native render")
        await densityRender.value
        guard let doubleDensityTile = canvas.tileImage else { throw ShotError("Retina native tile must finish rendering") }
        let doubleDensityWidth = doubleDensityTile.width
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
    static func recordingCurtain(folder:URL) throws {
        let view = RecordingCurtainView(frame:CGRect(x:0,y:0,width:960,height:600))
        view.region = CGRect(x:100,y:100,width:760,height:400)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:960,pixelsHigh:600,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:960*4,bitsPerPixel:32)!
        // Nonzero memory makes a missing clear fail deterministically.
        bitmap.bitmapData!.update(repeating:255,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSGraphicsContext.current!.cgContext.clear(view.bounds); view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try SelfTest.check((bitmap.colorAt(x:20,y:20)?.alphaComponent ?? 0) > 0.35,"curtain darkens outside the recording region")
        try SelfTest.check((bitmap.colorAt(x:480,y:300)?.alphaComponent ?? 1) == 0,"the recording region remains completely clear")
        try SelfTest.check(view.hitTest(CGPoint(x:20,y:20)) == nil && view.hitTest(CGPoint(x:480,y:300)) == nil,"curtain never intercepts input")
        try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("recording-curtain.png"))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor.white.setFill(); NSBezierPath(rect:view.bounds).fill()
        let title = "Native recording overlay · generated test content"
        title.draw(at:CGPoint(x:140,y:440),withAttributes:[.font:NSFont.systemFont(ofSize:22,weight:.semibold),.foregroundColor:NSColor.black])
        for row in 0..<7 {
            NSColor(white:0.87,alpha:1).setFill()
            NSBezierPath(roundedRect:CGRect(x:140,y:CGFloat(385-row*32),width:CGFloat(row%2 == 0 ? 630 : 510),height:10),xRadius:3,yRadius:3).fill()
        }
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("recording-curtain-fixture.png"))
        print("PASS native recording curtain: transparent capture, outside dimming, neutral frame, click through")
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
