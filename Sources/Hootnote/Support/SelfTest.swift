import Foundation

/// Runs the processing pipeline on a folder containing mic.caf + system.caf and prints the result.
/// Used to verify echo cancellation, Whisper and pyannote without a live call.
enum SelfTest {
    static func run(folder: URL, model: TranscriptionModel) async {
        let engine = TranscriptionEngine.shared
        do {
            var t = Date()
            try await engine.prepare(model: model) { print("[status] \($0)") }
            print(String(format: "models ready in %.1fs", Date().timeIntervalSince(t)))

            var mic = try await engine.loadSamples(folder.appendingPathComponent("mic.caf"))
            let system = try await engine.loadSamples(folder.appendingPathComponent("system.caf"))
            let n = min(mic.count, system.count)
            mic = Array(mic.prefix(n))
            t = Date()
            let aec = await engine.cancelEcho(mic: mic, reference: Array(system.prefix(n)))
            print(String(format: "AEC: %@ in %.2fs", aec.report.description, Date().timeIntervalSince(t)))
            try AudioFiles.writeAAC(channels: [aec.output, Array(system.prefix(n))], to: folder.appendingPathComponent("recording.m4a"))
            try AudioFiles.writeAAC(channels: [aec.output], to: folder.appendingPathComponent("mic-clean.m4a"))

            let options = WhisperOptions(language: "en", vocabulary: ProcessInfo.processInfo.environment["VOCAB"] ?? "")
            t = Date()
            let micRaw = try await engine.transcribe(samples: mic, options: options) { _ in }
            print("mic BEFORE echo cancellation: \(micRaw.map(\.text).joined(separator: " "))")
            let micWords = try await engine.transcribe(samples: aec.output, options: options) { _ in }
            print(String(format: "mic AFTER (%d words, %.1fs): ", micWords.count, Date().timeIntervalSince(t)) + micWords.map(\.text).joined(separator: " "))
            let systemWords = try await engine.transcribe(samples: system, options: options) { _ in }
            let diar = try await engine.diarize(samples: system)
            print("diarization: \(diar.segments.count) segments, \(diar.speakers.count) speakers")
            let built = TranscriptBuilder.build(micWords: micWords, systemWords: systemWords, systemSegments: diar.segments)
            print("text echo filter removed \(built.echoWordsRemoved) words")
            print("speaker map: \(built.speakerMap)")
            for u in built.utterances {
                print(String(format: "[%6.2f-%6.2f] %@: %@", u.start, u.end, u.speakerID, u.text))
            }
            if diar.speakers.count >= 2 {
                let a = diar.speakers[0].embedding, b = diar.speakers[1].embedding
                print(String(format: "cosine(speaker0, speaker1) = %.3f", Cosine.similarity(a, b)))
            }
        } catch {
            print("ERROR: \(error)")
        }
    }
}
