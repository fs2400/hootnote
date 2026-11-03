import Foundation

/// Tidies a transcript before it's shown, saved or summarized.
///
/// 1. Speaker echo that survived the echo canceller. On laptop speakers your mic hears the call,
///    sometimes louder than your own voice. What's left after cancellation is garbled, and Whisper
///    turns it into short lines of nonsense under your name, in the middle of someone else's sentence.
///    The test is whose voice it is: pyannote separates the voices on your mic, and the ones that
///    match a participant on the call (and only turn up while the call is playing) are echo. Your
///    own voice never matches theirs, so your interjections stay, even over someone else.
///    Without voice evidence it falls back on the audio: echo follows the call's loudness contour,
///    repeats its words, and is much quieter than you.
/// 2. Whisper artifacts: dialogue dashes ("- Okay.") and repetition loops ("I think, I think, I think…").
/// 3. Paragraphs split only by removed fragments are joined again.
enum TranscriptCleaner {
    struct Audio {
        /// Your track after echo cancellation (what was transcribed).
        let mic: [Float]
        /// The call track.
        let system: [Float]
    }

    /// Who is on your mic (your track's own diarization) and what the call participants sound like.
    struct Voices {
        let micSegments: [DiarSegment]
        let micSpeakers: [TranscriptionEngine.DiarizedSpeaker]
        let callVoices: [[Float]]
    }

    struct Report: CustomStringConvertible {
        var echoFragments = 0
        var echoWords = 0
        var loopWords = 0
        var description: String {
            "removed \(echoFragments) echo fragments (\(echoWords) words), \(loopWords) repeated words"
        }
        var changed: Bool { echoWords + loopWords > 0 }
    }

    /// One run of your words with no pause over 0.45 s, judged as a unit.
    struct Fragment {
        var words: [Word]
        var start: Double { words.first?.start ?? 0 }
        var end: Double { words.last?.end ?? 0 }
        var text: String { words.map(\.text).joined(separator: " ") }
        /// Per word: is it echo?
        var echo: [Bool] = []
        /// Share of the fragment's span covered by remote speech.
        var overlap = 0.0
        /// Correlation of your track's loudness contour with the call's (echo follows it).
        var contour = 0.0
        /// Share of words that the call audio also contains nearby.
        var textMatch = 0.0
        /// Loudness relative to your typical voice, in dB.
        var relativeLevel = 0.0
        /// Which voice on your mic said it, and whether that voice is a call participant's.
        var voice: String?
        var voiceIsEcho: Bool?
        var echoShare: Double { echo.isEmpty ? 0 : Double(echo.filter { $0 }.count) / Double(echo.count) }
    }

    static func clean(_ utterances: [Utterance], audio: Audio?, voices: Voices?,
                      echoPresent: Bool) -> (utterances: [Utterance], report: Report) {
        var report = Report()
        var out = utterances

        if echoPresent, let audio {
            let mine = out.filter { $0.speakerID == TranscriptBuilder.meID }
            let others = out.filter { $0.speakerID != TranscriptBuilder.meID }
            if !mine.isEmpty, !others.isEmpty {
                let judged = judge(fragments(of: mine.flatMap(\.words)), remote: others, audio: audio, voices: voices)
                var kept: [Word] = []
                for f in judged {
                    let dropped = f.echo.filter { $0 }.count
                    if dropped == 0 { kept += f.words; continue }
                    report.echoFragments += 1
                    report.echoWords += dropped
                    kept += zip(f.words, f.echo).filter { !$0.1 }.map(\.0)
                }
                if report.echoWords > 0 {
                    let rebuilt = TranscriptBuilder.group(kept.map { ($0, TranscriptBuilder.meID) })
                    out = (others + rebuilt).sorted { $0.start < $1.start }
                }
            }
        }

        for i in out.indices {
            let before = out[i].words.count
            out[i].words = tidy(out[i].words)
            report.loopWords += before - out[i].words.count
            out[i].text = out[i].words.map(\.text).joined(separator: " ")
            if let first = out[i].words.first, let last = out[i].words.last {
                out[i].start = first.start
                out[i].end = last.end
            }
        }
        out.removeAll { $0.words.isEmpty || $0.text.normalizedWord.isEmpty }
        return (TranscriptBuilder.mergeAdjacent(out), report)
    }

    // MARK: - Echo fragments

    static func fragments(of words: [Word]) -> [Fragment] {
        var out: [Fragment] = []
        for w in words.sorted(by: { $0.start < $1.start }) {
            if let last = out.last?.words.last, w.start - last.end <= 0.45 {
                out[out.count - 1].words.append(w)
            } else {
                out.append(Fragment(words: [w]))
            }
        }
        return out
    }

    /// Mic voices that belong to call participants: they sound like one of them, more than like you,
    /// and they turn up mostly while the call is talking.
    static func echoVoices(_ voices: Voices, remote intervals: [(Double, Double)]) -> Set<String> {
        var total: [String: Double] = [:], inRemote: [String: Double] = [:]
        for seg in voices.micSegments {
            total[seg.speaker, default: 0] += seg.end - seg.start
            inRemote[seg.speaker, default: 0] += coverage(start: seg.start, end: seg.end, by: intervals) * (seg.end - seg.start)
        }
        func share(_ id: String) -> Double { (inRemote[id] ?? 0) / max(total[id] ?? 0, 0.01) }
        func callSimilarity(_ e: [Float]) -> Float { voices.callVoices.map { Cosine.similarity($0, e) }.max() ?? 0 }
        // You: the voices on your mic that mostly speak while the call is quiet and sound like nobody on it.
        let you = voices.micSpeakers.filter { share($0.id) < 0.3 && callSimilarity($0.embedding) < 0.5 }
        var echo = Set<String>()
        for s in voices.micSpeakers where share(s.id) >= 0.4 {
            let call = callSimilarity(s.embedding)
            let me = you.map { Cosine.similarity($0.embedding, s.embedding) }.max() ?? 0
            if call >= 0.5, call > me { echo.insert(s.id) }
        }
        return echo
    }

    static func judge(_ input: [Fragment], remote: [Utterance], audio: Audio, voices: Voices?) -> [Fragment] {
        let intervals = speechIntervals(remote.flatMap(\.words))
        let remoteWords = remote.flatMap(\.words).sorted { $0.start < $1.start }
        let micEnv = envelope(audio.mic), sysEnv = envelope(audio.system)
        let echoIDs = voices.map { echoVoices($0, remote: intervals) } ?? []
        let segments = SegmentIndex(voices?.micSegments ?? [])

        var fragments = input
        for i in fragments.indices {
            let f = fragments[i]
            fragments[i].overlap = coverage(start: f.start, end: f.end, by: intervals)
            fragments[i].contour = contourCorrelation(start: f.start, end: f.end, mic: micEnv, system: sysEnv)
            fragments[i].textMatch = textMatch(f.words, remote: remoteWords)
            fragments[i].relativeLevel = level(start: f.start, end: f.end, env: micEnv)
        }
        // Your typical voice: fragments spoken while the call was quiet.
        let solo = fragments.filter { $0.overlap < 0.2 && $0.words.count >= 3 }.map(\.relativeLevel).sorted()
        let typical = solo.isEmpty ? 0 : solo[solo.count / 2]

        for i in fragments.indices {
            fragments[i].relativeLevel -= typical
            let f = fragments[i]
            fragments[i].echo = f.words.map { _ in false }
            // Nobody on the call was speaking: whatever this is, it isn't their echo.
            guard f.overlap >= 0.3 else { continue }
            // A full sentence at your own loudness, heard confidently, that the call didn't say is yours,
            // whatever the voice check thinks (it can blur where you and someone else meet).
            let confident = f.words.compactMap(\.p).isEmpty
                || Double(f.words.compactMap(\.p).reduce(0, +)) / Double(f.words.count) >= 0.8
            if f.words.count >= 5, f.relativeLevel >= 0, f.textMatch < 0.3, confident { continue }
            let fallback = looksLikeEcho(f)
            var echo: [Bool] = []
            var votes: [String: Double] = [:]
            for w in f.words {
                // Echo needs the call to be playing at that moment (or to be faint, as residue of a quiet talker is).
                guard callPlaying(start: w.start, end: w.end, system: sysEnv) || f.relativeLevel <= -10 else {
                    echo.append(false); continue
                }
                if let id = segments.voice(of: w) {
                    votes[id, default: 0] += w.end - w.start
                    echo.append(echoIDs.contains(id))
                } else {
                    echo.append(segments.isEmpty ? fallback : fallback && f.overlap >= 0.8)
                }
            }
            fragments[i].voice = votes.max { $0.value < $1.value }?.key
            fragments[i].voiceIsEcho = fragments[i].voice.map { echoIDs.contains($0) }
            fragments[i].echo = settle(echo, durations: f.words.map { max($0.end - $0.start, 0.05) })
        }
        return fragments
    }

    /// A fragment is one utterance. Mostly echo: all of it goes. Otherwise it's your sentence, and only a
    /// run of three or more echo words at its start or end (the call talking over your last words) goes;
    /// a stray word in the middle is more likely a diarization slip than echo.
    static func settle(_ echo: [Bool], durations: [Double]) -> [Bool] {
        guard !echo.isEmpty else { return echo }
        let total = durations.reduce(0, +)
        let share = zip(echo, durations).filter(\.0).reduce(0) { $0 + $1.1 } / max(total, 0.01)
        if share >= 0.6 { return echo.map { _ in true } }
        var out = echo.map { _ in false }
        let lead = echo.prefix { $0 }.count, trail = echo.reversed().prefix { $0 }.count
        if lead >= 3 { for k in 0..<lead { out[k] = true } }
        if trail >= 3 { for k in (echo.count - trail)..<echo.count { out[k] = true } }
        return out
    }

    /// The audio-only test, for words the voice check can't place.
    static func looksLikeEcho(_ f: Fragment) -> Bool {
        guard f.overlap >= 0.5 else { return false }
        let short = f.words.count <= 3
        if f.textMatch >= 0.5 { return true }
        if f.contour >= (short ? 0.5 : 0.6) && f.relativeLevel <= -4 { return true }
        if f.relativeLevel <= -10 { return true }
        return false
    }

    /// Diarization segments by the seconds they cover, so a word finds its segment even inside a long one.
    struct SegmentIndex {
        private var buckets: [Int: [DiarSegment]] = [:]
        init(_ segments: [DiarSegment]) {
            for seg in segments {
                for second in Int(seg.start)...Int(seg.end) { buckets[second, default: []].append(seg) }
            }
        }
        var isEmpty: Bool { buckets.isEmpty }

        /// The voice speaking during this word (or within 0.3 s of it).
        func voice(of w: Word) -> String? {
            var best: (Double, String)?
            var nearest: (Double, String)?
            var seen = Set<DiarSegment>()
            for second in Int(w.start - 0.3)...Int(w.end + 0.3) {
                for s in buckets[second] ?? [] where seen.insert(s).inserted {
                    let overlap = min(s.end, w.end) - max(s.start, w.start)
                    if overlap > 0, overlap > (best?.0 ?? 0) { best = (overlap, s.speaker) }
                    let distance = overlap > 0 ? 0 : min(abs(s.start - w.end), abs(w.start - s.end))
                    if distance <= 0.3, distance < (nearest?.0 ?? .infinity) { nearest = (distance, s.speaker) }
                }
            }
            return best?.1 ?? nearest?.1
        }
    }

    /// The call audio carried sound around this word (with 150 ms either side for the echo delay).
    private static func callPlaying(start: Double, end: Double, system: [Float]) -> Bool {
        let lo = max(0, Int((start - 0.15) * 100)), hi = min(system.count, Int((end + 0.15) * 100) + 1)
        guard lo < hi else { return false }
        let active = system[lo..<hi].filter { $0 > -42 }.count
        return Double(active) / Double(hi - lo) >= 0.25
    }

    /// Remote speech as time intervals (words closer than 0.6 s joined), padded slightly.
    private static func speechIntervals(_ words: [Word]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for w in words.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, w.start - last.1 <= 0.6 {
                out[out.count - 1].1 = max(last.1, w.end)
            } else {
                out.append((w.start, w.end))
            }
        }
        return out.map { ($0.0 - 0.2, $0.1 + 0.2) }
    }

    private static func coverage(start: Double, end: Double, by intervals: [(Double, Double)]) -> Double {
        let span = max(end - start, 0.05)
        var covered = 0.0
        // Binary search for the first interval that could overlap.
        var lo = 0, hi = intervals.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if intervals[mid].1 < start { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < intervals.count, intervals[i].0 < end {
            covered += max(0, min(end, intervals[i].1) - max(start, intervals[i].0))
            i += 1
        }
        return min(1, covered / span)
    }

    private static func textMatch(_ words: [Word], remote: [Word]) -> Double {
        guard !words.isEmpty, !remote.isEmpty else { return 0 }
        // A lone common word ("so", "the") matches something within 2.5 s by chance; keep it closer.
        let window = words.count <= 2 ? 1.2 : 2.5
        var matched = 0
        for w in words {
            let target = w.text.normalizedWord
            guard !target.isEmpty else { continue }
            var lo = 0, hi = remote.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if remote[mid].start < w.start - window { lo = mid + 1 } else { hi = mid }
            }
            var j = lo
            while j < remote.count, remote[j].start <= w.start + window {
                if similarity(target, remote[j].text.normalizedWord) >= 0.75 { matched += 1; break }
                j += 1
            }
        }
        return Double(matched) / Double(words.count)
    }

    /// 1 - normalized edit distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    // MARK: Loudness contours (10 ms frames, dB)

    private static let frame = 160

    static func envelope(_ x: [Float]) -> [Float] {
        let n = x.count / frame
        var out = [Float](repeating: -90, count: n)
        x.withUnsafeBufferPointer { p in
            for i in 0..<n {
                var acc: Float = 0
                let base = i * frame
                for k in 0..<frame { acc += p[base + k] * p[base + k] }
                out[i] = 10 * log10(max(acc / Float(frame), 1e-9))
            }
        }
        return out
    }

    private static func frames(_ start: Double, _ end: Double, count: Int) -> Range<Int>? {
        // At least 0.6 s, so a one-word fragment still has a contour to compare.
        let mid = (start + end) / 2, half = max((end - start) / 2 + 0.1, 0.3)
        let lo = max(0, Int((mid - half) * 100)), hi = min(count, Int((mid + half) * 100))
        return lo < hi - 10 ? lo..<hi : nil
    }

    private static func level(start: Double, end: Double, env: [Float]) -> Double {
        guard let r = frames(start, end, count: env.count) else { return -90 }
        // Loudness of the voiced part: the upper quartile of frames.
        let sorted = env[r].sorted()
        return Double(sorted[sorted.count * 3 / 4])
    }

    /// Best Pearson correlation between the two contours for echo delays of 0-120 ms.
    private static func contourCorrelation(start: Double, end: Double, mic: [Float], system: [Float]) -> Double {
        guard let r = frames(start, end, count: min(mic.count, system.count)) else { return 0 }
        let floor: Float = -70
        let m = mic[r].map { max($0, floor) }
        var best = 0.0
        for lag in 0...12 {
            let lo = r.lowerBound - lag
            guard lo >= 0 else { continue }
            let s = system[lo..<(lo + r.count)].map { max($0, floor) }
            best = max(best, pearson(m, s))
        }
        return best
    }

    private static func pearson(_ a: [Float], _ b: [Float]) -> Double {
        let n = Double(a.count)
        guard n > 2 else { return 0 }
        let ma = Double(a.reduce(0, +)) / n, mb = Double(b.reduce(0, +)) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let x = Double(a[i]) - ma, y = Double(b[i]) - mb
            num += x * y; da += x * x; db += y * y
        }
        guard da > 1e-6, db > 1e-6 else { return 0 }
        return num / (da * db).squareRoot()
    }

    // MARK: - Whisper artifacts

    /// Strips dialogue dashes and collapses a phrase repeated three or more times in a row.
    static func tidy(_ words: [Word]) -> [Word] {
        var out: [Word] = words.compactMap { w in
            var w = w
            while let first = w.text.first, first == "-" || first == "–" || first == "—" {
                w.text.removeFirst()
                w.text = w.text.trimmingCharacters(in: .whitespaces)
            }
            return w.text.isEmpty ? nil : w
        }
        // Repetition loops: n-grams of 1-6 words repeated 3+ times back to back keep one copy.
        var i = 0
        while i < out.count {
            var collapsed = false
            for n in 1...6 where i + 3 * n <= out.count {
                let gram = out[i..<(i + n)].map(\.text.normalizedWord)
                var repeats = 1
                while i + (repeats + 1) * n <= out.count,
                      out[(i + repeats * n)..<(i + (repeats + 1) * n)].map(\.text.normalizedWord) == gram {
                    repeats += 1
                }
                if repeats >= (n == 1 ? 4 : 3) { // "no, no, no" is speech; four of one word is a loop
                    out.removeSubrange((i + n)..<(i + repeats * n))
                    collapsed = true
                    break
                }
            }
            if !collapsed { i += 1 }
        }
        return out
    }
}
