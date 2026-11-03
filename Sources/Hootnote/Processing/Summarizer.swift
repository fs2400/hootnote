import Foundation

/// Talks to a local Ollama server (https://ollama.com), so summaries and answers never leave the Mac.
struct OllamaClient {
    let baseURL: URL

    init?(urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) else { return nil }
        baseURL = url
    }

    enum OllamaError: LocalizedError {
        case badResponse(String)
        case modelMissing(String)
        case tooLarge(String, Int64, Int64)
        var errorDescription: String? {
            switch self {
            case .badResponse(let s): return "Ollama: \(s)"
            case .modelMissing(let m): return "The model \(m) isn't installed. Run `ollama pull \(m)` in Terminal, or pick another in Settings › AI."
            case .tooLarge(let m, let size, let budget):
                let f = ByteCountFormatter()
                return "\(m) needs about \(f.string(fromByteCount: size)), more than this Mac can spare safely (\(f.string(fromByteCount: budget))). Choose a smaller model in Settings › AI."
            }
        }
    }

    /// How hard a model should reason before answering.
    enum Thinking {
        case off, on
        /// gpt-oss reasoning effort: "low", "medium" or "high".
        case effort(String)

        var json: Any {
            switch self {
            case .off: return false
            case .on: return true
            case .effort(let e): return e
            }
        }
    }

    struct Message: Codable, Sendable {
        var role: String
        var content: String
    }

    func installedModels() async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name).sorted()
    }

    /// Largest model Hootnote will load: a share of physical memory that leaves room for macOS,
    /// Whisper and the call recorder. On an 18 GB Mac this is about 8 GB; a 14 GB model froze it.
    static var memoryBudgetBytes: Int64 { Int64(Double(ProcessInfo.processInfo.physicalMemory) * 0.45) }

    struct InstalledModel: Decodable { let name: String; let size: Int64 }

    func installed() async throws -> [InstalledModel] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Tags: Decodable { let models: [InstalledModel] }
        return try JSONDecoder().decode(Tags.self, from: data).models
    }

    /// Refuses models that aren't installed or are too big for this Mac, and unloads any other
    /// model Ollama is holding so two never sit in memory together.
    func prepare(_ model: String) async throws {
        let all = try await installed()
        let wanted = model.contains(":") ? model : model + ":latest"
        guard let entry = all.first(where: { $0.name == wanted || $0.name == model }) else {
            throw OllamaError.modelMissing(model)
        }
        guard entry.size <= Self.memoryBudgetBytes else {
            throw OllamaError.tooLarge(model, entry.size, Self.memoryBudgetBytes)
        }
        await unloadAll(except: entry.name)
    }

    private func unloadAll(except keep: String) async {
        var psReq = URLRequest(url: baseURL.appendingPathComponent("api/ps"))
        psReq.timeoutInterval = 4
        struct PS: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        guard let (data, _) = try? await URLSession.shared.data(for: psReq),
              let ps = try? JSONDecoder().decode(PS.self, from: data) else { return }
        for m in ps.models where m.name != keep {
            var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": m.name, "keep_alive": 0])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    private func request(model: String, messages: [Message], thinking: Thinking?, contextTokens: Int,
                         keepAlive: String, stream: Bool) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "keep_alive": keepAlive,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "options": ["temperature": 0.2, "num_ctx": contextTokens],
        ]
        if let thinking { body["think"] = thinking.json }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// One-shot completion. Falls back to no reasoning flag for models that don't support it.
    func chat(model: String, messages: [Message], thinking: Thinking? = nil, contextTokens: Int,
              keepAlive: String = "2m") async throws -> String {
        let req = try request(model: model, messages: messages, thinking: thinking, contextTokens: contextTokens,
                              keepAlive: keepAlive, stream: false)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            if thinking != nil, text.contains("thinking") {
                return try await chat(model: model, messages: messages, thinking: nil, contextTokens: contextTokens, keepAlive: keepAlive)
            }
            throw OllamaError.badResponse(text)
        }
        struct Reply: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return Self.stripThinking(reply.message.content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streams reasoning and answer as they're generated.
    func chatStream(model: String, messages: [Message], thinking: Thinking?, contextTokens: Int, keepAlive: String,
                    onThinking: @escaping @MainActor (String) -> Void,
                    onContent: @escaping @MainActor (String) -> Void) async throws -> String {
        let req = try request(model: model, messages: messages, thinking: thinking, contextTokens: contextTokens,
                              keepAlive: keepAlive, stream: true)
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            if thinking != nil, text.contains("thinking") {
                return try await chatStream(model: model, messages: messages, thinking: nil, contextTokens: contextTokens,
                                            keepAlive: keepAlive, onThinking: onThinking, onContent: onContent)
            }
            throw OllamaError.badResponse(text)
        }
        struct Chunk: Decodable {
            struct Msg: Decodable { let content: String?; let thinking: String? }
            let message: Msg?
            let error: String?
        }
        var answer = ""
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8), let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
            if let error = chunk.error { throw OllamaError.badResponse(error) }
            if let t = chunk.message?.thinking, !t.isEmpty { await onThinking(t) }
            if let c = chunk.message?.content, !c.isEmpty {
                answer += c
                await onContent(c)
            }
        }
        return Self.stripThinking(answer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reasoning models that inline their scratch work wrap it in <think> tags.
    static func stripThinking(_ text: String) -> String {
        guard let end = text.range(of: "</think>") else { return text }
        return String(text[end.upperBound...])
    }

    /// Context window big enough for the prompt (roughly 3 characters per token, plus room to answer).
    static func contextSize(forCharacters chars: Int, cap: Int = 32_768) -> Int {
        let needed = chars / 3 + 4096
        var size = 8192
        while size < needed && size < cap { size *= 2 }
        return min(size, cap)
    }
}

enum Summarizer {
    static let systemPrompt = """
    You write accurate, concise meeting notes from transcripts. Use only what the transcript says. \
    Never invent names, numbers, dates, or commitments. If something is unclear, leave it out. \
    Write plainly and directly. Transcripts come from speech recognition, so fix obvious mis-hearings \
    only when the meaning is certain.
    """

    static let format = """
    Write the notes in Markdown with these sections, in this order:

    ## Summary
    Two to four sentences: what the meeting was for and what was concluded.

    ## Key points
    - One bullet per substantive point.

    ## Decisions
    - One bullet per decision. Write "None recorded." if there were none.

    ## Action items
    - [ ] Name of the person responsible: what they will do (and the due date, if one was stated).
    For example: "- [ ] Dana: send the revised budget by Friday". Use "Unassigned" when no one was named.

    ## Open questions
    - Questions raised but not resolved. Omit this section if there were none.
    """

    /// About 25k characters per chunk keeps small models well inside their context window.
    static let chunkCharacters = 25_000

    static func summarize(meeting: Meeting, transcript: Transcript, client: OllamaClient, model: String,
                          progress: @escaping @Sendable (String) -> Void) async throws -> String {
        try await client.prepare(model)
        let header = Self.header(meeting: meeting, transcript: transcript)
        let dialogue = transcript.dialogue()
        func ask(_ prompt: String) async throws -> String {
            try await client.chat(model: model, messages: [.init(role: "system", content: systemPrompt),
                                                           .init(role: "user", content: prompt)],
                                  thinking: .on, contextTokens: OllamaClient.contextSize(forCharacters: prompt.count),
                                  keepAlive: "1m")
        }
        if dialogue.count <= chunkCharacters * 2 {
            progress("Writing summary…")
            return try await ask("\(header)\n\nTranscript:\n\(dialogue)\n\n\(format)")
        }

        // Long meeting: take notes on each part, then write the final summary from the notes.
        let chunks = split(dialogue, maxCharacters: chunkCharacters)
        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            progress("Summarizing part \(i + 1) of \(chunks.count)…")
            notes.append(try await ask("""
            \(header)

            This is part \(i + 1) of \(chunks.count) of the transcript:
            \(chunk)

            Take detailed notes on this part only, as bullets: key points, decisions, action items \
            (with owner and due date if stated), and open questions. Keep speaker names.
            """))
        }
        progress("Writing summary…")
        return try await ask("""
        \(header)

        Below are notes taken on each part of the meeting, in order:

        \(notes.enumerated().map { "### Part \($0.offset + 1)\n\($0.element)" }.joined(separator: "\n\n"))

        Combine them into one set of meeting notes, removing duplicates.

        \(format)
        """)
    }

    /// The opening context for "Ask about this meeting": the whole transcript (or as much as fits).
    static func askContext(meeting: Meeting, transcript: Transcript, summary: MeetingSummary?) -> [OllamaClient.Message] {
        var dialogue = transcript.dialogue()
        let limit = 90_000
        var note = ""
        if dialogue.count > limit {
            dialogue = String(dialogue.prefix(limit))
            note = "\n(The transcript is cut off here because it is very long.)"
        }
        var context = "\(header(meeting: meeting, transcript: transcript))\n\n"
        if let summary { context += "Meeting notes:\n\(summary.markdown)\n\n" }
        context += "Transcript:\n\(dialogue)\(note)"
        let system = systemPrompt + """
         Answer questions about this one meeting from its transcript only. Cite timestamps like [12:34] \
        where helpful. If the transcript doesn't say, answer "The transcript doesn't cover that."
        """
        return [.init(role: "system", content: system), .init(role: "user", content: context),
                .init(role: "assistant", content: "I've read the transcript. What would you like to know?")]
    }

    static func header(meeting: Meeting, transcript: Transcript) -> String {
        let date = meeting.startedAt.formatted(date: .long, time: .shortened)
        let people = transcript.speakers.map(\.name).joined(separator: ", ")
        return "Meeting: \(meeting.title)\nDate: \(date)\nLength: \(meeting.duration.durationString)\nSpeakers: \(people)"
    }

    private static func split(_ text: String, maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > maxCharacters, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// One "Ask about this meeting" conversation, streamed from the reasoning model.
@MainActor
final class AskSession: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer = ""
        var reasoning = ""
        var finished = false
        var error: String?
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var isAnswering = false
    private var history: [OllamaClient.Message] = []

    func ask(_ question: String, meeting: Meeting, transcript: Transcript, summary: MeetingSummary?,
             settings: AppSettings) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAnswering, let client = OllamaClient(urlString: settings.ollamaURL) else { return }
        if history.isEmpty { history = Summarizer.askContext(meeting: meeting, transcript: transcript, summary: summary) }
        history.append(.init(role: "user", content: q))
        turns.append(Turn(question: q))
        let index = turns.count - 1
        isAnswering = true
        defer { isAnswering = false }
        do {
            try await client.prepare(settings.askModel)
            let chars = history.reduce(0) { $0 + $1.content.count }
            let thinking: OllamaClient.Thinking = settings.askModel.hasPrefix("gpt-oss") ? .effort("medium") : .on
            let answer = try await client.chatStream(
                model: settings.askModel, messages: history, thinking: thinking,
                contextTokens: OllamaClient.contextSize(forCharacters: chars), keepAlive: "4m",
                onThinking: { [weak self] t in self?.turns[index].reasoning += t },
                onContent: { [weak self] c in self?.turns[index].answer += c })
            turns[index].answer = answer
            turns[index].finished = true
            history.append(.init(role: "assistant", content: answer))
        } catch {
            turns[index].error = error.localizedDescription
            turns[index].finished = true
            history.removeLast()
        }
    }
}
