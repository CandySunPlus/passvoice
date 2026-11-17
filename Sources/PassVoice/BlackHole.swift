import AudioToolbox
import CoreAudio
import Foundation

protocol AudioPlayback: AnyObject {
    func enqueue(_ samples: [Int16]) throws
    func play() throws
    func drain(_ completed: @escaping () -> Void) throws
    func stop()
}

struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class BlackHolePlayback: AudioPlayback {
    private static let name = "BlackHole 2ch"
    private static let trailingSilence = [Int16](repeating: 0, count: ADPCM.samplesPerFrame * 5)
    private var output: AudioQueueRef?
    private var available: [AudioQueueBufferRef] = []
    private var started = false
    private var drainCompleted: (() -> Void)?
    private let onInvalidation: () -> Void

    static func deviceID() throws -> AudioDeviceID {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddress = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size), "Enumerate audio devices")
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        try check(AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, &devices), "Read audio devices")
        for device in devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.stride) {
            if let deviceName = try? stringProperty(kAudioObjectPropertyName, for: device).takeRetainedValue(),
               deviceName as String == name {
                return device
            }
        }
        throw BridgeError("BlackHole 2ch was not found. Install or enable its Core Audio driver.")
    }

    init(onInvalidation: @escaping () -> Void) throws {
        self.onInvalidation = onInvalidation
        let device = try Self.deviceID()
        var format = AudioStreamBasicDescription(
            mSampleRate: ADPCM.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        let callbacks = DispatchQueue(label: "PassVoice.AudioQueue")
        try Self.check(AudioQueueNewOutputWithDispatchQueue(&output, &format, 0, callbacks) { [weak self] _, buffer in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.output != nil else { return }
                self.available.append(buffer)
            }
        }, "Create the audio queue")
        guard let output else { throw BridgeError("Core Audio did not create an output queue") }
        do {
            let uid = try Self.stringProperty(kAudioDevicePropertyDeviceUID, for: device).takeRetainedValue()
            // Select the hardware directly. Core Audio converts the queue's PCM to this device's format.
            var deviceUID = Unmanaged.passUnretained(uid)
            try withExtendedLifetime(uid) {
                try Self.check(AudioQueueSetProperty(output, kAudioQueueProperty_CurrentDevice, &deviceUID,
                                                     UInt32(MemoryLayout.size(ofValue: deviceUID))), "Select BlackHole 2ch")
            }
            try Self.check(AudioQueueAddPropertyListener(output, kAudioQueueProperty_IsRunning,
                                                         Self.runningChanged, Unmanaged.passUnretained(self).toOpaque()),
                           "Monitor the BlackHole audio queue")
        } catch {
            AudioQueueDispose(output, true)
            self.output = nil
            throw error
        }
    }

    deinit { stop() }

    func enqueue(_ samples: [Int16]) throws {
        guard let output else { throw BridgeError("The BlackHole audio queue is closed") }
        let buffer: AudioQueueBufferRef
        if let reused = available.popLast() {
            buffer = reused
        } else {
            let capacity = UInt32(Self.trailingSilence.count * MemoryLayout<Int16>.stride)
            var allocated: AudioQueueBufferRef?
            try Self.check(AudioQueueAllocateBuffer(output, capacity, &allocated), "Allocate a playback buffer")
            guard let allocated else { throw BridgeError("Core Audio did not allocate a playback buffer") }
            buffer = allocated
        }
        samples.withUnsafeBytes { bytes in
            buffer.pointee.mAudioData.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            buffer.pointee.mAudioDataByteSize = UInt32(bytes.count)
        }
        try Self.check(AudioQueueEnqueueBuffer(output, buffer, 0, nil), "Queue Passport audio")
    }

    func play() throws {
        guard let output else { throw BridgeError("The BlackHole audio queue is closed") }
        try Self.check(AudioQueueStart(output, nil), "Start BlackHole playback")
        started = true
        if drainCompleted != nil { try drainQueue(output) }
    }

    func drain(_ completed: @escaping () -> Void) throws {
        guard let output else { throw BridgeError("The BlackHole audio queue is closed") }
        try enqueue(Self.trailingSilence)
        drainCompleted = completed
        if started { try drainQueue(output) }
    }

    func stop() {
        guard let output else { return }
        self.output = nil
        drainCompleted = nil
        available.removeAll()
        AudioQueueRemovePropertyListener(output, kAudioQueueProperty_IsRunning, Self.runningChanged,
                                         Unmanaged.passUnretained(self).toOpaque())
        AudioQueueDispose(output, true)
    }

    private func drainQueue(_ output: AudioQueueRef) throws {
        // The asynchronous stop is completed after the device plays its queued buffers.
        try Self.check(AudioQueueStop(output, false), "Drain BlackHole playback")
    }

    private static let runningChanged: AudioQueuePropertyListenerProc = { context, _, _ in
        guard let context else { return }
        let playback = Unmanaged<BlackHolePlayback>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { [weak playback] in playback?.checkRunning() }
    }

    private func checkRunning() {
        guard let output, started else { return }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: running))
        let status = AudioQueueGetProperty(output, kAudioQueueProperty_IsRunning, &running, &size)
        if status != noErr {
            onInvalidation()
        } else if running == 0 {
            if let completion = drainCompleted {
                drainCompleted = nil
                completion()
            } else {
                onInvalidation()
            }
        }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, for device: AudioDeviceID) throws -> Unmanaged<CFString> {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value), "Read an audio device property")
        guard let value else { throw BridgeError("Core Audio returned an empty device property") }
        return value
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw BridgeError("\(operation) failed (OSStatus \(status))") }
    }
}
