import SwiftUI

struct SummaryView: View {
    let meeting: Meeting
    let transcript: Transcript
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var processor: ProcessingQueue
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    @ObservedObject private var claude = ClaudeAccount.shared

    @State private var summary: MeetingSummary?
    @State private var writing = false
    @State private var error: String?
    /// The model from the menu beside Write summary and Rewrite; nil means the default.
    @State private var choice: AIModelChoice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TimetableRule()
                if let summary {
                    SummarySections(markdown: summary.markdown)
                    HStack(spacing: 14) {
                        Text("\(writtenBy(summary)) · \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(Theme.caption).foregroundStyle(Theme.inkTertiary)
                        Spacer()
                        if ready {
                            Link("Check \(provider.label) usage", destination: provider.usageURL)
                                .font(Theme.caption)
                            ModelMenu(selection: $choice)
                            Button("Rewrite") { Task { await write() } }.disabled(writing)
                        }
                    }
                    .padding(.top, 10)
                } else if writing || processor.activeID == meeting.id {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(meeting.statusDetail ?? "Writing summary").font(Theme.bodyEmphasis).foregroundStyle(Theme.working)
                    }
                    .padding(.top, 16)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No summary yet").font(Theme.section).foregroundStyle(Theme.ink)
                        if ready {
                            if let detail = meeting.statusDetail {
                                Text(detail).font(Theme.body).foregroundStyle(Theme.inkSecondary)
                            }
                            HStack(spacing: 14) {
                                Button("Write summary") { Task { await write() } }
                                ModelMenu(selection: $choice)
                                Link("Check \(provider.label) usage", destination: provider.usageURL)
                                    .font(Theme.caption)
                            }
                            .padding(.top, 4)
                        } else {
                            AIConnectPrompt(message: "Connect ChatGPT or Claude to get a summary of this meeting.")
                        }
                    }
                    .padding(.top, 16)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Theme.body).foregroundStyle(Theme.caution).padding(.top, 12)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 30)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: store.contentVersion[meeting.id]) {
            summary = store.summary(for: meeting.id)
        }
    }

    private var ready: Bool { chatGPT.isSignedIn || claude.hasKey }

    /// The service the next summary goes to, for the usage link.
    private var provider: AIProvider { (choice ?? AIModels.defaultChoice)?.provider ?? settings.aiProvider }

    private func writtenBy(_ summary: MeetingSummary) -> String {
        switch summary.app {
        case nil: return "Written on this Mac by \(summary.model)"
        case "ChatGPT"?: return "Written by \(summary.model) in ChatGPT"
        case "Claude"?: return "Written by \(summary.model)"
        case let app?: return "Written by \(summary.model) in \(app)"
        }
    }

    private func write() async {
        writing = true
        error = nil
        let before = summary?.createdAt
        await processor.summarize(meeting.id, using: choice)
        summary = store.summary(for: meeting.id)
        if summary == nil || summary?.createdAt == before {
            error = store.meeting(meeting.id)?.statusDetail ?? "Couldn't reach \(provider.label). Try again."
        }
        processor.exportIfEnabled(meeting.id)
        writing = false
    }
}

/// "Ask about this meeting": a conversation with ChatGPT, streamed as it answers.
struct AskView: View {
    let meeting: Meeting
    let transcript: Transcript
    @ObservedObject var session: AskSession
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    @ObservedObject private var claude = ClaudeAccount.shared
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        TimetableRule()
                        if session.turns.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Ask anything about this meeting").font(Theme.section).foregroundStyle(Theme.ink)
                                if ready {
                                    Text("Answers come from the transcript, with timestamps. Follow-up questions keep the context.")
                                        .font(Theme.body).foregroundStyle(Theme.inkSecondary)
                                        .frame(maxWidth: 560, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(starters, id: \.self) { s in
                                            StarterButton(title: s) { send(s) }
                                        }
                                    }
                                    .padding(.top, 6)
                                } else {
                                    AIConnectPrompt(message: "Connect ChatGPT or Claude to ask questions about this meeting.")
                                }
                            }
                            .padding(.top, 16)
                        }
                        ForEach(session.turns) { turn in
                            TurnView(turn: turn).id(turn.id)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 1080, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.turns.last?.answer) { _, _ in
                    if let last = session.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HairlineRule()
            HStack(spacing: 10) {
                TextField("Ask about this meeting", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { send(question) }
                if ready {
                    ModelMenu(selection: $session.choice)
                        .padding(.horizontal, 4)
                }
                Button("Ask") { send(question) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || session.isAnswering || !ready)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 12)
            .frame(maxWidth: 1080 + Theme.gutter * 2, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { focused = true }
    }

    private var ready: Bool { chatGPT.isSignedIn || claude.hasKey }

    private var starters: [String] {
        ["What did we decide?", "What are my action items?", "Summarize what each person said."]
    }

    private func send(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !session.isAnswering else { return }
        question = ""
        Task {
            await session.ask(q, meeting: meeting, transcript: transcript, summary: store.summary(for: meeting.id), settings: settings)
        }
    }
}

private struct StarterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.turn.down.right")
                .font(Theme.bodyEmphasis)
                .foregroundStyle(Theme.ink)
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TurnView: View {
    let turn: AskSession.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question).font(Theme.bodyEmphasis).foregroundStyle(Theme.ink).textSelection(.enabled)
            if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle").font(Theme.body).foregroundStyle(Theme.caution)
            } else if turn.answer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the transcript").font(Theme.body).foregroundStyle(Theme.working)
                }
            } else {
                MarkdownView(text: turn.answer)
                    .help("Times in brackets jump to that moment")
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { HairlineRule() }
    }
}

/// Renders the small Markdown subset the models produce: headings, bullets, checkboxes.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func line(_ raw: String) -> some View {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty {
            Spacer().frame(height: 2)
        } else if s.hasPrefix("#") {
            Text(inline(s.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)))
                .font(Theme.section)
                .foregroundStyle(Theme.ink)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
        } else if s.hasPrefix("- [ ] ") || s.hasPrefix("- [x] ") || s.hasPrefix("* [ ] ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(Theme.inkTertiary).accessibilityHidden(true)
                Text(inline(String(s.dropFirst(6)))).font(Theme.body).foregroundStyle(Theme.ink)
            }
        } else if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Theme.inkTertiary)
                Text(inline(String(s.dropFirst(2)))).font(Theme.body).foregroundStyle(Theme.ink)
            }
        } else {
            Text(inline(s)).font(Theme.body).foregroundStyle(Theme.ink)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        MarkdownView.inline(s)
    }

    /// Inline Markdown, with timestamps like [12:34] turned into links that seek the recording.
    static func inline(_ s: String) -> AttributedString {
        let linked = s.replacingOccurrences(of: #"\[(\d{1,2}:\d{2}(?::\d{2})?)\]"#,
                                            with: "[$1](hootnote://seek/$1)", options: .regularExpression)
        var a = (try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        for run in a.runs where run.link != nil {
            a[run.range].foregroundColor = Theme.ink
            a[run.range].underlineStyle = .single
        }
        return a
    }
}

/// The summary set on the timetable's armature: each section's heading in the left columns,
/// its points beside it, ruled like every other table in Hootnote.
struct SummarySections: View {
    let markdown: String

    private var sections: [(title: String, lines: [String])] {
        var out: [(String, [String])] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                out.append((line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression), []))
            } else if !line.isEmpty {
                if out.isEmpty { out.append(("Notes", [])) }
                out[out.count - 1].1.append(line)
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(section.title)
                        .font(Theme.bodyEmphasis)
                        .foregroundStyle(Theme.ink)
                        .frame(width: Theme.timeColumn + TimetableColumns.line, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    MarkdownView(text: section.lines.joined(separator: "\n"))
                        .frame(maxWidth: 720, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                HairlineRule()
            }
        }
    }
}
