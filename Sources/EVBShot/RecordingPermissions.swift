import AVFoundation

enum RecordingPermission: String, CaseIterable {
    case camera = "Camera", microphone = "Microphone"
    var mediaType: AVMediaType { self == .camera ? .video : .audio }
    var settingsURL: URL { URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_\(rawValue)")! }
}

struct RecordingAccessError: LocalizedError {
    let permission: RecordingPermission
    let restricted: Bool
    var errorDescription: String? {
        restricted ? "\(permission.rawValue) access is restricted on this Mac." : "\(permission.rawValue) access is off. Open Settings to enable it, or record without it."
    }
}

// Authorization is separate from device startup, so the user's selection stays
// visible while macOS asks for access. Tests inject decisions, never TCC state.
struct RecordingPermissionAccess {
    var status: (RecordingPermission) -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for:$0.mediaType) }
    var request: (RecordingPermission) async -> Bool = { await AVCaptureDevice.requestAccess(for:$0.mediaType) }

    func authorize(_ permission: RecordingPermission) async throws {
        switch status(permission) {
        case .authorized: return
        case .notDetermined:
            if await request(permission) { return }
            throw RecordingAccessError(permission:permission,restricted:false)
        case .restricted: throw RecordingAccessError(permission:permission,restricted:true)
        case .denied: throw RecordingAccessError(permission:permission,restricted:false)
        @unknown default: throw RecordingAccessError(permission:permission,restricted:true)
        }
    }
}
