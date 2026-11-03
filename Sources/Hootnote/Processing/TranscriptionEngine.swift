import Foundation

/// The on-device speech pipeline, run per audio track:
///  0. Echo cancellation cleans the mic track, using the call track as reference.
///  1. Silero VAD finds the speech (silence is skipped).
///  2. OpenAI Whisper Large-v3 Turbo transcribes it with word timestamps.
///  3. pyannote Community-1 works out who spoke when, with a voice embedding per speaker.
/// Everything runs locally on Core ML; models download once and stay loaded between meetings.
actor TranscriptionEngine {
    static let shared = TranscriptionEngine()

    struct DiarizedSpeaker: Sendable {
        let id: String
        let embedding: [Float]
    }

    struct Diarization: Sendable {
        var segments: [DiarSegment]
        var speakers: [DiarizedSpeaker]
    }

    enum EngineError: LocalizedError {
        case notReady
        var errorDescription: String? { "Speech models aren't loaded yet." }
    }

    private let fluid = FluidBackend()
    private let whisper = WhisperBackend()
    private var model: TranscriptionModel?

    func prepare(model: TranscriptionModel, status: @escaping @Sendable (String) -> Void) async throws {
        if let variant = model.whisperVariant {
            try await whisper.load(variant: variant, status: status)
            status("Loading voice-activity model…")
            try await fluid.loadVAD()
            // Parakeet times Whisper's words (see WordTiming). Without it, Whisper's own times are used.
            status("Loading word-timing model (Parakeet, one-time download)…")
            do { try await fluid.loadParakeet() } catch { log.error("Parakeet unavailable, using Whisper's word times: \(error.localizedDescription)") }
        } else {
            status("Loading Parakeet…")
            try await fluid.loadParakeet()
        }
        status("Loading speaker-recognition model (pyannote)…")
        try await fluid.loadDiarizer()
        self.model = model
    }

    /// Decodes any audio file to 16 kHz mono.
    func loadSamples(_ url: URL) async throws -> [Float] {
        try await fluid.loadSamples(url)
    }

    /// Removes speaker echo from the mic track using the call track as the reference.
    /// - Parameter parts: where each separately recorded part starts (joined meetings), cancelled on its own.
    func cancelEcho(mic: [Float], reference: [Float], parts: [Double]? = nil) -> (output: [Float], linear: [Float], report: EchoCanceller.Report) {
        EchoCanceller.process(mic: mic, reference: reference, parts: parts)
    }

    /// Word-level transcript of one track (16 kHz mono). Empty when there's no speech.
    /// - Parameter retime: put words on Parakeet's precise times (off for dictation, which only needs the text).
    func transcribe(samples: [Float], options: WhisperOptions, retime: Bool = true,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        guard let model else { throw EngineError.notReady }
        guard model.isWhisper else { return try await fluid.transcribeWithParakeet(samples: samples) }
        let chunks = try await fluid.speechChunks(samples)
        guard !chunks.isEmpty else { return [] }
        let words = try await whisper.transcribe(samples: samples, chunks: chunks,
                                                 options: options) { progress($0 * 0.85) }
        guard retime, await fluid.parakeetLoaded else { return words }
        return try await self.retime(words, samples: samples, chunks: chunks) { progress(0.85 + $0 * 0.15) }
    }

    /// Moves Whisper's words onto Parakeet's word times, one speech chunk at a time.
    func retime(_ words: [Word], samples: [Float], chunks: [SpeechChunk],
                progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        var out: [Word] = []
        out.reserveCapacity(words.count)
        var cursor = 0
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            var inChunk: [Word] = []
            while cursor < words.count, words[cursor].start < chunk.end + 0.5 {
                inChunk.append(words[cursor]); cursor += 1
            }
            guard !inChunk.isEmpty else { continue }
            let lo = max(0, Int(chunk.start * 16_000)), hi = min(samples.count, Int(chunk.end * 16_000))
            let reference = lo < hi ? ((try? await fluid.parakeetWords(Array(samples[lo..<hi]))) ?? []) : []
            let shifted = reference.map { Word(text: $0.text, start: $0.start + chunk.start, end: $0.end + chunk.start) }
            let aligned = WordTiming.align(inChunk, to: shifted)
            // Too little agreement means they heard different things; keep Whisper's times then.
            out += Double(aligned.matched) >= Double(inChunk.count) * 0.4 ? aligned.words : inChunk
            if index % 10 == 0 { progress(Double(index) / Double(chunks.count)) }
        }
        out += words[cursor...]
        return out
    }

    /// For the timing check: Whisper's words, Parakeet's words, and the aligned result for the first chunks.
    func timingComparison(samples: [Float], options: WhisperOptions, chunkLimit: Int) async throws -> (whisper: [Word], parakeet: [Word]) {
        let chunks = Array(try await fluid.speechChunks(samples).prefix(chunkLimit))
        let words = try await whisper.transcribe(samples: samples, chunks: chunks, options: options) { _ in }
        var reference: [Word] = []
        for chunk in chunks {
            let lo = Int(chunk.start * 16_000), hi = min(samples.count, Int(chunk.end * 16_000))
            reference += try await fluid.parakeetWords(Array(samples[lo..<hi]))
                .map { Word(text: $0.text, start: $0.start + chunk.start, end: $0.end + chunk.start) }
        }
        return (words, reference)
    }

    /// Who spoke when, plus one voice embedding per speaker.
    func diarize(samples: [Float]) async throws -> Diarization {
        guard samples.count > 16_000 else { return Diarization(segments: [], speakers: []) }
        return try await fluid.diarize(samples: samples)
    }
}

struct DiarSegment: Sendable, Hashable {
    let speaker: String
    let start: Double
    let end: Double
}
