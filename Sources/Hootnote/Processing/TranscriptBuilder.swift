import Foundation

/// Turns two word streams (your mic, the call audio) plus diarization into a
/// readable, speaker-labeled transcript.
enum TranscriptBuilder {
    static let meID = "me"

    struct Output {
        var utterances: [Utterance]
        /// Track-prefixed diarizer id ("sys:<id>" / "mic:<id>") -> transcript speaker id ("S1", "S2", …),
        /// numbered in order of first appearance.
        var speakerMap: [String: String]
        var echoWordsRemoved: Int
    }

    /// - Parameters:
    ///   - micSegments: when set (in-person recordings), the mic is diarized too instead of
    ///     being labeled as you.
    static func build(micWords: [Word], systemWords: [Word],
                      systemSegments: [DiarSegment], micSegments: [DiarSegment]? = nil) -> Output {
        let systemLabeled = label(systemWords, with: systemSegments, prefix: "sys:")
        var micInput = micWords
        var removed = 0
        if micSegments == nil, !systemWords.isEmpty {
            // Safety net behind the audio echo canceller: drop mic words that repeat what the
            // call audio said at the same moment. Word-level, so your own speech is never dropped
            // just because it sits next to an echoed phrase.
            let before = micInput.count
            micInput = removeEchoedWords(micInput, index: WordIndex(systemWords))
            removed = before - micInput.count
        }
        let micLabeled: [(Word, String)] = micSegments.map { label(micInput, with: $0, prefix: "mic:") }
            ?? micInput.map { ($0, meID) }

        let micUtterances = group(micLabeled)
        let systemUtterances = group(systemLabeled)

        // Fragments with no letters or digits (a stray "%" or "-") aren't speech.
        var all = (micUtterances + systemUtterances)
            .filter { !$0.text.normalizedWord.isEmpty }
            .sorted { $0.start < $1.start }

        // Stable, human-friendly ids in order of first appearance.
        var map: [String: String] = [:]
        var next = 1
        for u in all where u.speakerID != meID && map[u.speakerID] == nil {
            map[u.speakerID] = "S\(next)"
            next += 1
        }
        for i in all.indices where all[i].speakerID != meID {
            all[i].speakerID = map[all[i].speakerID] ?? all[i].speakerID
        }
        return Output(utterances: mergeAdjacent(all), speakerMap: map, echoWordsRemoved: removed)
    }

    // MARK: - Speaker assignment

    private static func label(_ words: [Word], with segments: [DiarSegment], prefix: String) -> [(Word, String)] {
        guard !segments.isEmpty else { return words.map { ($0, prefix + "0") } }
        let sorted = segments.sorted { $0.start < $1.start }
        var result: [(Word, String)] = []
        var lastSpeaker = prefix + sorted[0].speaker
        var lo = 0
        for w in words {
            // Segments ending well before this word can't match it or any later word.
            while lo < sorted.count - 1 && sorted[lo].end < w.start - 5 { lo += 1 }
            var best: (overlap: Double, speaker: String)? = nil
            var nearest: (distance: Double, speaker: String)? = nil
            var j = lo
            while j < sorted.count && sorted[j].start <= w.end + 5 {
                let s = sorted[j]
                let overlap = min(s.end, w.end) - max(s.start, w.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (overlap, s.speaker) }
                let distance = overlap > 0 ? 0 : min(abs(s.start - w.end), abs(w.start - s.end))
                if distance < (nearest?.distance ?? .infinity) { nearest = (distance, s.speaker) }
                j += 1
            }
            if let best {
                lastSpeaker = prefix + best.speaker
            } else if let nearest, nearest.distance < 1.5 {
                lastSpeaker = prefix + nearest.speaker
            }
            result.append((w, lastSpeaker))
        }
        return result
    }

    // MARK: - Grouping into paragraphs

    static func group(_ words: [(Word, String)]) -> [Utterance] {
        var out: [Utterance] = []
        var current: [Word] = []
        var speaker = ""

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            out.append(Utterance(speakerID: speaker, start: first.start, end: last.end, text: text, words: current))
            current = []
        }

        for (w, s) in words {
            if let last = current.last {
                let gap = w.start - last.end
                let long = last.end - (current.first?.start ?? last.end) > 40
                let sentenceEnd = last.text.last.map { ".?!".contains($0) } ?? false
                if s != speaker || gap > 1.6 || (long && sentenceEnd) {
                    flush()
                }
            }
            speaker = s
            current.append(w)
        }
        flush()
        return out
    }

    /// Joins consecutive paragraphs by the same speaker separated by a short pause.
    static func mergeAdjacent(_ utterances: [Utterance]) -> [Utterance] {
        var out: [Utterance] = []
        for u in utterances {
            if var last = out.last, last.speakerID == u.speakerID, u.start - last.end < 1.0,
               last.end - last.start < 40 {
                last.words += u.words
                last.text += " " + u.text
                last.end = max(last.end, u.end)
                out[out.count - 1] = last
            } else {
                out.append(u)
            }
        }
        return out
    }

    // MARK: - Echo removal

    private struct WordIndex {
        var buckets: [Int: [Word]] = [:]
        init(_ words: [Word]) {
            for w in words { buckets[Int(w.start), default: []].append(w) }
        }
        func contains(_ word: Word, tolerance: Double = 0.9) -> Bool {
            let target = word.text.normalizedWord
            guard !target.isEmpty else { return false }
            let second = Int(word.start)
            for b in (second - 1)...(second + 1) {
                if buckets[b]?.contains(where: { abs($0.start - word.start) <= tolerance && $0.text.normalizedWord == target }) == true {
                    return true
                }
            }
            return false
        }
    }

    /// Removes runs of 2+ mic words that match the call audio in time, plus lone matched words
    /// with no other mic speech within a second (a stray echoed "yes" or "okay").
    private static func removeEchoedWords(_ words: [Word], index: WordIndex) -> [Word] {
        let matched = words.map { index.contains($0) }
        var keep = [Bool](repeating: true, count: words.count)
        var i = 0
        while i < words.count {
            guard matched[i] else { i += 1; continue }
            var j = i
            while j + 1 < words.count && matched[j + 1] { j += 1 }
            let runLength = j - i + 1
            let isolated = (i == 0 || words[i].start - words[i - 1].end > 1.0)
                && (j == words.count - 1 || words[j + 1].start - words[j].end > 1.0)
            if runLength >= 2 || isolated {
                for k in i...j { keep[k] = false }
            }
            i = j + 1
        }
        return zip(words, keep).filter(\.1).map(\.0)
    }
}
