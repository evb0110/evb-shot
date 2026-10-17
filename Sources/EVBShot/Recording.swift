import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreImage

struct RecordingOptions {
    var fps = 30
    var scale: Double = 1
    var microphone = false
    var systemAudio = false
    var camera: AVCaptureDevice?
    var corner: CameraCorner = .bottomRight
    var audioOnly = false
    var cursor = true
}

// AVFoundation's callback API predates Sendable. This immutable payload hands
// retained samples to one writer queue; its cursor is mutated only on that queue.
private final class FixtureFeed: @unchecked Sendable {
    let input: AVAssetWriterInput?
    let samples: [CMSampleBuffer]
    var index = 0
    var done = false
    init(input: AVAssetWriterInput?, samples: [CMSampleBuffer]) { self.input = input; self.samples = samples }
}

// Encoder state and sample callbacks are confined to queue between start and stop.
final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.evb.shot.writer", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var camera: CameraCapture?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var systemAudio: AVAssetWriterInput?
    private var microphone: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var started = false
    private var accepting = true
    private var failure: Error?
    private var startTime = CMTime.invalid
    private var lastVideo = CMTime.invalid
    private var lastAudio: [SCStreamOutputType: CMTime] = [:]
    private var options = RecordingOptions()
    private var pixelSize = CGSize.zero
    private var outputURL: URL?
    var onFailure: ((Error) -> Void)?
    private var frameClock: DispatchSourceTimer?
    private var latestScreen: CVPixelBuffer?
    private var firstHostTime = CMTime.invalid
    private var usesFrameClock = false
    private var fixtureFinished = Set<SCStreamOutputType>()
    private var stoppingTask: Task<CaptureArtifact, Error>?

    func start(surface: CaptureSurface, options: RecordingOptions) async throws {
        self.options = options
        usesFrameClock = !options.audioOnly
        if options.audioOnly && !options.microphone && !options.systemAudio {
            throw ShotError("Choose microphone or system audio for an audio-only recording.")
        }
        if options.microphone {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw ShotError("Microphone access is off. Enable EVBShot in System Settings → Privacy & Security → Microphone.")
            }
        }
        if let device = options.camera, !options.audioOnly {
            let camera = CameraCapture(); self.camera = camera
            camera.onFailure = { [weak self] error in self?.queue.async { self?.fail(error) } }
            do { try await camera.start(device: device) } catch { await camera.stop(); self.camera = nil; throw error }
        }
        do {
            let config = surface.configuration(scale: options.scale, fps: options.fps, cursor: options.cursor)
            config.width = max(2, (config.width + 1) / 2 * 2)
            config.height = max(2, (config.height + 1) / 2 * 2)
            pixelSize = CGSize(width: config.width, height: config.height)
            config.capturesAudio = options.systemAudio
            config.captureMicrophone = options.microphone
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000; config.channelCount = 2
            try prepareWriter(width: config.width, height: config.height)
            if options.audioOnly { config.width = 2; config.height = 2 }
            let stream = SCStream(filter: surface.filter, configuration: config, delegate: self)
            self.stream = stream
            if !options.audioOnly { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) }
            if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            if options.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
            try await stream.startCapture()
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                queue.async {
                    if let failure = self.failure { pending.resume(throwing: failure); return }
                    if self.usesFrameClock { self.startFrameClock() }
                    pending.resume()
                }
            }
        } catch {
            try? await stream?.stopCapture()
            writer?.cancelWriting(); await camera?.stop(); camera = nil
            throw error
        }
    }

    private func prepareWriter(width: Int, height: Int, fixtureFolder: URL? = nil) throws {
        let folder = try fixtureFolder ?? CaptureFiles.newSession()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let needsMix = options.microphone && options.systemAudio
        let m4a = options.audioOnly && !needsMix
        let url = folder.appendingPathComponent(m4a ? "recording.m4a" : "recording.mov")
        outputURL = url
        pixelSize = CGSize(width: width, height: height)
        let writer = try AVAssetWriter(outputURL: url, fileType: m4a ? .m4a : .mov)
        self.writer = writer
        if !options.audioOnly {
            let codec: AVVideoCodecType = width > 4096 || height > 2304 ? .hevc : .h264
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * options.fps / 7), AVVideoExpectedSourceFrameRateKey: options.fps]
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ShotError("This resolution is not supported by the video encoder. Choose a downscaled size.") }
            writer.add(input); video = input
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        }
        if options.systemAudio { systemAudio = try addAudio(to: writer) }
        if options.microphone { microphone = try addAudio(to: writer) }
        guard writer.startWriting() else { throw writer.error ?? ShotError("The media writer could not start.") }
    }

    // Deterministic media validation uses the same encoder and stop/export path.
    func startFixture(width: Int, height: Int, options: RecordingOptions, folder: URL, frameClock: Bool = false) throws {
        self.options = options
        try prepareWriter(width: width, height: height, fixtureFolder: folder)
        writer?.startSession(atSourceTime: .zero); startTime = .zero; started = true
        firstHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        usesFrameClock = frameClock
        if frameClock { queue.async { self.startFrameClock() } }
    }
    func pushFixture(_ sample: CMSampleBuffer) async {
        let feed = FixtureFeed(input: nil, samples: [sample])
        await withCheckedContinuation { pending in
            queue.async { self.consume(feed.samples[0], type: .screen); pending.resume() }
        }
    }
    func feedFixture(_ samples: [CMSampleBuffer], type: SCStreamOutputType) async throws {
        let input = type == .screen ? video : type == .audio ? systemAudio : microphone
        guard let input else { throw ShotError("Fixture input missing") }
        let feed = FixtureFeed(input: input, samples: samples)
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !feed.done, let input = feed.input else { return }
                while input.isReadyForMoreMediaData && feed.index < feed.samples.count {
                    self.consume(feed.samples[feed.index], type: type); feed.index += 1
                    if let error = self.failure { feed.done = true; pending.resume(throwing: error); return }
                }
                if feed.index == feed.samples.count {
                    feed.done = true; input.markAsFinished(); self.fixtureFinished.insert(type); pending.resume()
                }
            }
        }
    }

    private func addAudio(to writer: AVAssetWriter) throws -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ShotError("Cannot add this audio source to the recording.") }
        writer.add(input); return input
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        consume(sampleBuffer, type: type)
    }

    // Also exercised with synthetic CMSampleBuffers without screen/camera permissions.
    func consume(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
        guard accepting, failure == nil, CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample), let writer else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        if !started {
            guard options.audioOnly || type == .screen else { return }
            writer.startSession(atSourceTime: pts); startTime = pts; firstHostTime = CMClockGetTime(CMClockGetHostTimeClock()); started = true
        }
        guard CMTimeCompare(pts, startTime) >= 0 else { return }
        if type == .screen {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            latestScreen = buffer
            if !usesFrameClock { appendVideo(buffer, pts: pts) }
        } else {
            let input = type == .audio ? systemAudio : microphone
            guard let input, input.isReadyForMoreMediaData else { return }
            if let last = lastAudio[type], CMTimeCompare(pts, last) <= 0 { return }
            if input.append(sample) { lastAudio[type] = pts }
            else { fail(writer.error ?? ShotError("The audio encoder could not append a buffer.")) }
        }
    }

    private func startFrameClock() {
        let clock = DispatchSource.makeTimerSource(queue: queue)
        clock.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / options.fps), leeway: .milliseconds(1))
        clock.setEventHandler { [weak self] in self?.emitFrame() }
        frameClock = clock; clock.resume()
    }
    private func emitFrame() {
        guard accepting, failure == nil, started, let buffer = latestScreen else { return }
        let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), firstHostTime)
        appendVideo(buffer, pts: CMTimeAdd(startTime, elapsed))
    }
    private func appendVideo(_ buffer: CVPixelBuffer, pts: CMTime) {
        guard let input = video, input.isReadyForMoreMediaData, let adaptor, let writer else { return }
        guard !lastVideo.isValid || CMTimeCompare(pts, lastVideo) > 0 else { return }
        var final = buffer
        if let cameraBuffer = camera?.frame() {
            guard let pool = adaptor.pixelBufferPool else { fail(ShotError("The video pixel buffer pool is unavailable.")); return }
            var target: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess, let target else {
                fail(ShotError("The video encoder ran out of pixel buffers.")); return
            }
            let image = SelfieCompositor.image(screen: CIImage(cvPixelBuffer: buffer), camera: CIImage(cvPixelBuffer: cameraBuffer), size: pixelSize, corner: options.corner)
            context.render(image, to: target, bounds: CGRect(origin: .zero, size: pixelSize), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            final = target
        }
        if adaptor.append(final, withPresentationTime: pts) { lastVideo = pts }
        else { fail(writer.error ?? ShotError("The video encoder could not append a frame.")) }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        DispatchQueue.main.async { self.onFailure?(error) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.fail(error) } }

    func stop() async throws -> CaptureArtifact {
        // The controller calls this once; cache the task to make repeated Stop idempotent.
        if let stoppingTask { return try await stoppingTask.value }
        let task = Task { try await finalize() }
        stoppingTask = task
        return try await task.value
    }

    private func finalize() async throws -> CaptureArtifact {
        await withCheckedContinuation { pending in
            queue.async { self.frameClock?.cancel(); self.frameClock = nil; pending.resume() }
        }
        var stopError: Error?
        do { try await stream?.stopCapture() } catch { stopError = error }
        await camera?.stop(); camera = nil
        let raw: URL = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.accepting = false
                guard let writer = self.writer, let url = self.outputURL else {
                    continuation.resume(throwing: ShotError("No recording is active.")); return
                }
                guard self.started else {
                    writer.cancelWriting()
                    continuation.resume(throwing: self.failure ?? stopError ?? ShotError("No media frames arrived. Check screen/audio permissions.")); return
                }
                if !self.fixtureFinished.contains(.screen) { self.video?.markAsFinished() }
                if !self.fixtureFinished.contains(.audio) { self.systemAudio?.markAsFinished() }
                if !self.fixtureFinished.contains(.microphone) { self.microphone?.markAsFinished() }
                if self.lastVideo.isValid {
                    let end = CMTimeAdd(self.lastVideo, CMTime(value: 1, timescale: CMTimeScale(self.options.fps)))
                    writer.endSession(atSourceTime: end)
                }
                self.latestScreen = nil
                writer.finishWriting {
                    if writer.status == .completed { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: writer.error ?? self.failure ?? ShotError("The recording could not be finalized. Its draft is preserved.")) }
                }
            }
        }
        let normalized = try await MediaExport.normalized(raw, includeAudio: true)
        let audioTracks = try await AVURLAsset(url: normalized).loadTracks(withMediaType: .audio)
        return CaptureArtifact(url: normalized, kind: options.audioOnly ? .audio : .video,
            width: options.audioOnly ? 0 : Int(pixelSize.width), height: options.audioOnly ? 0 : Int(pixelSize.height),
            hasAudio: !audioTracks.isEmpty, preview: nil,
            notice: failure.map { "Capture was interrupted: \($0.localizedDescription). The available media has been recovered." })
    }
}
