import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

struct CaptureSurface {
    let filter: SCContentFilter
    let sourceRect: CGRect?
    let width: Int
    let height: Int
    let label: String

    func configuration(scale: Double = 1, fps: Int = 30, cursor: Bool = false) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(2, Int((Double(width) * scale).rounded()))
        config.height = max(2, Int((Double(height) * scale).rounded()))
        config.captureResolution = .best
        config.scalesToFit = false
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        config.ignoreShadowsDisplay = true
        config.shouldBeOpaque = true
        config.showsCursor = cursor
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        if let sourceRect { config.sourceRect = sourceRect }
        return config
    }
}

enum CaptureEngine {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func surface(for source: CaptureSource) async throws -> CaptureSurface {
        try await surface(for: source, content: content())
    }

    static func surface(for source: CaptureSource, content: SCShareableContent) throws -> CaptureSurface {
        switch source {
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ShotError("That window is no longer available. Choose another window.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let rect = filter.contentRect
            let scale = Double(filter.pointPixelScale)
            return CaptureSurface(filter: filter, sourceRect: nil,
                width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded()),
                label: window.title ?? window.owningApplication?.applicationName ?? "Window")
        case let .display(id, selection):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ShotError("That display was disconnected. Select an available display.")
            }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let bounds = CGRect(x: 0, y: 0, width: display.width, height: display.height)
            let region = (selection ?? bounds).intersection(bounds)
            guard region.width >= 2, region.height >= 2 else { throw ShotError("Select an area at least 2 × 2 points.") }
            let scale = Double(filter.pointPixelScale)
            return CaptureSurface(filter: filter, sourceRect: selection == nil ? nil : region,
                width: Int((region.width * scale).rounded()), height: Int((region.height * scale).rounded()),
                label: selection == nil ? "Full screen" : "Selected area")
        }
    }

    static func image(_ surface: CaptureSurface) async throws -> CGImage {
        let image = try await SCScreenshotManager.captureImage(contentFilter: surface.filter, configuration: surface.configuration())
        guard image.width == surface.width, image.height == surface.height else {
            throw ShotError("The display geometry changed during capture. Select the area again; no image was downscaled.")
        }
        return image
    }

    static func screenshot(_ source: CaptureSource) async throws -> CaptureArtifact {
        let surface = try await surface(for: source)
        let image = try await image(surface)
        let folder = try CaptureFiles.newSession()
        let url = folder.appendingPathComponent("capture.png")
        try writePNG(image, to: url)
        return CaptureArtifact(url: url, kind: .image, width: image.width, height: image.height,
                               hasAudio: false, preview: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ShotError("Could not create the PNG file.")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw ShotError("Could not finish writing the PNG. Check available disk space.") }
    }
}
