import FluidAudio
import Foundation

/// Speaker diarization (pyannote Community-1), voice-activity detection (Silero), and the optional
/// Parakeet recognizer, all from FluidAudio's Core ML ports so they run on the Neural Engine.
actor FluidBackend {
    private var vad: VadManager?
    private var diarizer: OfflineDiarizerManager?
    private var parakeet: AsrManager?
    private var parakeetLayers = 2

    func loadVAD() async throws {
        guard vad == nil else { return }
        // 0.5 is Silero's standard threshold; FluidAudio's 0.85 default is tuned for studio-clean speech.
        vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5))
    }

    func loadDiarizer() async throws {
        guard diarizer == nil else { return }
        // pyannote's reference Community-1 settings (FluidAudio's default trades ~1.2 DER points for 2x speed).
        let config = OfflineDiarizerConfig(segmentationStepRatio: 0.1, minSegmentDuration: 0.0)
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        diarizer = manager
    }

    func loadParakeet() async throws {
        guard parakeet == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        parakeet = manager
        parakeetLayers = await manager.decoderLayerCount
    }

    /// 16 kHz mono samples (the format every model here and Whisper expect).
    func loadSamples(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }

    /// Speech regions grouped into chunks of up to `maxChunk` seconds for Whisper's 30 s window.
    /// Silence is never sent to Whisper, which is where it tends to invent text.
    func speechChunks(_ samples: [Float], maxChunk: Double = 28) async throws -> [SpeechChunk] {
        guard let vad else { throw TranscriptionEngine.EngineError.notReady }
        let config = VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.6,
                                           maxSpeechDuration: 24, speechPadding: 0.3)
        let segments = try await vad.segmentSpeech(samples, config: config)
        var chunks: [SpeechChunk] = []
        for s in segments {
            if var last = chunks.last, s.endTime - last.start <= maxChunk, s.startTime - last.end <= 2.0 {
                last.end = s.endTime
                chunks[chunks.count - 1] = last
            } else {
                chunks.append(SpeechChunk(start: s.startTime, end: s.endTime))
            }
        }
        return chunks
    }

    func transcribeWithParakeet(samples: [Float]) async throws -> [Word] {
        guard let parakeet else { throw TranscriptionEngine.EngineError.notReady }
        guard samples.count >= 16_000 / 2 else { return [] }
        var state = TdtDecoderState.make(decoderLayers: parakeetLayers)
        do {
            let result = try await parakeet.transcribe(samples, decoderState: &state)
            return buildWordTimings(from: result.tokenTimings ?? []).map {
                Word(text: $0.word, start: $0.startTime, end: $0.endTime)
            }
        } catch ASRError.invalidAudioData {
            return []
        }
    }

    var parakeetLoaded: Bool { parakeet != nil }

    /// Parakeet's words for one stretch of speech, on that stretch's own timeline.
    func parakeetWords(_ samples: [Float]) async throws -> [Word] {
        guard let parakeet else { throw TranscriptionEngine.EngineError.notReady }
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: parakeetLayers)
        do {
            let result = try await parakeet.transcribe(audio, decoderState: &state)
            return buildWordTimings(from: result.tokenTimings ?? []).map {
                Word(text: $0.word, start: $0.startTime, end: $0.endTime)
            }
        } catch ASRError.invalidAudioData {
            return []
        }
    }

    func diarize(samples: [Float]) async throws -> TranscriptionEngine.Diarization {
        guard let diarizer else { throw TranscriptionEngine.EngineError.notReady }
        let result = try await diarizer.process(audio: samples)
        let segments = result.segments.map {
            DiarSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        var speakers: [TranscriptionEngine.DiarizedSpeaker] = []
        for id in Set(result.segments.map(\.speakerId)).sorted() {
            let embedding = result.speakerDatabase?[id]
                ?? Cosine.mean(result.segments.filter { $0.speakerId == id }.map(\.embedding))
            if let embedding { speakers.append(.init(id: id, embedding: embedding)) }
        }
        return .init(segments: segments, speakers: speakers)
    }
}

struct SpeechChunk: Sendable {
    var start: Double
    var end: Double
}
