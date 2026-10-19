import AppKit
import CoreAudio

struct MicrophoneDevice: Equatable, Sendable {
    let uid: String
    let name: String
}

enum SystemMicrophone {
    static func current() throws -> MicrophoneDevice {
        var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,
            mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device) == noErr,
              device != kAudioObjectUnknown else { throw ShotError("No system input microphone is available.") }
        return try MicrophoneDevice(uid:string(device,kAudioDevicePropertyDeviceUID),name:string(device,kAudioObjectPropertyName))
    }
    private static func string(_ device:AudioDeviceID,_ selector:AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let result = withUnsafeMutablePointer(to:&value) { AudioObjectGetPropertyData(device,&address,0,nil,&size,$0) }
        guard result == noErr, let value else { throw ShotError("Cannot read the system input microphone.") }
        return value.takeRetainedValue() as String
    }
}

/// Observe the user's choice without changing any system audio settings.
@MainActor
final class SystemMicrophoneMonitor {
    private var listener: AudioObjectPropertyListenerBlock?
    var onChange: ((MicrophoneDevice?) -> Void)?
    private static var address:AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,
            mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    }
    func start() {
        guard listener == nil else { return }
        let block:AudioObjectPropertyListenerBlock = { [weak self] _,_ in
            MainActor.assumeIsolated { self?.onChange?(try? SystemMicrophone.current()) }
        }
        var address = Self.address
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&address,.main,block) == noErr { listener = block }
    }
    func stop() {
        guard let listener else { return }
        var address = Self.address
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&address,.main,listener)
        self.listener = nil
    }
    deinit {
        if let listener {
            var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,
                mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&address,.main,listener)
        }
    }
}
