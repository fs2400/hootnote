import AVFoundation
import CoreAudio
import Foundation

/// Records everything the Mac plays (the other people on the call) with a Core Audio
/// process tap (macOS 14.4+). No virtual audio driver, and nothing joins the meeting.
///
/// The tap is global (all apps except Hootnote), so it keeps working when a call
/// app moves its audio to a helper process or you switch speakers/headphones mid-call.
final class SystemAudioCapture: @unchecked Sendable {
    private let writer: AudioTrackWriter
    private let queue = DispatchQueue(label: "Hootnote.systemAudio", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var tapChannelBuffers = 1
    private var callbackCount = 0
    private var usingOutputSubDevice = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var watchdog: DispatchWorkItem?

    init(writer: AudioTrackWriter) {
        self.writer = writer
    }

    func start() throws {
        try build(includeOutputDevice: false)
        scheduleWatchdog()
        listenForOutputDeviceChanges()
    }

    func stop() {
        watchdog?.cancel()
        if let outputListener {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(.system, &addr, queue, outputListener)
            self.outputListener = nil
        }
        teardown()
    }

    // MARK: - Build / teardown

    private func build(includeOutputDevice: Bool) throws {
        var exclude: [AudioObjectID] = []
        if let own = AudioObjectID.processObject(for: getpid()) { exclude.append(own) }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.uuid = UUID()
        description.name = "Hootnote system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Creating the system-audio tap")
        tapID = tap

        var asbd = try tap.readTapFormat()
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            teardown()
            throw CoreAudioError.status("Reading the tap's audio format", -1)
        }
        tapFormat = format
        tapChannelBuffers = format.isInterleaved ? 1 : Int(format.channelCount)

        var props: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hootnote Tap",
            kAudioAggregateDeviceUIDKey: "com.local.Hootnote.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if includeOutputDevice, let out = AudioObjectID.defaultOutputDevice, let uid = out.deviceUID {
            props[kAudioAggregateDeviceMainSubDeviceKey] = uid
            props[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        usingOutputSubDevice = includeOutputDevice

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(props as CFDictionary, &aggregate), "Creating the capture device")
            aggregateID = aggregate
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [weak self] _, input, inputTime, _, _ in
                self?.handle(input, inputTime)
            }, "Creating the capture callback")
            try check(AudioDeviceStart(aggregate, procID), "Starting system-audio capture")
        } catch {
            teardown()
            throw error
        }
        log.info("System audio tap started (sub-device: \(includeOutputDevice), format: \(format))")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// If a tap-only device never calls back, rebuild it clocked by the output device.
    private func scheduleWatchdog() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.callbackCount == 0, !self.usingOutputSubDevice else { return }
            log.warning("No system-audio callbacks; rebuilding tap with the output device as clock")
            self.teardown()
            try? self.build(includeOutputDevice: true)
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func listenForOutputDeviceChanges() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Only the output-clocked fallback depends on the output device.
            guard let self, self.usingOutputSubDevice else { return }
            log.info("Default output changed; rebuilding system-audio capture")
            self.teardown()
            try? self.build(includeOutputDevice: true)
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(.system, &addr, queue, block)
    }

    // MARK: - Audio callback (on `queue`)

    private func handle(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        callbackCount += 1
        guard let format = tapFormat else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let hostTime: UInt64? = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : nil

        if list.count == tapChannelBuffers {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            writer.append(buffer, hostTime: hostTime)
            return
        }
        // With a sub-device the device's own input streams come first; the tap's are last.
        guard list.count > tapChannelBuffers else { return }
        let tapList = AudioBufferList.allocate(maximumBuffers: tapChannelBuffers)
        defer { free(tapList.unsafeMutablePointer) }
        for i in 0..<tapChannelBuffers {
            tapList[i] = list[list.count - tapChannelBuffers + i]
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: tapList.unsafePointer, deallocator: nil) else { return }
        writer.append(buffer, hostTime: hostTime)
    }
}
