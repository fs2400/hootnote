import AudioToolbox
import CoreAudio
import Foundation

enum CoreAudioError: LocalizedError {
    case status(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .status(let what, let code): return "\(what) failed (OSStatus \(code))"
        }
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError.status(what, status) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func readUInt32(_ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    func readPID() -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    func readString(_ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    func readObjectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    func readObjectID(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var addr = address(selector)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value) == noErr,
              value != kAudioObjectUnknown else { return nil }
        return value
    }

    func readTapFormat() throws -> AudioStreamBasicDescription {
        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &asbd), "Read tap format")
        return asbd
    }

    static var defaultOutputDevice: AudioObjectID? { system.readObjectID(kAudioHardwarePropertyDefaultSystemOutputDevice) }
    static var defaultInputDevice: AudioObjectID? { system.readObjectID(kAudioHardwarePropertyDefaultInputDevice) }

    var deviceUID: String? { readString(kAudioDevicePropertyDeviceUID) }
    var deviceName: String? { readString(kAudioObjectPropertyName) }

    /// The Core Audio "process object" for a PID (only exists once that process has touched audio).
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &result)
        return (status == noErr && result != kAudioObjectUnknown) ? result : nil
    }
}

/// One process known to Core Audio and whether it is currently using input/output.
struct AudioClientProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
    let isRunningOutput: Bool

    /// Snapshot of every process using Core Audio. Needs no permission (macOS 14+).
    static func snapshot() -> [AudioClientProcess] {
        AudioObjectID.system.readObjectList(kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = id.readPID() else { return nil }
            return AudioClientProcess(
                objectID: id,
                pid: pid,
                bundleID: id.readString(kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: (id.readUInt32(kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                isRunningOutput: (id.readUInt32(kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            )
        }
    }
}
