import AVFoundation

enum MediaExport {
    // Decode/mix audio only. Compressed video samples pass through unchanged.
    static func normalized(_ source: URL, includeAudio: Bool) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        if (includeAudio && audios.count <= 1) || (!includeAudio && audios.isEmpty) { return source }
        guard !videos.isEmpty || includeAudio else { throw ShotError("An audio recording cannot be saved without audio.") }
        let destination = source.deletingLastPathComponent().appendingPathComponent("export-\(UUID().uuidString).\(videos.isEmpty ? "m4a" : "mov")")
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: videos.isEmpty ? .m4a : .mov)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
        if let track = videos.first {
            let formats = try await track.load(.formatDescriptions)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
            input.transform = try await track.load(.preferredTransform)
            guard reader.canAdd(output), writer.canAdd(input) else { throw ShotError("Cannot prepare the video export.") }
            reader.add(output); writer.add(input); pairs.append((output, input))
        }
        if includeAudio, !audios.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audios, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            if audios.count > 1 {
                let mix = AVMutableAudioMix()
                mix.inputParameters = audios.map { track in
                    let p = AVMutableAudioMixInputParameters(track: track)
                    p.setVolume(0.7, at: .zero); return p
                }
                output.audioMix = mix
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
            ])
            guard reader.canAdd(output), writer.canAdd(input) else { throw ShotError("Cannot prepare the audio mix.") }
            reader.add(output); writer.add(input); pairs.append((output, input))
        }
        guard writer.startWriting() else { throw writer.error ?? ShotError("Cannot start exporting.") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? ShotError("Cannot read the recording.") }
        do {
            try await MediaPump(reader: reader, writer: writer, pairs: pairs).run()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

// Mutable export state is confined to queue after run() registers its callbacks.
private final class MediaPump: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]
    let queue = DispatchQueue(label: "com.evb.shot.export")
    var continuation: CheckedContinuation<Void, Error>?
    var remaining: Int
    var ended = Set<Int>()

    init(reader: AVAssetReader, writer: AVAssetWriter, pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]) {
        self.reader = reader; self.writer = writer; self.pairs = pairs; remaining = pairs.count
    }
    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            for (index, pair) in pairs.enumerated() {
                pair.1.requestMediaDataWhenReady(on: queue) { self.pump(index: index) }
            }
        }
    }
    func pump(index: Int) {
        guard continuation != nil, !ended.contains(index) else { return }
        let (output, input) = pairs[index]
        while input.isReadyForMoreMediaData {
            if let sample = output.copyNextSampleBuffer() {
                guard input.append(sample) else { fail(writer.error ?? ShotError("Export could not write a media sample.")); return }
            } else {
                if reader.status == .failed { fail(reader.error ?? ShotError("Export could not read a media sample.")); return }
                input.markAsFinished(); ended.insert(index); remaining -= 1
                if remaining == 0 {
                    writer.finishWriting { self.queue.async {
                        guard let pending = self.continuation else { return }
                        self.continuation = nil
                        if self.writer.status == .completed { pending.resume() }
                        else { pending.resume(throwing: self.writer.error ?? ShotError("Export did not finish. The original draft is preserved.")) }
                    } }
                }
                return
            }
        }
    }
    func fail(_ error: Error) {
        guard let pending = continuation else { return }
        continuation = nil
        reader.cancelReading(); writer.cancelWriting(); pending.resume(throwing: error)
    }
}
