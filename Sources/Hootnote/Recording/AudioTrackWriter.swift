import AVFoundation
import Foundation

/// Writes one track to a 16 kHz mono 16-bit CAF file (the format the speech models use).
///
/// - Resamples and downmixes whatever arrives (any rate, any channel count).
/// - Uses each buffer's host timestamp to keep the track aligned to the recording start, so the mic
///   and system tracks line up for the echo canceller and the transcript. Real gaps (device switches,
///   the tap waking up late) are padded with silence. Ordinary clock drift between the audio device and
///   the host clock is absorbed a sample at a time, which you can't hear; padding or dropping 40 ms
///   blocks for it made the call audio skip.
final class AudioTrackWriter: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    let url: URL
    private let queue: DispatchQueue
    private let startHostTime: UInt64
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var framesWritten: Int64 = 0
    private var correcting = false

    private let lock = NSLock()
    private var _level: Float = 0
    private var _lastActivity: Date = .distantPast
    private var _receivedAudio = false
    private var _paused = false

    /// Recent RMS level, 0...1 (roughly: 0.1 = normal speech).
    var level: Float { lock.withLock { _level } }
    /// Last time this track carried something louder than background noise.
    var lastActivity: Date { lock.withLock { _lastActivity } }
    var receivedAudio: Bool { lock.withLock { _receivedAudio } }
    var durationSeconds: Double { queue.sync { Double(framesWritten) / Self.sampleRate } }

    /// While paused, incoming audio is metered but not written. Resuming fills the time paused with
    /// silence, so the track stays on the recording's clock.
    var isPaused: Bool {
        get { lock.withLock { _paused } }
        set {
            let resumed = lock.withLock { () -> Bool in
                defer { _paused = newValue }
                return _paused && !newValue
            }
            if resumed {
                let now = mach_absolute_time()
                queue.async { self.padSilence(until: now) }
            }
        }
    }

    init(url: URL, startHostTime: UInt64, label: String) throws {
        self.url = url
        self.startHostTime = startHostTime
        self.queue = DispatchQueue(label: "Hootnote.writer.\(label)", qos: .userInitiated)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Thread-safe. The buffer is copied, so the caller may reuse it.
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        guard buffer.frameLength > 0, let copy = buffer.deepCopy() else { return }
        queue.async { self.process(copy, hostTime: hostTime) }
    }

    /// Flushes and closes the file. Blocks until pending buffers are written.
    func finish() {
        queue.sync {
            file = nil
            converter = nil
        }
    }

    // MARK: - Private (writer queue)

    private func process(_ input: AVAudioPCMBuffer, hostTime: UInt64?) {
        guard file != nil, var output = convert(input) else { return }
        if lock.withLock({ _paused }) {
            meter(output)
            return
        }

        if let hostTime, hostTime > startHostTime {
            let elapsed = AVAudioTime.seconds(forHostTime: hostTime - startHostTime)
            let expected = Int64(elapsed * Self.sampleRate)
            let drift = expected - framesWritten
            let gap = Int64(Self.sampleRate * 0.1)
            if drift > gap || (framesWritten == 0 && drift > 0) {
                // Audio is missing (or this is the first buffer): line up with silence.
                writeSilence(frames: drift)
            } else if drift < -gap {
                // Far ahead of the clock: drop the overlap.
                let drop = min(Int64(output.frameLength), -drift)
                guard let trimmed = output.dropping(frames: AVAudioFrameCount(drop)) else { return }
                output = trimmed
            } else {
                // Clock drift: stretch or squeeze this buffer by a few samples (at most 0.6%) until
                // the track is back within 2 ms, starting once it is 10 ms out.
                if abs(drift) > Int64(Self.sampleRate * 0.01) { correcting = true }
                if abs(drift) < Int64(Self.sampleRate * 0.002) { correcting = false }
                if correcting {
                    let step = max(1, min(Int(output.frameLength) / 160, 4))
                    if let adjusted = output.resampled(by: drift > 0 ? step : -step) { output = adjusted }
                }
            }
        }
        write(output)
        meter(output)
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converterSource != input.format || converter == nil {
            converter = AVAudioConverter(from: input.format, to: outFormat)
            converter?.downmix = true
            converterSource = input.format
        }
        guard let converter else { return nil }
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            log.error("Audio conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file, buffer.frameLength > 0 else { return }
        do {
            try file.write(from: buffer)
            framesWritten += Int64(buffer.frameLength)
        } catch {
            log.error("Write failed for \(self.url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func padSilence(until hostTime: UInt64) {
        guard file != nil, hostTime > startHostTime else { return }
        let expected = Int64(AVAudioTime.seconds(forHostTime: hostTime - startHostTime) * Self.sampleRate)
        if expected > framesWritten { writeSilence(frames: expected - framesWritten) }
    }

    private func writeSilence(frames: Int64) {
        var remaining = frames
        let chunk: AVAudioFrameCount = 16_000
        guard let silence = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else { return }
        while remaining > 0 {
            let n = AVAudioFrameCount(min(Int64(chunk), remaining))
            silence.frameLength = n
            if let ch = silence.floatChannelData?[0] { ch.update(repeating: 0, count: Int(n)) }
            write(silence)
            remaining -= Int64(n)
        }
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
        lock.withLock {
            _level = rms
            _receivedAudio = true
            if rms > 0.004 { _lastActivity = Date() }
        }
    }
}

extension AVAudioPCMBuffer {
    /// Copies the samples so the buffer outlives the audio callback that produced it.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            let bytes = min(src[i].mDataByteSize, dst[i].mDataByteSize)
            memcpy(d, s, Int(bytes))
            dst[i].mDataByteSize = bytes
        }
        return copy
    }

    /// The same audio stretched to `frameLength + delta` frames by linear interpolation (mono float only).
    func resampled(by delta: Int) -> AVAudioPCMBuffer? {
        let n = Int(frameLength), m = n + delta
        guard delta != 0, n > 1, m > 1, let src = floatChannelData?[0],
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(m)),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(m)
        let ratio = Double(n - 1) / Double(m - 1)
        for i in 0..<m {
            let x = Double(i) * ratio
            let k = min(Int(x), n - 2)
            let f = Float(x - Double(k))
            dst[i] = src[k] * (1 - f) + src[k + 1] * f
        }
        return out
    }

    /// A copy without the first `frames` frames (mono float only).
    func dropping(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard frames < frameLength, let src = floatChannelData?[0] else { return nil }
        let remaining = frameLength - frames
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = remaining
        dst.update(from: src.advanced(by: Int(frames)), count: Int(remaining))
        return out
    }
}
