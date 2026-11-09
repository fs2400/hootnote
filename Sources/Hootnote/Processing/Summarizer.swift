import Foundation

/// One turn of a conversation with ChatGPT.
struct ChatMessage: Codable, Sendable {
    var role: String
    var content: String
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

    /// ChatGPT and Claude take a whole meeting at once; only very long ones are summarized in parts.
    static let chunkCharacters = 200_000

    @MainActor
    static func summarize(meeting: Meeting, transcript: Transcript, using ai: AIConnection,
                          progress: @escaping @Sendable (String) -> Void) async throws -> String {
        func ask(_ prompt: String) async throws -> String {
            try await ai.respond(systemPrompt, [.init(role: "user", content: prompt)], false, nil)
        }
        let header = Self.header(meeting: meeting, transcript: transcript)
        let dialogue = transcript.dialogue()
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
    static func askContext(meeting: Meeting, transcript: Transcript, summary: MeetingSummary?) -> [ChatMessage] {
        var dialogue = transcript.dialogue()
        let limit = 400_000
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

    static func split(_ text: String, maxCharacters: Int) -> [String] {
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

/// One "Ask about this meeting" conversation, streamed from ChatGPT or Claude.
@MainActor
final class AskSession: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer = ""
        var finished = false
        var error: String?
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var isAnswering = false
    private var history: [ChatMessage] = []

    func ask(_ question: String, meeting: Meeting, transcript: Transcript, summary: MeetingSummary?,
             settings: AppSettings) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAnswering else { return }
        if history.isEmpty { history = Summarizer.askContext(meeting: meeting, transcript: transcript, summary: summary) }
        history.append(.init(role: "user", content: q))
        turns.append(Turn(question: q))
        let index = turns.count - 1
        isAnswering = true
        defer { isAnswering = false }
        do {
            // The system message becomes the instructions; the rest is the conversation so far. The
            // transcript stays at the front, so follow-up questions reuse Claude's cached copy of it.
            let ai = try await AIConnection.current()
            let answer = try await ai.respond(history[0].content, Array(history.dropFirst()), true) { [weak self] c in
                self?.turns[index].answer += c
            }
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
