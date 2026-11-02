import CoreAudio
import Foundation

/// Sends one app's audio to one output device.
///
/// How it works (macOS 14.2+):
///  1. A *process tap* captures the app's audio and mutes it on its normal output.
///  2. A private *aggregate device* is built from the chosen output device plus that tap.
///  3. An IO callback on the aggregate device copies tap input -> device output.
final class AppAudioRouter {
    static let uidPrefix = "com.francisco.AudioRouter.agg."

    let bundleID: String
    let deviceUID: String
    let processObjects: Set<AudioObjectID>

    private var tapID = kUnknownObject
    private var aggregateID = kUnknownObject
    private var ioProcID: AudioDeviceIOProcID?

    init(bundleID: String, processObjects: Set<AudioObjectID>, deviceUID: String) throws {
        self.bundleID = bundleID
        self.deviceUID = deviceUID
        self.processObjects = processObjects
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func start() throws {
        // 1. Tap the app's processes (all helpers included) and mute their normal output.
        let tap = CATapDescription(stereoMixdownOfProcesses: processObjects.sorted())
        tap.uuid = UUID()
        tap.name = "AudioRouter – \(bundleID)"
        tap.isPrivate = true
        tap.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        try caCheck(AudioHardwareCreateProcessTap(tap, &tapID), "Creating audio tap (check Audio Capture permission)")

        // 2. Aggregate device: chosen speaker as the clock/main device, tap as its input.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRouter \(bundleID)",
            kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: deviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                ]
            ],
        ]
        try caCheck(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                    "Creating aggregate device")

        // Small buffer = less added delay (~5 ms at 48 kHz). Ignored if the device refuses.
        var frames: UInt32 = 256
        var bufAddr = CA.address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(aggregateID, &bufAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        // 3. Copy captured audio to the output, directly on the real-time audio thread.
        try caCheck(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInput, _, outOutput, _ in
            AppAudioRouter.render(
                input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput)),
                output: UnsafeMutableAudioBufferListPointer(outOutput)
            )
        }, "Creating IO callback")

        try caCheck(AudioDeviceStart(aggregateID, ioProcID), "Starting playback")
    }

    func stop() {
        if aggregateID != kUnknownObject, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kUnknownObject {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kUnknownObject
        }
        if tapID != kUnknownObject {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kUnknownObject
        }
    }

    /// Real-time copy: maps input channels onto output channels (wrapping, so a stereo tap
    /// fills L/R of any device), works for interleaved and non-interleaved Float32 buffers.
    /// No allocation, no locks.
    private static func render(input: UnsafeMutableAudioBufferListPointer,
                               output: UnsafeMutableAudioBufferListPointer) {
        var inTotal = 0
        for b in input { inTotal += Int(b.mNumberChannels) }

        var outChannelBase = 0
        for ob in output {
            guard let od = ob.mData else { continue }
            let oc = max(Int(ob.mNumberChannels), 1)
            let outFrames = Int(ob.mDataByteSize) / (MemoryLayout<Float>.size * oc)
            let dst = od.assumingMemoryBound(to: Float.self)

            if inTotal == 0 {
                memset(od, 0, Int(ob.mDataByteSize))
                outChannelBase += oc
                continue
            }

            for c in 0..<oc {
                // Find which input buffer/channel feeds this output channel.
                var idx = (outChannelBase + c) % inTotal
                var srcPtr: UnsafePointer<Float>?
                var srcStride = 1
                var srcFrames = 0
                for ib in input {
                    let ic = Int(ib.mNumberChannels)
                    if idx < ic {
                        if let d = ib.mData, ic > 0 {
                            srcPtr = UnsafePointer(d.assumingMemoryBound(to: Float.self)).advanced(by: idx)
                            srcStride = ic
                            srcFrames = Int(ib.mDataByteSize) / (MemoryLayout<Float>.size * ic)
                        }
                        break
                    }
                    idx -= ic
                }

                let n = min(outFrames, srcFrames)
                var f = 0
                if let src = srcPtr {
                    while f < n {
                        dst[f * oc + c] = src[f * srcStride]
                        f += 1
                    }
                }
                while f < outFrames {
                    dst[f * oc + c] = 0
                    f += 1
                }
            }
            outChannelBase += oc
        }
    }
}
