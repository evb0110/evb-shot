import AVFoundation

struct VideoEdits: Equatable {
    var start: Double = 0
    var end: Double? = nil
    // Pixel coordinates in the displayed frame, measured from its top left.
    var crop: CGRect? = nil

    func timeRange(duration: CMTime) throws -> CMTimeRange {
        let finish = end ?? duration.seconds
        guard start.isFinite, finish.isFinite, start >= 0, finish > start,
              finish <= duration.seconds + 0.001 else { throw ShotError("Choose a valid start and end time.") }
        return CMTimeRange(start:CMTime(seconds:start,preferredTimescale:60000),
                           end:CMTime(seconds:min(finish,duration.seconds),preferredTimescale:60000))
    }
    static func pixelCrop(_ rect:CGRect, in size:CGSize) -> CGRect {
        let bounds = CGRect(origin:.zero,size:size)
        let clipped = rect.standardized.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return bounds }
        let x = max(0,floor(clipped.minX)), y = max(0,floor(clipped.minY))
        return CGRect(x:x,y:y,width:floor(clipped.width/2)*2,height:floor(clipped.height/2)*2)
    }
}

enum VideoEditing {
    static func composition(asset:AVAsset, crop:CGRect) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw ShotError("This file has no video.") }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin:.zero,size:natural).applying(transform)
        let frame = VideoEdits.pixelCrop(crop,in:oriented.size)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack:track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX:-oriented.minX-frame.minX,y:-oriented.minY-frame.minY)),at:.zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start:.zero,duration:try await asset.load(.duration)); instruction.layerInstructions = [layer]
        let result = AVMutableVideoComposition(); result.renderSize = frame.size; result.instructions = [instruction]
        let frameDuration = try await track.load(.minFrameDuration), fps = try await track.load(.nominalFrameRate)
        result.frameDuration = frameDuration.isNumeric && frameDuration.seconds > 0 ? frameDuration : CMTime(seconds:1/Double(max(1,fps)),preferredTimescale:60000)
        return result
    }

    static func export(_ source:URL, edits:VideoEdits, includeAudio:Bool) async throws -> URL {
        if edits == VideoEdits() { return try await MediaExport.normalized(source,includeAudio:includeAudio) }
        let asset = AVURLAsset(url:source), duration = try await asset.load(.duration)
        let range = try edits.timeRange(duration:duration)
        let composition = AVMutableComposition()
        let videos = try await asset.loadTracks(withMediaType:.video)
        let audios = includeAudio ? try await asset.loadTracks(withMediaType:.audio) : []
        for track in videos + audios {
            guard let output = composition.addMutableTrack(withMediaType:track.mediaType,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw ShotError("Cannot prepare the edited recording.") }
            let available = try await track.load(.timeRange).intersection(range)
            if available.duration > .zero {
                try output.insertTimeRange(available,of:track,at:available.start-range.start)
                if track.mediaType == .video { output.preferredTransform = try await track.load(.preferredTransform) }
            }
        }
        let videoComposition:AVVideoComposition?
        if let crop = edits.crop { videoComposition = try await self.composition(asset:composition,crop:crop) }
        else { videoComposition = nil }
        let large = (videoComposition?.renderSize.width ?? 0) > 4096 || (videoComposition?.renderSize.height ?? 0) > 2304
        let preset = videoComposition == nil ? AVAssetExportPresetPassthrough : large ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset:composition,presetName:preset) else { throw ShotError("Cannot export the edited recording.") }
        session.videoComposition = videoComposition
        let destination = source.deletingLastPathComponent().appendingPathComponent("export-\(UUID().uuidString).mov")
        do {
            try await session.export(to:destination,as:.mov)
            if let expected = videoComposition?.renderSize {
                guard let track = try await AVURLAsset(url:destination).loadTracks(withMediaType:.video).first,
                      try await track.load(.naturalSize) == expected else { throw ShotError("The video encoder could not preserve the selected crop resolution. Your original is unchanged.") }
            }
            return destination
        } catch { try? FileManager.default.removeItem(at:destination); throw error }
    }
}
