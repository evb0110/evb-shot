import AppKit
import ScreenCaptureKit
import VideoToolbox

// One native stream and one in-flight frame. Slow stitching never creates a frame backlog.
final class ScrollFrameFeed: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label:"com.evb.shot.scrolling.frames",qos:.userInitiated)
    private var stream: SCStream?
    private var processing: Task<Void,Never>?
    private var active = true
    private var nativeSize = CGSize.zero
    private let onFrame: @Sendable (CGImage) async -> Void
    private let onError: @Sendable (Error) async -> Void
    init(onFrame:@escaping @Sendable (CGImage) async -> Void,onError:@escaping @Sendable (Error) async -> Void) {
        self.onFrame = onFrame; self.onError = onError
    }
    func start(_ surface:CaptureSurface) async throws {
        nativeSize = CGSize(width:surface.width,height:surface.height)
        let config = surface.configuration(fps:15)
        let stream = SCStream(filter:surface.filter,configuration:config,delegate:self)
        self.stream = stream
        try stream.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
        try await stream.startCapture()
    }
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard active, processing == nil, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = sampleBuffer.imageBuffer else { return }
        var image:CGImage?
        let conversion = VTCreateCGImageFromCVPixelBuffer(pixels,options:nil,imageOut:&image)
        guard conversion == noErr, let image else {
            active = false; Task { await onError(ShotError("Cannot read a scrolling frame (\(conversion)). Previously captured pixels are preserved.")) }; return
        }
        guard image.width == Int(nativeSize.width), image.height == Int(nativeSize.height) else {
            active = false
            Task { await onError(ShotError("The capture geometry changed. Finish this image and select the area again. Pixels were not resized.")) }; return
        }
        processing = Task { [self, sampleBuffer] in
            await onFrame(image)
            withExtendedLifetime(sampleBuffer) {} // Keep the IOSurface owned until native pixels have been copied.
            queue.async { self.processing = nil }
        }
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) { Task { await onError(error) } }
    func stop() async {
        let task = queue.sync { active = false; return processing }
        try? await stream?.stopCapture()
        await task?.value
        stream = nil
    }
}
