import AppKit
import CoreText
import CryptoKit
import PixelCore

enum MarkKind: String, Codable { case text, arrow, rectangle }
struct MarkColor: Codable, Equatable {
    var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1
    static let red = MarkColor(red: 0.95, green: 0.18, blue: 0.24)
    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) { self.red = red; self.green = green; self.blue = blue; self.alpha = alpha }
    init(_ color: NSColor) { let c = color.usingColorSpace(.sRGB) ?? .systemRed; self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
struct ImageMark: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: MarkKind
    var start: CGPoint
    var end: CGPoint
    var text = ""
    var color = MarkColor.red
    var thickness: CGFloat = 6
    var fontSize: CGFloat = 48
    func moved(_ delta: CGSize) -> ImageMark {
        var result = self
        result.start.x += delta.width; result.start.y += delta.height
        result.end.x += delta.width; result.end.y += delta.height
        return result
    }
}
struct ImageEditState: Codable, Equatable {
    var crop: CGRect // Original native pixels, top-left origin. Crop never moves the marks.
    var marks: [ImageMark] = []
}
private struct SavedImageEdits: Codable {
    var fingerprint: String
    var state: ImageEditState
}

enum MarkRenderer {
    static func textLines(_ mark: ImageMark) -> [CTLine] {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, mark.fontSize, nil)
        return mark.text.components(separatedBy: .newlines).map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): mark.color.cgColor
            ]))
        }
    }
    static func bounds(_ mark: ImageMark) -> CGRect {
        if mark.kind == .text {
            let lines = textLines(mark)
            let width = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
            return CGRect(origin: mark.start, size: CGSize(width: max(20, width), height: CGFloat(max(1, lines.count)) * mark.fontSize * 1.25))
        }
        return CGRect(x: min(mark.start.x, mark.end.x), y: min(mark.start.y, mark.end.y), width: abs(mark.end.x - mark.start.x), height: abs(mark.end.y - mark.start.y))
            .insetBy(dx: -max(mark.thickness, mark.kind == .arrow ? mark.thickness * 4 : 0), dy: -max(mark.thickness, mark.kind == .arrow ? mark.thickness * 4 : 0))
    }
    // Context is in native image coordinates with a top-left origin.
    static func draw(_ mark: ImageMark, in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(mark.color.cgColor); context.setFillColor(mark.color.cgColor)
        context.setLineWidth(mark.thickness); context.setLineCap(.round); context.setLineJoin(.round)
        switch mark.kind {
        case .rectangle:
            context.stroke(CGRect(x: min(mark.start.x, mark.end.x), y: min(mark.start.y, mark.end.y), width: abs(mark.end.x-mark.start.x), height: abs(mark.end.y-mark.start.y)))
        case .arrow:
            let angle = atan2(mark.end.y-mark.start.y, mark.end.x-mark.start.x)
            let length = max(14, mark.thickness * 4)
            context.move(to: mark.start); context.addLine(to: mark.end); context.strokePath()
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                context.move(to: mark.end)
                context.addLine(to: CGPoint(x: mark.end.x - length * cos(angle + offset), y: mark.end.y - length * sin(angle + offset)))
                context.strokePath()
            }
        case .text:
            for (index, line) in textLines(mark).enumerated() {
                var ascent: CGFloat = 0; CTLineGetTypographicBounds(line, &ascent, nil, nil)
                context.saveGState()
                context.translateBy(x: mark.start.x, y: mark.start.y + ascent + CGFloat(index) * mark.fontSize * 1.25)
                context.scaleBy(x: 1, y: -1); context.textPosition = .zero
                CTLineDraw(line, context); context.restoreGState()
            }
        }
    }
}

@MainActor
final class ImageEditDocument {
    let source: URL, width: Int, height: Int, workspace: URL
    let history = UndoManager()
    let pixels: ImagePixelStore
    private(set) var state: ImageEditState
    private let initial: ImageEditState
    private let sidecar: URL
    private let fingerprint: String
    private(set) var persistenceError: Error?
    var onChange: (() -> Void)?

    init(source: URL, width: Int, height: Int, workspace: URL? = nil) throws {
        self.source = source; self.width = width; self.height = height
        let key = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.workspace = workspace ?? CaptureFiles.root.deletingLastPathComponent().appendingPathComponent("Edits/\(key)")
        try FileManager.default.createDirectory(at: self.workspace, withIntermediateDirectories: true)
        sidecar = self.workspace.appendingPathComponent("edits.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        fingerprint = "\(attributes[.size] ?? 0)-\((attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)-\(width)x\(height)"
        initial = ImageEditState(crop: CGRect(x: 0, y: 0, width: width, height: height))
        state = initial
        if let data = try? Data(contentsOf: sidecar), let saved = try? JSONDecoder().decode(SavedImageEdits.self, from: data),
           saved.fingerprint == fingerprint, !saved.state.crop.isEmpty, initial.crop.contains(saved.state.crop) { state = saved.state }
        history.groupsByEvent = false
        pixels = ImagePixelStore(source: source, width: width, height: height, workspace: self.workspace)
        // Reopened editable drafts retain useful undo: each restored object and
        // the final crop can be removed without changing the source bitmap.
        var previous = initial
        for mark in state.marks {
            let snapshot = previous
            history.beginUndoGrouping()
            history.registerUndo(withTarget:self) { $0.change(snapshot,name:"Add annotation") }
            history.setActionName("Add annotation"); history.endUndoGrouping()
            previous.marks.append(mark)
        }
        if state.crop != initial.crop {
            let snapshot = previous
            history.beginUndoGrouping()
            history.registerUndo(withTarget:self) { $0.change(snapshot,name:"Crop") }
            history.setActionName("Crop"); history.endUndoGrouping()
        }
    }
    var hasEdits: Bool { state != initial }
    func change(_ value: ImageEditState, name: String) {
        guard value != state else { return }
        let previous = state
        let grouping = !history.isUndoing && !history.isRedoing
        if grouping { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) { $0.change(previous, name: name) }
        history.setActionName(name)
        if grouping { history.endUndoGrouping() }
        state = value
        do { try JSONEncoder().encode(SavedImageEdits(fingerprint:fingerprint,state:state)).write(to: sidecar, options: .atomic); persistenceError = nil }
        catch { persistenceError = error }
        onChange?()
    }
    func add(_ mark: ImageMark) { var next = state; next.marks.append(mark); change(next, name: "Add \(mark.kind.rawValue)") }
    func replace(_ mark: ImageMark) { var next = state; guard let i = next.marks.firstIndex(where: { $0.id == mark.id }) else { return }; next.marks[i] = mark; change(next, name: "Edit annotation") }
    func remove(_ id: UUID) { var next = state; next.marks.removeAll { $0.id == id }; change(next, name: "Delete annotation") }
    func crop(_ rect: CGRect) {
        let crop = rect.standardized.integral.intersection(state.crop)
        guard crop.width >= 2 && crop.height >= 2 else { return }
        var next = state; next.crop = crop; change(next, name: "Crop")
    }
    func export() async throws -> URL {
        guard hasEdits else { return source }
        return try await pixels.export(state)
    }
}

// Disk-backed original pixels. A viewport or export strip is the largest bitmap.
actor ImagePixelStore {
    let source: URL, width: Int, height: Int, workspace: URL
    private var raw: URL?
    private var cachedExport: (ImageEditState, URL)?
    init(source: URL, width: Int, height: Int, workspace: URL) { self.source = source; self.width = width; self.height = height; self.workspace = workspace }
    deinit { if let raw { try? FileManager.default.removeItem(at: raw) } }
    private func prepare() throws -> URL {
        if let raw { return raw }
        let url = workspace.appendingPathComponent("pixels-\(UUID().uuidString).rgba")
        var w: UInt32 = 0, h: UInt32 = 0, message = [CChar](repeating: 0, count: 512)
        let result = evb_png_to_rgba(source.path, url.path, &w, &h, &message, message.count)
        guard result == 0 else { throw ShotError("Cannot prepare image: \(String(cString: message))") }
        guard Int(w) == width && Int(h) == height else { try? FileManager.default.removeItem(at: url); throw ShotError("The source image changed. Reopen it before editing.") }
        raw = url; return url
    }
    private func read(_ rect: CGRect, handle: FileHandle) throws -> Data {
        let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        var bytes = Data(); bytes.reserveCapacity(w * h * 4)
        for row in 0..<h {
            try handle.seek(toOffset: UInt64(((y + row) * width + x) * 4))
            guard let data = try handle.read(upToCount: w * 4), data.count == w * 4 else { throw ShotError("The image pixel spool is incomplete.") }
            bytes.append(data)
        }
        return bytes
    }
    func tile(_ rect: CGRect, maximum: CGSize) throws -> CGImage {
        try Task.checkCancellation()
        let region = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !region.isEmpty else { throw ShotError("Empty image viewport") }
        let file = try FileHandle(forReadingFrom: prepare()); defer { try? file.close() }
        let w = min(Int(region.width), max(1, Int(ceil(maximum.width)))), h = min(Int(region.height), max(1, Int(ceil(maximum.height))))
        var pixels = Data(count: w * h * 4)
        for row in 0..<h {
            try Task.checkCancellation()
            let sy = Int(region.minY) + min(Int(region.height) - 1, Int((Double(row) + 0.5) * Double(region.height) / Double(h)))
            try file.seek(toOffset: UInt64((sy * width + Int(region.minX)) * 4))
            guard let data = try file.read(upToCount: Int(region.width) * 4), data.count == Int(region.width) * 4 else { throw ShotError("Cannot read image viewport") }
            pixels.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in
                let d = dst.bindMemory(to: UInt8.self), s = src.bindMemory(to: UInt8.self)
                for x in 0..<w {
                    let offset = min(Int(region.width)-1, Int((Double(x)+0.5) * Double(region.width) / Double(w))) * 4
                    for channel in 0..<4 { d[(row*w+x)*4+channel] = s[offset+channel] }
                }
            } }
        }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func export(_ state: ImageEditState) throws -> URL {
        if let cachedExport, cachedExport.0 == state { return cachedExport.1 }
        let file = try FileHandle(forReadingFrom: prepare()); defer { try? file.close() }
        let rawOut = workspace.appendingPathComponent("export-\(UUID().uuidString).rgba")
        let output = workspace.appendingPathComponent("edited-\(UUID().uuidString).png")
        FileManager.default.createFile(atPath: rawOut.path, contents: nil)
        let handle = try FileHandle(forWritingTo: rawOut)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: rawOut) }
        let w = Int(state.crop.width), h = Int(state.crop.height)
        let stripRows = max(1, min(256, 8_388_608 / max(1, w * 4)))
        for row in stride(from: 0, to: h, by: stripRows) {
            let count = min(stripRows, h - row)
            let strip = CGRect(x: state.crop.minX, y: state.crop.minY + CGFloat(row), width: CGFloat(w), height: CGFloat(count))
            var bytes = try read(strip, handle: file)
            let marks = state.marks.filter { MarkRenderer.bounds($0).intersects(strip) }
            if !marks.isEmpty {
                var overlay = Data(count: w * count * 4)
                try overlay.withUnsafeMutableBytes { buffer in
                    guard let context = CGContext(data: buffer.baseAddress, width: w, height: count, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ShotError("Cannot render an annotation strip") }
                    context.translateBy(x: -strip.minX, y: CGFloat(count) + strip.minY); context.scaleBy(x: 1, y: -1)
                    marks.forEach { MarkRenderer.draw($0, in: context) }; context.flush()
                }
                bytes.withUnsafeMutableBytes { dst in overlay.withUnsafeBytes { src in
                    let d = dst.bindMemory(to: UInt8.self), s = src.bindMemory(to: UInt8.self)
                    for p in stride(from: 0, to: d.count, by: 4) {
                        let a = Double(s[p+3]) / 255
                        if a == 0 { continue }
                        let b = Double(d[p+3]) / 255, alpha = a + b * (1-a)
                        for c in 0..<3 { d[p+c] = UInt8(clamping: Int(((Double(s[p+c]) + Double(d[p+c]) * b * (1-a)) / alpha).rounded())) }
                        d[p+3] = UInt8(clamping: Int((alpha * 255).rounded()))
                    }
                } }
            }
            try handle.write(contentsOf: bytes)
        }
        try handle.synchronize(); try handle.close()
        var message = [CChar](repeating: 0, count: 512)
        guard evb_write_png(rawOut.path, output.path, UInt32(w), UInt32(h), &message, message.count) == 0 else { throw ShotError(String(cString: message)) }
        if let cachedExport { try? FileManager.default.removeItem(at: cachedExport.1) }
        cachedExport = (state, output); return output
    }
}
