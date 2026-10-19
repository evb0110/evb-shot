import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import Darwin

struct ShotError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum CaptureSource {
    case display(CGDirectDisplayID, CGRect?) // Rectangle in display-local, top-left points.
    case window(CGWindowID)
}

enum MediaKind { case image, video, audio }
enum CaptureCopyMode { case none, filePath, media }

struct CaptureArtifact {
    let url: URL
    let kind: MediaKind
    let width: Int
    let height: Int
    let hasAudio: Bool
    var preview: NSImage?
    var notice: String? = nil
    var detail: String {
        switch kind {
        case .image: return "\(width.formatted()) × \(height.formatted()) pixels · lossless PNG"
        case .video: return "\(width.formatted()) × \(height.formatted()) pixels · \(hasAudio ? "audio included" : "silent")"
        case .audio: return "Audio recording · AAC"
        }
    }
}

enum CaptureFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EVBShot/Drafts", isDirectory: true)
    }
    static func newSession() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func suggestedName(_ kind: MediaKind) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let ext = kind == .image ? "png" : kind == .video ? "mov" : "m4a"
        return "EVB Shot \(formatter.string(from: Date())).\(ext)"
    }
    static func atomicCopy(from source: URL, to destination: URL) throws {
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".evbshot-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: source, to: stage)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage)
        } else {
            try FileManager.default.moveItem(at: stage, to: destination)
        }
    }
    static func copyToFolder(from source: URL, folder: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stage = folder.appendingPathComponent(".evbshot-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: source, to: stage)
        let filename = URL(fileURLWithPath: name)
        var number = 1
        while true {
            let candidate = number == 1 ? name : "\(filename.deletingPathExtension().lastPathComponent) (\(number)).\(filename.pathExtension)"
            let destination = folder.appendingPathComponent(candidate)
            // Publish the completed copy without ever replacing an existing capture,
            // including when two editors save in the same second.
            if renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            let code = errno
            guard code == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: destination.path]) }
            number += 1
        }
    }
}

struct CaptureSaveSettings {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Keep an existing installation's default save location through the display-name change.
        let legacyFolder = Self.defaultFolder.deletingLastPathComponent().appendingPathComponent("EVBShot", isDirectory: true)
        if defaults === UserDefaults.standard, defaults.url(forKey: "saveFolder") == nil,
           FileManager.default.fileExists(atPath: legacyFolder.path) {
            defaults.set(legacyFolder, forKey: "saveFolder")
        }
    }
    static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EVB Shot", isDirectory: true)
    }
    var folder: URL {
        get { defaults.url(forKey: "saveFolder") ?? Self.defaultFolder }
        nonmutating set { defaults.set(newValue.standardizedFileURL, forKey: "saveFolder") }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    static var underPointer: NSScreen {
        screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? main ?? screens[0]
    }
}

@MainActor
func presentError(_ error: Error) {
    let alert = NSAlert(error: error)
    alert.alertStyle = .warning
    alert.runModal()
}

@MainActor
func copyPath(_ url: URL, pasteboard: NSPasteboard = .general) throws {
    pasteboard.clearContents()
    let quoted = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    guard pasteboard.setString(quoted, forType: .string) else {
        throw ShotError("The file was saved, but its path could not be copied. Saved file: \(url.path)")
    }
}

@MainActor
func copySavedCapture(_ url: URL, kind: MediaKind, mode: CaptureCopyMode, pasteboard: NSPasteboard = .general) async throws {
    switch mode {
    case .none: return
    case .filePath: try copyPath(url, pasteboard: pasteboard)
    case .media:
        let object: NSPasteboardWriting
        if kind == .image {
            // Offer the saved, full-resolution edited PNG as image data and as
            // a file attachment. Never use the scaled editor preview.
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            item.setString(url.absoluteString, forType: .fileURL)
            object = item
        } else {
            // Copy the permanent saved file, like Finder. Large recordings do
            // not need to be loaded into memory or depend on a temporary export.
            object = url as NSURL
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([object]) else {
            throw ShotError("The file was saved, but its media could not be copied. Saved file: \(url.path)")
        }
    }
}

@MainActor
func saveCaptureFile(from source: URL, to destination: URL, copyFilePath: Bool, pasteboard: NSPasteboard = .general) async throws {
    try await Task.detached { try CaptureFiles.atomicCopy(from: source, to: destination) }.value
    if copyFilePath { try copyPath(destination, pasteboard: pasteboard) }
}

@MainActor
func saveCaptureFile(from source: URL, toFolder folder: URL, kind: MediaKind, copy: CaptureCopyMode, pasteboard: NSPasteboard = .general) async throws -> URL {
    let name = CaptureFiles.suggestedName(kind)
    let destination = try await Task.detached { try CaptureFiles.copyToFolder(from: source, folder: folder, name: name) }.value
    try await copySavedCapture(destination, kind: kind, mode: copy, pasteboard: pasteboard)
    return destination
}
