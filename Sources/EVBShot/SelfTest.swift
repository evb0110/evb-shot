import AppKit
import AVFoundation
import ScreenCaptureKit
import PixelCore
import CoreText

enum SelfTest {
    // A short, silent live smoke. Private desktop pixels are deleted after validation.
    static func captureSmoke(folder: URL) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw ShotError("Enable EVBShot screen capture access in macOS Privacy & Security, then rerun this check.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = CGMainDisplayID()
        let content = try await CaptureEngine.content()
        let full = try CaptureEngine.surface(for: .display(id, nil), content: content)
        let image = try await CaptureEngine.image(full)
        let scale = Double(full.filter.pointPixelScale)
        let expectedWidth = Int((Double(content.displays.first { $0.displayID == id }!.width) * scale).rounded())
        try check(image.width == expectedWidth, "live full-screen native width")
        let area = try CaptureEngine.surface(for: .display(id, CGRect(x: 40, y: 40, width: 321, height: 239)), content: content)
        let crop = try await CaptureEngine.image(area)
        try check(crop.width == Int((321 * scale).rounded()) && crop.height == Int((239 * scale).rounded()), "live area native dimensions")
        let streamFrames = StreamFrameCheck()
        let feed = ScrollFrameFeed(onFrame:{ image in await streamFrames.record(image) },onError:{ error in await streamFrames.failed(error) })
        try await feed.start(area)
        try await Task.sleep(for:.milliseconds(500))
        await feed.stop()
        let streamResult = await streamFrames.result()
        try check(streamResult.0 > 0 && streamResult.1 == crop.width && streamResult.2 == crop.height && streamResult.3 == nil,"live scrolling stream provides exact native area pixels: \(streamResult)")
        print("PASS live scrolling SCStream, \(streamResult.0) native frames at \(streamResult.1)×\(streamResult.2); desktop pixels discarded")
        guard let window = content.windows.first(where: { $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 100 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }) else { throw ShotError("Open a window for the capture smoke test.") }
        let windowSurface = try CaptureEngine.surface(for: .window(window.windowID), content: content)
        let windowImage = try await CaptureEngine.image(windowSurface)
        try check(windowImage.width == windowSurface.width && windowImage.height == windowSurface.height, "live window native dimensions without added shadow")
        var options = RecordingOptions(); options.scale = 0.5; options.fps = 15
        let recording = RecordingSession()
        try await recording.start(surface: full, options: options)
        try await Task.sleep(for: .seconds(2))
        let result = try await recording.stop()
        defer { try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent()) }
        let asset = AVURLAsset(url: result.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        try check(!tracks.isEmpty && duration.seconds > 1.5, "live two-second recording")
        let dimensions = try await tracks[0].load(.naturalSize)
        let fps = try await tracks[0].load(.nominalFrameRate)
        let text = "PASS live ScreenCaptureKit full screen \(image.width)×\(image.height), area \(crop.width)×\(crop.height), window \(windowImage.width)×\(windowImage.height).\nPASS live silent recording \(Int(dimensions.width))×\(Int(dimensions.height)), selected 15 FPS, measured nominal \(fps) FPS, duration \(duration.seconds) seconds.\nDesktop pixels were discarded after validation. Camera and microphone were not activated.\n"
        try text.write(to: folder.appendingPathComponent("live-capture.txt"), atomically: true, encoding: .utf8)
        print(text)
    }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ShotError("Self-test failed: \(message)") }
    }
    static func fixture(width: Int, height: Int, start: Int) throws -> PixelFrame {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                // Spatially unique, opaque rows with a known top-to-bottom order.
                var n = UInt32(truncatingIfNeeded: (y + start) &* 1_664_525 &+ x &* 1_013_904_223)
                n ^= n >> 13; n = n &* 2_246_822_519; n ^= n >> 16
                let i = (y * width + x) * 4
                p[i] = UInt8(truncatingIfNeeded: n); p[i+1] = UInt8(truncatingIfNeeded: n >> 8)
                p[i+2] = UInt8(truncatingIfNeeded: n >> 16); p[i+3] = 255
            } }
        }
        return try PixelFrame(width: width, height: height, rgba: data)
    }
    static func run(folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stitchFolder = folder.appendingPathComponent("stitch")
        try FileManager.default.createDirectory(at: stitchFolder, withIntermediateDirectories: true)
        let stitch = try LongCapture(folder: stitchFolder)
        let first = try fixture(width: 401, height: 512, start: 0)
        _ = try await stitch.append(first)
        _ = try await stitch.append(first)
        _ = try await stitch.append(fixture(width: 401, height: 512, start: 173))
        _ = try await stitch.append(fixture(width: 401, height: 512, start: 394))
        let size = await stitch.dimensions(); try check(size.0 == 401 && size.1 == 906, "stitch dimensions \(size)")
        let expected = try fixture(width: 401, height: 906, start: 0)
        let raw = try Data(contentsOf: stitch.rawURL)
        try check(raw == expected.rgba, "every stitched RGBA byte matches the original atlas")
        try expected.rgba.write(to: folder.appendingPathComponent("stitch-reference.rgba"))
        _ = try await stitch.finish()
        try await textStitch(folder: folder)
        // The format limit, not a 16-bit texture or image-view limit, controls export.
        let tallRaw = folder.appendingPathComponent("tall.rgba")
        FileManager.default.createFile(atPath: tallRaw.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tallRaw)
        let width = 1537, height = 70001
        for y in 0..<height {
            var row = Data(count: width * 4)
            row.withUnsafeMutableBytes { bytes in
                let p = bytes.bindMemory(to: UInt8.self)
                for x in 0..<width { let i = x * 4
                    p[i] = UInt8(truncatingIfNeeded: x); p[i+1] = UInt8(truncatingIfNeeded: y)
                    p[i+2] = UInt8(truncatingIfNeeded: y >> 8); p[i+3] = 255
                }
            }
            try handle.write(contentsOf: row)
        }
        try handle.close()
        var error = [CChar](repeating: 0, count: 512)
        let tallPNG = folder.appendingPathComponent("native-1537x70001.png")
        let result = evb_write_png(tallRaw.path, tallPNG.path, UInt32(width), UInt32(height), &error, error.count)
        try check(result == 0, String(cString: error))
        // Reject non-overlap and preserve the last known-good spool.
        let rejectFolder = folder.appendingPathComponent("reject")
        try FileManager.default.createDirectory(at: rejectFolder, withIntermediateDirectories: true)
        let reject = try LongCapture(folder: rejectFolder)
        _ = try await reject.append(first)
        do { _ = try await reject.append(fixture(width: 401, height: 512, start: 2000)); throw ShotError("Self-test accepted missing overlap") }
        catch ScrollAlignmentError.missing { }
        let rejectedSize = await reject.dimensions(); try check(rejectedSize.1 == 512, "rejected frame changed spool")
        _ = try await reject.append(fixture(width:401,height:512,start:173))
        let recoveredSize = await reject.dimensions(); try check(recoveredSize.1 == 685,"a valid frame resumes from the last good viewport after an animated or missed frame")
        let tile = try fixture(width: 401, height: 19, start: 0)
        func periodic(_ start: Int) throws -> PixelFrame {
            var pixels = Data()
            for row in 0..<512 {
                let offset = ((row + start) % 19) * 401 * 4
                pixels.append(tile.rgba[offset..<offset + 401 * 4])
            }
            return try PixelFrame(width: 401, height: 512, rgba: pixels)
        }
        let ambiguousFolder = folder.appendingPathComponent("ambiguous")
        try FileManager.default.createDirectory(at: ambiguousFolder, withIntermediateDirectories: true)
        let ambiguous = try LongCapture(folder: ambiguousFolder)
        _ = try await ambiguous.append(periodic(0))
        do { _ = try await ambiguous.append(periodic(5)); throw ShotError("Self-test accepted ambiguous overlap") }
        catch ScrollAlignmentError.ambiguous { }
        // Round-trip CGImage conversion must preserve orientation and channels.
        let provider = CGDataProvider(data: first.rgba as CFData)!
        let image = CGImage(width: 401, height: 512, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 401 * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let converted = try PixelFrame(image: image)
        try check(converted.rgba == first.rgba, "CGImage orientation/channel conversion")
        print("PASS native-pixel stitching, rejection, CGImage orientation, and tall PNG encoder")
        try await media(folder: folder)
        try await save(folder: folder)
        try await renderUI(folder: folder, image: image)
        print("PASS all self-tests; independent PNG validation is scripts/verify-png.py")
    }

    static func textStitch(folder: URL) async throws {
        let width = 1000, height = 2400
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 16, nil)
        for row in 0..<110 {
            let text = String(format: "%04d  Native scrolling capture preserves every pixel in this numbered document.", row)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)]))
            context.textPosition = CGPoint(x: 24, y: height - 30 - row * 21); CTLineDraw(line, context)
        }
        let atlas = context.makeImage()!
        let target = folder.appendingPathComponent("text-stitch")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let capture = try LongCapture(folder: target)
        for start in [0, 173, 394] {
            let image = atlas.cropping(to: CGRect(x: 0, y: start, width: width, height: 600))!
            _ = try await capture.append(PixelFrame(image: image))
        }
        let expected = try PixelFrame(image: atlas.cropping(to: CGRect(x: 0, y: 0, width: width, height: 994))!)
        let actual = try Data(contentsOf: capture.rawURL)
        try check(actual == expected.rgba, "numbered text stitch retains every pixel")
        _ = try await capture.finish()
        print("PASS real rendered text: 1000×994, exact native pixels across two scrolls")
    }

    static func videoSample(index: Int, width: Int, height: Int, fps:Int = 30) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw ShotError("Fixture pixel allocation failed") }
        let screen = CIImage(color: CIColor(red: 0.08, green: 0.16 + Double(index) / 200, blue: 0.28)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let selfie = CIImage(color: CIColor(red: 0.9, green: 0.45, blue: 0.14)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))
        let image = SelfieCompositor.image(screen: screen, camera: selfie, size: CGSize(width: width, height: height), corner: .bottomRight)
        CIContext().render(image, to: buffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)), presentationTimeStamp: CMTime(value: Int64(index), timescale: CMTimeScale(fps)), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { throw ShotError("Fixture video sample failed") }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)!
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as CFString).toOpaque(), Unmanaged.passUnretained(NSNumber(value: SCFrameStatus.complete.rawValue)).toOpaque())
        return sample
    }
    static func audioSample(index: Int, frequency: Double) throws -> CMSampleBuffer {
        let count = 1600
        var samples = [Float](repeating: 0, count: count * 2)
        for frame in 0..<count { let value = Float(sin(Double(index * count + frame) * frequency * 2 * .pi / 48000) * 0.2)
            samples[frame * 2] = value; samples[frame * 2 + 1] = value
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: samples.count * 4, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: samples.count * 4, flags: 0, blockBufferOut: &block)
        guard let block else { throw ShotError("Fixture audio block failed") }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: Int64(index * count), timescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?; var bytesPerSample = 8
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &bytesPerSample, sampleBufferOut: &sample)
        guard let sample else { throw ShotError("Fixture audio sample failed") }; return sample
    }
    static func media(folder: URL) async throws {
        var options = RecordingOptions(); options.systemAudio = true; options.microphone = true
        let recording = RecordingSession(); try recording.startFixture(width: 640, height: 360, options: options, folder: folder.appendingPathComponent("media-mixed"))
        let video = try (0..<60).map { try videoSample(index: $0, width: 640, height: 360) }
        let computer = try (0..<60).map { try audioSample(index: $0, frequency: 440) }
        let mic = try (0..<60).map { try audioSample(index: $0, frequency: 880) }
        async let v: Void = recording.feedFixture(video, type: .screen)
        async let a: Void = recording.feedFixture(computer, type: .audio)
        async let m: Void = recording.feedFixture(mic, type: .microphone)
        _ = try await (v, a, m)
        let artifact = try await recording.stop()
        let asset = AVURLAsset(url: artifact.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try check(videoTracks.count == 1 && audioTracks.count == 1, "mixed output has one video and one audio track")
        let size = try await videoTracks[0].load(.naturalSize); try check(size == CGSize(width: 640, height: 360), "video resolution")
        try CaptureFiles.atomicCopy(from: artifact.url, to: folder.appendingPathComponent("selfie-and-mixed-audio.mov"))
        let silent = try await MediaExport.normalized(artifact.url, includeAudio: false)
        let silentTracks = try await AVURLAsset(url: silent).loadTracks(withMediaType: .audio)
        try check(silentTracks.isEmpty, "remove recorded audio")
        try CaptureFiles.atomicCopy(from: silent, to: folder.appendingPathComponent("silent.mov"))
        var audioOptions = RecordingOptions(); audioOptions.audioOnly = true; audioOptions.microphone = true
        let audio = RecordingSession(); try audio.startFixture(width: 2, height: 2, options: audioOptions, folder: folder.appendingPathComponent("media-audio"))
        try await audio.feedFixture(mic, type: .microphone)
        let audioArtifact = try await audio.stop()
        try CaptureFiles.atomicCopy(from: audioArtifact.url, to: folder.appendingPathComponent("audio-only.m4a"))
        audioOptions.systemAudio = true
        let mixedAudio = RecordingSession()
        try mixedAudio.startFixture(width: 2, height: 2, options: audioOptions, folder: folder.appendingPathComponent("media-audio-mix"))
        async let computerOnly: Void = mixedAudio.feedFixture(computer, type: .audio)
        async let micOnly: Void = mixedAudio.feedFixture(mic, type: .microphone)
        _ = try await (computerOnly, micOnly)
        let mixedAudioArtifact = try await mixedAudio.stop()
        try CaptureFiles.atomicCopy(from: mixedAudioArtifact.url, to: folder.appendingPathComponent("audio-only-mixed.m4a"))
        let staticRecording = RecordingSession()
        try staticRecording.startFixture(width: 640, height: 360, options: RecordingOptions(), folder: folder.appendingPathComponent("media-static"), frameClock: true)
        await staticRecording.pushFixture(video[0])
        try await Task.sleep(for: .milliseconds(750))
        let staticArtifact = try await staticRecording.stop()
        let staticAsset = AVURLAsset(url: staticArtifact.url)
        let duration = try await staticAsset.load(.duration)
        try check(duration.seconds > 0.65, "static desktop duration must follow the recording clock")
        try CaptureFiles.atomicCopy(from: staticArtifact.url, to: folder.appendingPathComponent("static-desktop.mov"))
        print("PASS 640×360 at 30 FPS, selfie compositor, two-source audio mix, audio removal, audio-only output")
        var filmOptions = RecordingOptions(); filmOptions.fps = 24
        let film = RecordingSession(); try film.startFixture(width:320,height:180,options:filmOptions,folder:folder.appendingPathComponent("media-24fps"))
        try await film.feedFixture((0..<48).map { try videoSample(index:$0,width:320,height:180,fps:24) },type:.screen)
        let filmArtifact = try await film.stop()
        let filmTracks = try await AVURLAsset(url:filmArtifact.url).loadTracks(withMediaType:.video)
        let filmRate = try await filmTracks[0].load(.nominalFrameRate)
        try check(abs(filmRate-24) < 0.01,"selected 24 FPS is retained in the encoded video")
        try CaptureFiles.atomicCopy(from:filmArtifact.url,to:folder.appendingPathComponent("24-fps.mov"))
        print("PASS 320×180 recording at 24 FPS with 48 native-timestamped frames")
    }
    @MainActor static func save(folder: URL) async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("com.evb.shot.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let source = folder.appendingPathComponent("audio-only.m4a")
        let destination = folder.appendingPathComponent("Saved file with spaces - հայերեն.m4a")
        let quotedDestination = "'\(destination.path)'"
        try await saveCaptureFile(from: source, to: destination, copyFilePath: true, pasteboard: board)
        try check(board.string(forType: .string) == quotedDestination, "clipboard contains the single-quoted full Unicode file path")
        let saved = try Data(contentsOf: destination), original = try Data(contentsOf: source)
        try check(saved == original, "saved bytes")
        var failed = false
        do {
            try await saveCaptureFile(from: source, to: folder.appendingPathComponent("missing-parent/file.m4a"), copyFilePath: true, pasteboard: board)
        } catch { failed = true }
        try check(failed && board.string(forType: .string) == quotedDestination, "failed save must throw and preserve clipboard")
        try await saveCaptureFile(from: source, to: destination, copyFilePath: false, pasteboard: board)
        try check(board.string(forType: .string) == quotedDestination, "save-only preserves clipboard")
        let trickyFolder = folder.appendingPathComponent("Owner's captures",isDirectory:true)
        try FileManager.default.createDirectory(at:trickyFolder,withIntermediateDirectories:true)
        let tricky = trickyFolder.appendingPathComponent("Eugene's $HOME $(echo unsafe); `echo nope` \"clip\" - հայերեն.m4a")
        try await saveCaptureFile(from:source,to:tricky,copyFilePath:true,pasteboard:board)
        let expected = "'\(folder.path)/Owner'\\''s captures/Eugene'\\''s $HOME $(echo unsafe); `echo nope` \"clip\" - հայերեն.m4a'"
        try check(board.string(forType:.string) == expected,"apostrophes are shell-escaped and shell metacharacters remain quoted")
        let clipboardCases = [["path":destination.path,"clipboard":quotedDestination],["path":tricky.path,"clipboard":board.string(forType:.string)!]]
        try JSONSerialization.data(withJSONObject:clipboardCases,options:[.prettyPrinted]).write(to:folder.appendingPathComponent("clipboard-cases.json"))
        print("PASS atomic save, overwrite, full Unicode clipboard path, failed-save clipboard preservation")
        let automatic = folder.appendingPathComponent("automatic-save",isDirectory:true)
        try FileManager.default.createDirectory(at:automatic,withIntermediateDirectories:true)
        let occupied = automatic.appendingPathComponent("same.m4a"), sentinel = Data("existing capture must survive".utf8)
        try sentinel.write(to:occupied)
        let concurrent = try await withThrowingTaskGroup(of:URL.self) { group in
            for _ in 0..<8 { group.addTask { try CaptureFiles.copyToFolder(from:source,folder:automatic,name:"same.m4a") } }
            var urls = [URL](); for try await url in group { urls.append(url) }; return urls
        }
        let preserved = try Data(contentsOf:occupied)
        try check(Set(concurrent).count == 8 && preserved == sentinel,"concurrent same-name saves never replace existing files")
        for url in concurrent { let bytes = try Data(contentsOf:url); try check(bytes == original,"each concurrent save contains the complete source") }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath:automatic.path)
        try check(!leftovers.contains { $0.hasSuffix(".partial") },"successful saves leave no staging files")
        let suite = "com.evb.shot.media-save-test.\(UUID().uuidString)", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let settings = CaptureSaveSettings(defaults:defaults); settings.folder = automatic
        for (filename,kind) in [("audio-only.m4a",MediaKind.audio),("selfie-and-mixed-audio.mov",MediaKind.video)] {
            let controller = ResultController(CaptureArtifact(url:folder.appendingPathComponent(filename),kind:kind,width:640,height:360,hasAudio:true),saveSettings:settings,pasteboard:board)
            guard let url = try await EditorTest.saveAndCheck(controller,copy:true) else { throw ShotError("Media save button produced no file") }
            let asset = AVURLAsset(url:url), audioTracks = try await asset.loadTracks(withMediaType:.audio)
            try check(board.string(forType:.string) == "'\(url.path)'" && !audioTracks.isEmpty,"audio/video button saves playable audio and copies the single-quoted absolute path")
            if kind == .video { let videoTracks = try await asset.loadTracks(withMediaType:.video); try check(!videoTracks.isEmpty,"saved recording retains its video track") }
            controller.close()
        }
        print("PASS exclusive same-name concurrent saves and actual audio/video Save & Copy Path buttons with no dialog")
    }
    @MainActor static func renderUI(folder: URL, image: CGImage) throws {
        let recorder = RecordingController(display: CGMainDisplayID())
        let artifact = CaptureArtifact(url: folder.appendingPathComponent("stitch/scrolling-capture.png"), kind: .image, width: 401, height: 906, hasAudio: false, preview: NSImage(cgImage: image, size: NSSize(width: 401, height: 512)))
        let result = ResultController(artifact, editingWorkspace: folder.appendingPathComponent("editor-draft"))
        for (controller, name) in [(recorder as NSWindowController, "recording-controls.png"), (result as NSWindowController, "save-controls.png")] {
            guard let view = controller.window?.contentView else { throw ShotError("Missing native content view") }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ShotError("Cannot render native UI") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
        }
        print("PASS native UI rendered offscreen")
        try resultLayout(folder: folder.appendingPathComponent("result-layout"))
    }

    @MainActor static func resultLayout(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (width, height) in [(2294, 1741), (3840, 2160), (7680, 1080), (1080, 7680)] {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 0.97, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0.1, green: 0.42, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: height - 160, width: width, height: 160))
            let font = CTFontCreateWithName("Menlo" as CFString, 32, nil)
            for row in 0..<min(80, (height - 210) / 50) {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(row + 1). Native capture preview · \(width) × \(height) pixels", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                context.textPosition = CGPoint(x: 40, y: height - 220 - row * 50); CTLineDraw(line, context)
            }
            let image = context.makeImage()!
            let url = folder.appendingPathComponent("capture-\(width)x\(height).png")
            try CaptureEngine.writePNG(image, to: url)
            let original = try Data(contentsOf: url)
            let artifact = CaptureArtifact(url: url, kind: .image, width: width, height: height, hasAudio: false,
                                           preview: NSImage(cgImage: image, size: NSSize(width: width, height: height)))
            let result = ResultController(artifact, editingWorkspace: folder.appendingPathComponent("editor-\(width)x\(height)"))
            let window = result.window!, view = window.contentView!
            view.layoutSubtreeIfNeeded()
            let frame = window.frame
            print("RESULT \(width)×\(height): window \(frame.width)×\(frame.height) points; content fitting size \(view.fittingSize)")
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("result-\(width)x\(height).png"))
            try check(frame.width <= 900 && frame.height <= 720, "result window grew with \(width)×\(height) capture: \(frame)")
            try check(view.fittingSize.width <= 900, "image forces oversized content when the window opens: \(view.fittingSize)")
            try check(NSScreen.screens.contains { $0.visibleFrame.contains(frame) }, "result window must fit a single screen")
            let saved = folder.appendingPathComponent("saved-\(width)x\(height).png")
            try CaptureFiles.atomicCopy(from: artifact.url, to: saved)
            let copied = try Data(contentsOf: saved)
            try check(copied == original, "preview layout must preserve full-resolution saved bytes")
            result.close()
        }
        print("PASS full-size, 4K, ultra-wide and portrait captures keep a compact window and unchanged saved PNGs")
    }
}

private actor StreamFrameCheck {
    private var count = 0, width = 0, height = 0
    private var error:String?
    func record(_ image:CGImage) { count += 1; width = image.width; height = image.height }
    func failed(_ value:Error) { error = value.localizedDescription }
    func result() -> (Int,Int,Int,String?) { (count,width,height,error) }
}
