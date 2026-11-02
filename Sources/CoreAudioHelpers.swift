import CoreAudio
import Foundation

// MARK: - Errors

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String
    var errorDescription: String? { "\(operation) failed (OSStatus \(status))" }
}

func caCheck(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status: status, operation: operation()) }
}

let kUnknownObject = AudioObjectID(kAudioObjectUnknown)
let kSystemObject = AudioObjectID(kAudioObjectSystemObject)

// MARK: - Model types

struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool
}

// MARK: - Property access

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objectIDs(_ object: AudioObjectID,
                          _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: kUnknownObject, count: count)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func pid(of process: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = -1
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    static func streamCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        objectIDs(device, kAudioDevicePropertyStreams, scope).count
    }

    /// All devices that can play sound (our own private aggregate devices are excluded).
    static func outputDevices() -> [OutputDevice] {
        objectIDs(kSystemObject, kAudioHardwarePropertyDevices).compactMap { dev in
            guard streamCount(dev, kAudioObjectPropertyScopeOutput) > 0,
                  let uid = string(dev, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(AppAudioRouter.uidPrefix),
                  let name = string(dev, kAudioObjectPropertyName) else { return nil }
            return OutputDevice(id: dev, uid: uid, name: name)
        }
    }

    /// Every process Core Audio knows about (macOS 14.2+).
    static func audioProcesses() -> [AudioProcess] {
        objectIDs(kSystemObject, kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            guard let pid = pid(of: obj) else { return nil }
            return AudioProcess(
                object: obj,
                pid: pid,
                bundleID: string(obj, kAudioProcessPropertyBundleID),
                isPlaying: (uint32(obj, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            )
        }
    }
}
