import AppKit
import AVFoundation
import CoreImage

enum CameraCorner: String, CaseIterable {
    case bottomRight = "Bottom right", bottomLeft = "Bottom left", topRight = "Top right", topLeft = "Top left"
}

struct SelfieCompositor {
    static func image(screen: CIImage, camera: CIImage, size: CGSize, corner: CameraCorner) -> CIImage {
        image(screen:screen,camera:camera,size:size,placement:.initial(size:size,corner:corner))
    }
    static func image(screen:CIImage,camera:CIImage,size:CGSize,placement:SelfiePlacement) -> CIImage {
        let rect = placement.rect(in:size), width = rect.width, height = rect.height
        let extent = camera.extent
        let mirrored = camera.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: extent.width, y: 0))
        let scale = max(width / extent.width, height / extent.height)
        let tile = mirrored.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.midX - extent.width * scale / 2,
                                             y: rect.midY - extent.height * scale / 2))
            .cropped(to: rect)
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": width * 0.08,
            "inputColor": CIColor.white
        ])!.outputImage!
        return tile.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: screen, kCIInputMaskImageKey: mask])
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}

// Session and continuations belong to queue; latest frame is protected by lock.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.evb.shot.camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var firstFrame: CheckedContinuation<Void, Error>?
    private var observer: NSObjectProtocol?
    var onFailure: ((Error) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?

    func start(device: AVCaptureDevice) async throws {
        let deviceID = device.uniqueID
        try await RecordingPermissionAccess().authorize(.camera)
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .high
                    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
                    guard let selected = devices.first(where: { $0.uniqueID == deviceID }) else { throw ShotError("The selected camera was disconnected.") }
                    let input = try AVCaptureDeviceInput(device: selected)
                    guard self.session.canAddInput(input) else { throw ShotError("This camera is not available.") }
                    self.session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    guard self.session.canAddOutput(output) else { throw ShotError("Cannot receive video from this camera.") }
                    self.session.addOutput(output)
                    self.session.commitConfiguration()
                    self.firstFrame = continuation
                    self.observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: self.session, queue: nil) { [weak self] notification in
                        self?.queue.async { self?.fail(notification.userInfo?[AVCaptureSessionErrorKey] as? Error ?? ShotError("Camera stopped unexpectedly.")) }
                    }
                    self.session.startRunning()
                    if !self.session.isRunning { self.fail(ShotError("The camera could not start.")) }
                    self.queue.asyncAfter(deadline: .now() + 10) {
                        if self.firstFrame != nil { self.fail(ShotError("The camera started but did not deliver a frame. Check the camera connection and try again.")) }
                    }
                } catch {
                    self.session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func fail(_ error: Error) {
        let pending = firstFrame; firstFrame = nil; pending?.resume(throwing: error)
        if pending == nil { onFailure?(error) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = image; lock.unlock()
        onFrame?(CameraFrame(image))
        let pending = firstFrame; firstFrame = nil; pending?.resume()
    }
    func frame() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return latest }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.session.stopRunning()
                let pending = self.firstFrame; self.firstFrame = nil
                pending?.resume(throwing: ShotError("Camera preparation was cancelled."))
                if let observer = self.observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
                self.lock.lock(); self.latest = nil; self.lock.unlock()
                continuation.resume()
            }
        }
    }
}
