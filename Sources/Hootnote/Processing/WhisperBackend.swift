import CoreML
import Foundation
import WhisperKit

struct WhisperOptions: Sendable {
    /// Whisper language code, or nil to detect.
    var language: String?
    /// Names and jargon to bias spelling toward (Whisper's "initial prompt").
    var vocabulary: String
}

/// OpenAI Whisper (Large-v3 / Large-v3 Turbo) via WhisperKit's Core ML build.
actor WhisperBackend {
    private var kit: WhisperKit?
    private var loadedVariant: String?

    private static var downloadBase: URL {
        let url = AppPaths.appSupport.appendingPathComponent("Models/whisperkit", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Known Whisper hallucinations on near-silent audio (from Whisper's subtitle-heavy training data).
    private static let hallucinations: Set<String> = [
        "thankyou", "thankyouverymuch", "thanksforwatching", "thankyouforwatching", "pleasesubscribe",
        "subscribe", "you", "subtitlesbytheamaraorgcommunity", "transcribedby", "music",
    ]

    func load(variant: String, status: @escaping @Sendable (String) -> Void) async throws {
        if loadedVariant == variant, kit != nil { return }
        kit = nil
        let defaultsKey = "whisperModelFolder.\(variant)"
        var folder = UserDefaults.standard.string(forKey: defaultsKey).map { URL(fileURLWithPath: $0) }
        let present = folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("AudioEncoder.mlmodelc").path) } ?? false
        if !present {
            status("Downloading Whisper (one time)…")
            folder = try await WhisperKit.download(variant: variant, downloadBase: Self.downloadBase) { progress in
                status("Downloading Whisper (one time)… \(Int(progress.fractionCompleted * 100))%")
            }
            UserDefaults.standard.set(folder?.path, forKey: defaultsKey)
        }
        status("Loading Whisper. The first load tunes it for this Mac and can take a few minutes…")
        let config = WhisperKitConfig(model: variant, downloadBase: Self.downloadBase, modelFolder: folder?.path,
                                      segmentSeeker: PromptAlignedSegmentSeeker(),
                                      verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
        kit = try await WhisperKit(config)
        loadedVariant = variant
    }

    /// Transcribes only the given speech chunks of `samples` (16 kHz mono) and returns words on the
    /// file's timeline.
    func transcribe(samples: [Float], chunks: [SpeechChunk], options: WhisperOptions,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        guard let kit else { throw TranscriptionEngine.EngineError.notReady }

        var decode = DecodingOptions()
        decode.task = .transcribe
        decode.language = options.language
        decode.detectLanguage = options.language == nil
        decode.usePrefillPrompt = true
        decode.temperature = 0
        decode.skipSpecialTokens = true
        decode.withoutTimestamps = false
        decode.wordTimestamps = true
        decode.suppressBlank = true
        decode.chunkingStrategy = ChunkingStrategy.none
        let vocabulary = options.vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
            let tokens = tokenizer.encode(text: " " + vocabulary).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            decode.promptTokens = Array(tokens.suffix(PromptAlignedSegmentSeeker.maxPromptTokens))
        }

        let sampleRate = 16_000.0
        var words: [Word] = []
        let batchSize = 6
        for batchStart in stride(from: 0, to: chunks.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(chunks[batchStart..<min(batchStart + batchSize, chunks.count)])
            let arrays: [[Float]] = batch.map { c in
                let lo = max(0, Int(c.start * sampleRate)), hi = min(samples.count, Int(c.end * sampleRate))
                return lo < hi ? Array(samples[lo..<hi]) : []
            }
            let results = await kit.transcribeWithResults(audioArrays: arrays, decodeOptions: decode)
            for (chunk, result) in zip(batch, results) {
                switch result {
                case .success(let r): words += Self.words(from: r, offset: chunk.start)
                case .failure(let error): log.error("Whisper chunk at \(chunk.start)s failed: \(error.localizedDescription)")
                }
            }
            progress(Double(min(batchStart + batchSize, chunks.count)) / Double(max(chunks.count, 1)))
        }
        return words
    }

    private static func words(from results: [TranscriptionResult], offset: Double) -> [Word] {
        var out: [Word] = []
        for segment in results.flatMap(\.segments) {
            // Whisper's own "this window is silence" rule, plus its stock phrases for near-silence.
            if segment.noSpeechProb > 0.6 && segment.avgLogprob < -1.0 { continue }
            let normalized = segment.text.normalizedWord
            if normalized.isEmpty { continue }
            // Real closing "Thank you"s are confident speech; hallucinated ones look like near-silence.
            if hallucinations.contains(normalized) && segment.noSpeechProb > 0.3 { continue }

            if let timed = segment.words, !timed.isEmpty {
                for w in timed {
                    let text = w.word.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty, !text.hasPrefix("<|") else { continue }
                    out.append(Word(text: text, start: Double(w.start) + offset, end: Double(w.end) + offset, p: w.probability))
                }
            } else {
                // No word timings: spread the segment's words evenly over its span.
                let pieces = segment.text.split(separator: " ").map(String.init).filter { !$0.hasPrefix("<|") }
                let span = Double(segment.end - segment.start) / Double(max(pieces.count, 1))
                for (i, p) in pieces.enumerated() {
                    let s = Double(segment.start) + Double(i) * span + offset
                    out.append(Word(text: p, start: s, end: s + span))
                }
            }
        }
        return out
    }
}

/// Fixes WhisperKit 1.1.1 word timestamps when a prompt (custom vocabulary) is used.
///
/// The decoder's cross-attention rows include the prompt (`<|startofprev|>` + prompt tokens), but the
/// segments' tokens start at `<|startoftranscript|>`. WhisperKit pairs them from row 0, so every word
/// lands a prompt-length early. This drops the prompt's rows before WhisperKit's own alignment runs.
final class PromptAlignedSegmentSeeker: SegmentSeeking {
    /// WhisperKit trims prompts to the last (maxTokenContext / 2 - 1) = 111 tokens; stay under it.
    static let maxPromptTokens = 100
    private let base = SegmentSeeker()

    func findSeekPointAndSegments(decodingResult: DecodingResult, options: DecodingOptions, allSegmentsCount: Int,
                                  currentSeek seek: Int, segmentSize: Int, sampleRate: Int, timeToken: Int,
                                  specialToken: Int, tokenizer: WhisperTokenizer) -> (Int, [TranscriptionSegment]?) {
        base.findSeekPointAndSegments(decodingResult: decodingResult, options: options, allSegmentsCount: allSegmentsCount,
                                      currentSeek: seek, segmentSize: segmentSize, sampleRate: sampleRate,
                                      timeToken: timeToken, specialToken: specialToken, tokenizer: tokenizer)
    }

    func addWordTimestamps(segments: [TranscriptionSegment], alignmentWeights: MLMultiArray, tokenizer: WhisperTokenizer,
                           seek: Int, segmentSize: Int, prependPunctuations: String, appendPunctuations: String,
                           lastSpeechTimestamp: Float, options: DecodingOptions,
                           timings: TranscriptionTimings) throws -> [TranscriptionSegment]? {
        let promptCount = options.promptTokens?.filter { $0 < tokenizer.specialTokens.specialTokenBegin }.count ?? 0
        // Verified against ground-truth timings: skipping exactly the prompt's rows matches
        // no-prompt accuracy (within ~0.3 s); one more row splits sentences between speakers.
        let offset = min(promptCount, Constants.maxTokenContext / 2 - 1)
        let weights = offset > 0 ? try Self.dropLeadingRows(alignmentWeights, count: offset) : alignmentWeights
        return try base.addWordTimestamps(segments: segments, alignmentWeights: weights, tokenizer: tokenizer, seek: seek,
                                          segmentSize: segmentSize, prependPunctuations: prependPunctuations,
                                          appendPunctuations: appendPunctuations, lastSpeechTimestamp: lastSpeechTimestamp,
                                          options: options, timings: timings)
    }

    private static func dropLeadingRows(_ array: MLMultiArray, count: Int) throws -> MLMultiArray {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 2, count < shape[0] else { return array }
        let rows = shape[0], columns = shape[1]
        let elementSize: Int
        switch array.dataType {
        case .float16: elementSize = 2
        case .float32: elementSize = 4
        case .double: elementSize = 8
        default: return array
        }
        let out = try MLMultiArray(shape: array.shape, dataType: array.dataType)
        array.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst, _ in
                let rowBytes = columns * elementSize
                memset(dst.baseAddress!, 0, rows * rowBytes)
                memcpy(dst.baseAddress!, src.baseAddress!.advanced(by: count * rowBytes), (rows - count) * rowBytes)
            }
        }
        return out
    }
}
