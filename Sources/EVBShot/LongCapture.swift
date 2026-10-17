import Foundation
import CoreGraphics
import PixelCore

struct PixelFrame {
    let width: Int
    let height: Int
    let rgba: Data

    init(width: Int, height: Int, rgba: Data) throws {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { throw ShotError("Invalid pixel frame.") }
        self.width = width; self.height = height; self.rgba = rgba
    }

    init(image: CGImage) throws {
        width = image.width; height = image.height
        var bytes = Data(count: width * height * 4)
        let w = width, h = height
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else { throw ShotError("Could not read the captured pixels.") }
        rgba = bytes
    }
}

enum StitchUpdate {
    case appended(Int)
    case unchanged
}

actor LongCapture {
    let folder: URL
    let rawURL: URL
    private let handle: FileHandle
    private var previous: PixelFrame?
    private(set) var width = 0
    private(set) var height = 0
    private var exported = false
    private var writeFailure: Error?

    init(folder: URL) throws {
        self.folder = folder
        rawURL = folder.appendingPathComponent("native-pixels.rgba")
        guard FileManager.default.createFile(atPath: rawURL.path, contents: nil) else { throw ShotError("Cannot create the scrolling capture spool.") }
        handle = try FileHandle(forWritingTo: rawURL)
    }

    deinit { try? handle.close() }

    func append(_ frame: PixelFrame) throws -> StitchUpdate {
        guard !exported else { throw ShotError("This scrolling capture has already finished.") }
        if let writeFailure { throw writeFailure }
        guard let previous else {
            try write(frame.rgba, committedLength: 0)
            width = frame.width; height = frame.height
            self.previous = frame
            return .appended(height)
        }
        guard previous.width == frame.width, previous.height == frame.height else {
            throw ShotError("The capture dimensions changed. Finish this image and start a new capture.")
        }
        var shift: Int32 = 0, error: Double = 0
        let minimumOverlap = max(16, min(frame.height / 3, 160))
        let result = previous.rgba.withUnsafeBytes { a in
            frame.rgba.withUnsafeBytes { b in
                evb_match_vertical(a.bindMemory(to: UInt8.self).baseAddress, b.bindMemory(to: UInt8.self).baseAddress,
                                   Int32(width), Int32(frame.height), Int32(minimumOverlap), &shift, &error)
            }
        }
        if result == 1 { return .unchanged }
        guard result == 0 else {
            throw ShotError(result == 2
                ? "The overlap is ambiguous. Scroll back to the last captured content, then resume. No uncertain pixels were added."
                : "No matching overlap. Scroll back until the last captured content is visible, then resume. Keep fixed headers and scrollbars outside the area.")
        }
        let newRows = Int(shift)
        guard height <= Int(Int32.max) - newRows else {
            throw ShotError("This image reached the PNG format’s dimension limit. The original pixels remain in the capture spool.")
        }
        let offset = (frame.height - newRows) * width * 4
        try write(frame.rgba[offset...], committedLength: UInt64(width) * UInt64(height) * 4)
        height += newRows
        self.previous = frame
        return .appended(newRows)
    }

    func dimensions() -> (Int, Int) { (width, height) }

    private func write(_ bytes: Data, committedLength: UInt64) throws {
        do { try handle.write(contentsOf: bytes) }
        catch {
            do { try handle.truncate(atOffset: committedLength); try handle.seek(toOffset: committedLength) }
            catch { writeFailure = ShotError("A disk write failed and the spool could not be restored. Free disk space before recovering the draft at \(rawURL.path).") }
            throw writeFailure ?? ShotError("The disk write failed. Previously captured pixels are intact. Free disk space, then resume or finish.")
        }
    }

    func finish() throws -> URL {
        guard width > 0, height > 0 else { throw ShotError("Capture at least one frame before finishing.") }
        try handle.synchronize()
        let output = folder.appendingPathComponent("scrolling-capture.png")
        if exported { return output }
        var message = [CChar](repeating: 0, count: 512)
        let status = rawURL.path.withCString { raw in
            output.path.withCString { png in evb_write_png(raw, png, UInt32(width), UInt32(height), &message, message.count) }
        }
        guard status == 0 else { throw ShotError(String(cString: message)) }
        exported = true
        try handle.close()
        // The completed PNG is durable; release the potentially very large raw spool.
        try? FileManager.default.removeItem(at: rawURL)
        previous = nil
        return output
    }
}
