import Foundation

/// Builds what the player plays (playback.m4a): the call and your voice, each brought to the same
/// loudness and mixed to one track.
///
/// - Levelling: each track's gain follows its speech level over a few seconds toward one target, so a
///   laptop mic 13 dB quieter than the call, or a participant far from their mic, plays as loud as
///   everyone else. The gain holds through silence, so background noise isn't pumped up.
/// - Your track is the echo canceller's linear output: nothing in it is gated, so your voice isn't
///   chopped. While the call is talking and you aren't, it is turned down, so the echo left in it
///   can't play on top of the call and make it sound doubled or hollow.
/// - A soft limiter keeps the peaks from clipping.
enum PlaybackMixer {
    static let sampleRate = 16_000
    private static let frame = 160 // 10 ms
    private static let target: Float = -20 // dBFS of speech
    private static let maxBoost: Float = 18, maxCut: Float = -8
    /// Your track while only the call is talking (-18 dB).
    private static let duckFloor: Float = 0.125

    /// - Parameters:
    ///   - mic: your track (echo-cancelled linear output when there was echo).
    ///   - system: the call track, if any.
    ///   - yourWords: when you spoke (after clean-up), to know when the mic is you and not echo.
    ///   - echoPresent: false with headphones: then there's nothing to duck.
    static func mix(mic: [Float], system: [Float]?, yourWords: [Word], echoPresent: Bool) -> [Float] {
        let n = max(mic.count, system?.count ?? 0)
        guard n > 0 else { return [] }
        let micEnv = envelope(mic)
        let speaking = activity(of: yourWords, frames: micEnv.count, pad: 0.1)
        var out = [Float](repeating: 0, count: n)

        // Your track: levelled on the moments you speak (or, without words, whenever it's active).
        let micActive: [Bool] = yourWords.isEmpty ? active(micEnv) : speaking
        let micGain = gainCurve(micEnv, active: micActive)

        if let system, !system.isEmpty {
            let sysEnv = envelope(system)
            let sysGain = gainCurve(sysEnv, active: active(sysEnv))
            // Duck your track while the call talks and you don't (with 250 ms of hangover around your words).
            var duck = [Float](repeating: 1, count: micEnv.count)
            if echoPresent {
                let you = activity(of: yourWords, frames: micEnv.count, pad: 0.25)
                let callActive = active(sysEnv)
                for i in 0..<duck.count {
                    let lo = max(0, i - 30), hi = min(callActive.count, i + 31)
                    let callNear = lo < hi && callActive[lo..<hi].contains(true)
                    duck[i] = (callNear && !you[i]) ? duckFloor : 1
                }
                duck = smooth(duck, attackFrames: 5, releaseFrames: 3) // down over 50 ms, back up over 30 ms
            }
            for i in 0..<n {
                let f = i / frame
                var x: Float = 0
                if i < system.count { x += system[i] * interpolate(sysGain, at: i) }
                if i < mic.count { x += mic[i] * interpolate(micGain, at: i) * (f < duck.count ? interpolate(duck, at: i) : 1) }
                out[i] = limit(x)
            }
        } else {
            for i in 0..<mic.count { out[i] = limit(mic[i] * interpolate(micGain, at: i)) }
        }
        return out
    }

    // MARK: - Pieces

    private static func envelope(_ x: [Float]) -> [Float] {
        let count = x.count / frame
        var env = [Float](repeating: -100, count: count)
        x.withUnsafeBufferPointer { p in
            for i in 0..<count {
                var acc: Float = 0
                for k in 0..<frame { let v = p[i * frame + k]; acc += v * v }
                env[i] = 10 * log10(max(acc / Float(frame), 1e-10))
            }
        }
        return env
    }

    /// Frames well above the track's noise floor.
    private static func active(_ env: [Float]) -> [Bool] {
        guard !env.isEmpty else { return [] }
        let sorted = env.sorted()
        let noise = sorted[sorted.count / 10]
        let threshold = max(noise + 12, -55)
        return env.map { $0 > threshold }
    }

    private static func activity(of words: [Word], frames count: Int, pad: Double) -> [Bool] {
        var on = [Bool](repeating: false, count: count)
        for w in words {
            let lo = max(0, Int((w.start - pad) * 100)), hi = min(count, Int((w.end + pad) * 100) + 1)
            if lo < hi { for i in lo..<hi { on[i] = true } }
        }
        return on
    }

    /// Linear gain per 10 ms frame that brings the speech level (over ~3 s) to the target.
    private static func gainCurve(_ env: [Float], active: [Bool]) -> [Float] {
        let count = env.count
        guard count > 0 else { return [] }
        // Running sums of active power, so each frame's 3 s window costs O(1).
        var power = [Double](repeating: 0, count: count + 1), hits = [Int](repeating: 0, count: count + 1)
        for i in 0..<count {
            let on = i < active.count && active[i]
            power[i + 1] = power[i] + (on ? pow(10, Double(env[i]) / 10) : 0)
            hits[i + 1] = hits[i] + (on ? 1 : 0)
        }
        // The level of the whole track, for the start and for long stretches of silence.
        let overall = hits[count] > 0 ? Float(10 * log10(power[count] / Double(hits[count]))) : target
        var gainDB = [Float](repeating: 0, count: count)
        var held = clamp(target - overall)
        for i in 0..<count {
            let lo = max(0, i - 150), hi = min(count, i + 150)
            let n = hits[hi] - hits[lo]
            if n >= 30 { // at least 0.3 s of speech in the window
                held = clamp(target - Float(10 * log10((power[hi] - power[lo]) / Double(n))))
            }
            gainDB[i] = held
        }
        // Glide between levels (about a second) so the volume never jumps.
        let glided = smooth(gainDB, attackFrames: 60, releaseFrames: 60)
        return glided.map { pow(10, $0 / 20) }
    }

    private static func clamp(_ db: Float) -> Float { min(maxBoost, max(maxCut, db)) }

    /// One-pole smoothing, faster when the value drops (attack) than when it rises (release), or as given.
    private static func smooth(_ x: [Float], attackFrames: Float, releaseFrames: Float) -> [Float] {
        guard var y = x.first else { return x }
        let a = 1 / max(attackFrames, 1), r = 1 / max(releaseFrames, 1)
        return x.map { v in
            y += (v - y) * (v < y ? a : r)
            return y
        }
    }

    @inline(__always) private static func interpolate(_ curve: [Float], at sample: Int) -> Float {
        let pos = Float(sample) / Float(frame)
        let i = min(Int(pos), curve.count - 1)
        guard i >= 0 else { return 1 }
        let j = min(i + 1, curve.count - 1)
        let f = pos - Float(i)
        return curve[i] + (curve[j] - curve[i]) * min(max(f, 0), 1)
    }

    /// Transparent below -6 dBFS, then rounds off toward -2 dBFS (headroom for the AAC encoder's overshoot).
    @inline(__always) private static func limit(_ x: Float) -> Float {
        let knee: Float = 0.5, ceiling: Float = 0.8
        let a = abs(x)
        guard a > knee else { return x }
        let y = knee + (ceiling - knee) * tanh((a - knee) / (ceiling - knee))
        return x < 0 ? -y : y
    }
}
