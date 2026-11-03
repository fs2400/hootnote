import Accelerate
import CSpeexDSP
import Foundation

/// Removes the call audio your microphone picks up from the Mac's speakers (acoustic echo).
///
/// The system-audio tap gives us exactly what the speakers played, so it serves as the
/// reference signal for an adaptive echo canceller (SpeexDSP's MDF filter, plus its
/// residual-echo suppressor). This runs after the call on the two clock-aligned tracks, so it
/// can look both ways in time to find the speaker-to-mic delay. With headphones there is no
/// echo to find and the mic track is left untouched.
enum EchoCanceller {
    struct Report: Sendable, CustomStringConvertible {
        var applied: Bool
        var delayMs: Double
        var correlation: Float
        /// Energy removed from the mic while the call was audible (includes double-talk, so conservative).
        var reductionDB: Float?

        var description: String {
            applied
                ? String(format: "echo cancelled (delay %.0f ms, r=%.2f, %.1f dB removed)", delayMs, correlation, reductionDB ?? 0)
                : String(format: "no echo detected (r=%.2f); mic left as recorded", correlation)
        }
    }

    static let sampleRate = 16_000
    static let frameSize = 256 // 16 ms
    /// Room reverberation the filter models after the bulk delay (192 ms).
    static let filterLength = 3072
    /// Minimum envelope correlation that counts as audible echo.
    static let detectionThreshold: Float = 0.2

    /// - Returns: `output` with echo removed and suppressed (for transcription: no echo words), and `linear`,
    ///   the adaptive filter's output without the suppressor (for listening: no gating, so your voice isn't chopped).
    static func process(mic: [Float], reference: [Float]) -> (output: [Float], linear: [Float], report: Report) {
        guard mic.count > sampleRate, reference.count > sampleRate else {
            return (mic, mic, Report(applied: false, delayMs: 0, correlation: 0))
        }
        let (lag, r) = estimateDelay(mic: mic, reference: reference)
        guard r >= detectionThreshold else {
            return (mic, mic, Report(applied: false, delayMs: Double(lag) * 1000 / Double(sampleRate), correlation: r))
        }

        // Align the reference so the echo starts just after it (10 ms margin keeps the filter causal).
        let shift = lag - sampleRate / 100
        var aligned = [Float](repeating: 0, count: mic.count)
        for t in 0..<mic.count {
            let s = t - shift
            if s >= 0 && s < reference.count { aligned[t] = reference[s] }
        }

        let (output, linear) = cancel(mic: mic, reference: aligned)
        let reduction = measureReduction(before: mic, after: output, reference: aligned)
        return (output, linear, Report(applied: true, delayMs: Double(lag) * 1000 / Double(sampleRate),
                                       correlation: r, reductionDB: reduction))
    }

    // MARK: - Delay estimation

    /// Correlates 4 ms log-energy envelopes over lags of -100…+500 ms, using only the moments when
    /// the call is audible (your own speech would otherwise swamp the comparison).
    /// Returns (lag in samples, peak correlation).
    static func estimateDelay(mic: [Float], reference: [Float]) -> (Int, Float) {
        let hop = 64
        let n = min(mic.count, reference.count) / hop
        guard n > 100 else { return (0, 0) }
        let refEnv = envelope(reference, hop: hop, count: n)
        let micEnv = envelope(mic, hop: hop, count: n)
        let active = (0..<n).filter { refEnv[$0] > 0.005 } // call louder than about -46 dBFS
        guard active.count > 250 else { return (0, 0) }    // under a second of call audio
        let logRef = refEnv.map { log10($0 + 1e-4) }
        let logMic = micEnv.map { log10($0 + 1e-4) }

        let minLag = -100 * sampleRate / 1000 / hop
        let maxLag = 500 * sampleRate / 1000 / hop
        var best = (lag: 0, r: Float(-1))
        for lag in minLag...maxLag {
            var sx: Double = 0, sy: Double = 0, sxx: Double = 0, syy: Double = 0, sxy: Double = 0, count: Double = 0
            for t in active {
                let u = t + lag
                guard u >= 0 && u < n else { continue }
                let x = Double(logRef[t]), y = Double(logMic[u])
                sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y; count += 1
            }
            guard count > 250 else { continue }
            let cov = sxy - sx * sy / count
            let vx = sxx - sx * sx / count, vy = syy - sy * sy / count
            guard vx > 0, vy > 0 else { continue }
            let r = Float(cov / (vx * vy).squareRoot())
            if r > best.r { best = (lag, r) }
        }
        return (best.lag * hop, max(best.r, 0))
    }

    private static func envelope(_ x: [Float], hop: Int, count: Int) -> [Float] {
        var env = [Float](repeating: 0, count: count)
        x.withUnsafeBufferPointer { p in
            for i in 0..<count {
                var ms: Float = 0
                vDSP_measqv(p.baseAddress! + i * hop, 1, &ms, vDSP_Length(hop))
                env[i] = ms.squareRoot()
            }
        }
        return env
    }

    // MARK: - Cancellation

    private static func cancel(mic: [Float], reference: [Float]) -> (suppressed: [Float], linear: [Float]) {
        guard let echo = speex_echo_state_init(Int32(frameSize), Int32(filterLength)) else { return (mic, mic) }
        defer { speex_echo_state_destroy(echo) }
        var rate = Int32(sampleRate)
        speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)

        guard let pre = speex_preprocess_state_init(Int32(frameSize), Int32(sampleRate)) else { return (mic, mic) }
        defer { speex_preprocess_state_destroy(pre) }
        // Only residual-echo suppression: no denoise/AGC/dereverb, which would alter your voice for Whisper.
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echo))
        var off: Int32 = 0
        for request in [SPEEX_PREPROCESS_SET_DENOISE, SPEEX_PREPROCESS_SET_AGC, SPEEX_PREPROCESS_SET_DEREVERB] {
            speex_preprocess_ctl(pre, request, &off)
        }
        var suppress: Int32 = -45      // dB, while only the far end is talking
        var suppressActive: Int32 = -15 // dB, during double-talk (protects your voice)
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &suppress)
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, &suppressActive)

        var output = [Float](repeating: 0, count: mic.count)
        var linear = [Float](repeating: 0, count: mic.count)
        var micFrame = [Int16](repeating: 0, count: frameSize)
        var refFrame = [Int16](repeating: 0, count: frameSize)
        var outFrame = [Int16](repeating: 0, count: frameSize)
        let frames = mic.count / frameSize

        func run(_ f: Int, keep: Bool) {
            let base = f * frameSize
            for i in 0..<frameSize {
                micFrame[i] = toInt16(mic[base + i])
                refFrame[i] = toInt16(reference[base + i])
            }
            speex_echo_cancellation(echo, micFrame, refFrame, &outFrame)
            if keep { for i in 0..<frameSize { linear[base + i] = Float(outFrame[i]) / 32768 } }
            _ = speex_preprocess_run(pre, &outFrame)
            if keep { for i in 0..<frameSize { output[base + i] = Float(outFrame[i]) / 32768 } }
        }
        // The filter needs a few seconds of call audio to learn the room. Offline we can let it
        // learn on the first 30 s, then process the whole recording from the start.
        let warmup = min(frames, 30 * sampleRate / frameSize)
        for f in 0..<warmup { run(f, keep: false) }
        for f in 0..<frames { run(f, keep: true) }
        // The last partial frame (under 16 ms) is passed through.
        for i in (frames * frameSize)..<mic.count { output[i] = mic[i]; linear[i] = mic[i] }
        return (output, linear)
    }

    @inline(__always)
    private static func toInt16(_ x: Float) -> Int16 {
        Int16(max(-32768, min(32767, (x * 32767).rounded())))
    }

    /// Median per-frame reduction while the call is audible. The median ignores the frames where
    /// you were talking over the call (your voice is, correctly, not removed there).
    private static func measureReduction(before: [Float], after: [Float], reference: [Float]) -> Float? {
        let hop = 256
        var reductions: [Float] = []
        for start in stride(from: 0, to: before.count - hop, by: hop) {
            var refMS: Float = 0, b: Float = 0, a: Float = 0
            reference.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + start, 1, &refMS, vDSP_Length(hop)) }
            guard refMS > 1e-4 else { continue } // reference RMS > 0.01
            before.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + start, 1, &b, vDSP_Length(hop)) }
            after.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + start, 1, &a, vDSP_Length(hop)) }
            guard b > 1e-9 else { continue }
            reductions.append(10 * log10(b / max(a, 1e-12)))
        }
        guard !reductions.isEmpty else { return nil }
        return min(reductions.sorted()[reductions.count / 2], 60)
    }
}
