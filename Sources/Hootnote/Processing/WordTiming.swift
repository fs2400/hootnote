import Foundation

/// Puts Whisper's words on precise times.
///
/// Whisper gets the words right (and spells your vocabulary), but its word timestamps come from
/// attention weights and drift by a few hundred milliseconds, which is enough for the highlighted
/// word to run ahead of or behind the voice. NVIDIA's Parakeet TDT predicts a duration for every
/// token it emits, so its word times are tight. Both transcribe the same speech; this lines the two
/// word sequences up and moves each Whisper word onto its Parakeet twin's times. Words Parakeet heard
/// differently are spread between the nearest matched words.
enum WordTiming {
    struct Result {
        var words: [Word]
        var matched: Int
    }

    /// - Parameters:
    ///   - words: Whisper's words for one stretch of speech.
    ///   - reference: Parakeet's words for the same stretch.
    static func align(_ words: [Word], to reference: [Word]) -> Result {
        guard !words.isEmpty, !reference.isEmpty else { return Result(words: words, matched: 0) }
        let a = words.map(\.text.normalizedWord), b = reference.map(\.text.normalizedWord)
        let n = a.count, m = b.count
        // Needleman–Wunsch: similar words close in time score, gaps cost a little.
        let gap = -0.4
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var move = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1) // 0 diag, 1 up, 2 left
        for i in 1...n { score[i][0] = Double(i) * gap; move[i][0] = 1 }
        for j in 1...m { score[0][j] = Double(j) * gap; move[0][j] = 2 }
        for i in 1...n {
            for j in 1...m {
                let diag = score[i - 1][j - 1] + pairScore(a[i - 1], b[j - 1], words[i - 1].start - reference[j - 1].start)
                let up = score[i - 1][j] + gap, left = score[i][j - 1] + gap
                if diag >= up && diag >= left { score[i][j] = diag; move[i][j] = 0 }
                else if up >= left { score[i][j] = up; move[i][j] = 1 }
                else { score[i][j] = left; move[i][j] = 2 }
            }
        }
        var pair = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 || j > 0 {
            switch (i > 0 && j > 0) ? move[i][j] : (i > 0 ? 1 : 2) {
            case 0:
                if pairScore(a[i - 1], b[j - 1], words[i - 1].start - reference[j - 1].start) > 0 { pair[i - 1] = j - 1 }
                i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }

        var out = words
        let anchors = pair.enumerated().compactMap { k, r in r.map { (k, $0) } }
        for (k, r) in anchors {
            // Parakeet's starts are tight; a word's end can run on into the following pause, so cap it
            // near the word's own length.
            let length = min(max((words[k].end - words[k].start) * 1.3, 0.12), 1.2)
            out[k].start = reference[r].start
            out[k].end = max(min(reference[r].end, reference[r].start + length), reference[r].start + 0.06)
        }
        // Unmatched runs move with their matched neighbours (the shift blended across the run), staying
        // between them.
        var k = 0
        while k < n {
            guard pair[k] == nil else { k += 1; continue }
            var e = k
            while e + 1 < n && pair[e + 1] == nil { e += 1 }
            let shiftBefore = k > 0 ? out[k - 1].start - words[k - 1].start : nil
            let shiftAfter = e + 1 < n ? out[e + 1].start - words[e + 1].start : nil
            let floor = k > 0 ? out[k - 1].end : -Double.infinity
            let ceiling = e + 1 < n ? out[e + 1].start : Double.infinity
            for idx in k...e {
                let f = Double(idx - k + 1) / Double(e - k + 2)
                let shift: Double
                switch (shiftBefore, shiftAfter) {
                case let (b?, a?): shift = b + (a - b) * f
                case let (b?, nil): shift = b
                case let (nil, a?): shift = a
                default: shift = 0
                }
                let length = max(words[idx].end - words[idx].start, 0.06)
                let start = min(max(words[idx].start + shift, floor), ceiling)
                out[idx].start = start
                out[idx].end = min(start + length, max(ceiling, start + 0.06))
            }
            k = e + 1
        }
        // Keep the order monotonic whatever happened above.
        for idx in 1..<max(n, 1) where out[idx].start < out[idx - 1].start {
            out[idx].start = out[idx - 1].start
            out[idx].end = max(out[idx].end, out[idx].start)
        }
        return Result(words: out, matched: anchors.count)
    }

    private static func pairScore(_ x: String, _ y: String, _ dt: Double) -> Double {
        guard !x.isEmpty, !y.isEmpty, abs(dt) < 3 else { return -1 }
        let s = TranscriptCleaner.similarity(x, y)
        guard s >= 0.6 else { return -1 }
        return 2 * s - 0.2 - min(abs(dt), 2) * 0.1
    }
}
