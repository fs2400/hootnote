import AppKit
import SwiftUI

enum SpeakerColors {
    /// You ride the ink line; everyone else gets a route colour in order of first appearance.
    static func color(for speaker: Speaker, in transcript: Transcript) -> Color {
        if speaker.isMe { return Theme.ink }
        let others = transcript.speakers.filter { !$0.isMe }
        let i = others.firstIndex(of: speaker) ?? 0
        return Theme.lines[i % Theme.lines.count]
    }
}

struct TranscriptView: View {
    let meeting: Meeting
    let transcript: Transcript
    @ObservedObject var player: PlayerModel
    @EnvironmentObject var state: AppState
    @EnvironmentObject var voiceprints: VoiceprintStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var follow = true
    @State private var editing: Utterance?
    @State private var pendingMerge: (speaker: Speaker, into: String)?
    @State private var pendingDelete: Utterance?
    @State private var matchCursor = 0
    /// When a word was last clicked: the follow scroll leaves that paragraph where you clicked it.
    @State private var lastWordClick = Date.distantPast
    /// When ↑ or ↓ last moved playback: the transcript follows that even while paused.
    @State private var lastKeyJump = Date.distantPast
    @FocusState private var transcriptFocused: Bool
    /// A paragraph has keyboard focus (after a click in it); its keys still drive playback.
    @State private var paragraphFocused = false

    @Environment(\.undoManager) private var undoManager
    private var editor: TranscriptEditor { TranscriptEditor(meetingID: meeting.id, state: state, undoManager: undoManager) }

    /// Share of talk time per speaker, computed once per transcript rather than on every playback tick.
    private var shares: [String: String] {
        let total = transcript.utterances.reduce(0) { $0 + ($1.end - $1.start) }
        guard total > 0 else { return [:] }
        var bySpeaker: [String: Double] = [:]
        for u in transcript.utterances { bySpeaker[u.speakerID, default: 0] += u.end - u.start }
        return bySpeaker.mapValues { "\(Int(($0 / total * 100).rounded()))%" }
    }
    private var query: String { state.searchQuery.trimmingCharacters(in: .whitespaces) }
    private var matches: [Utterance] {
        query.isEmpty ? [] : transcript.utterances.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// Renames, but asks first when the new name belongs to someone else here (that merges two speakers).
    private func rename(_ speaker: Speaker, to name: String) {
        if transcript.speakers.contains(where: { $0.id != speaker.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            pendingMerge = (speaker, name)
        } else {
            editor.rename(speaker: speaker.id, to: name)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            speakerStrip
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        TimetableRule()
                        ForEach(transcript.utterances) { u in
                            row(u).id(u.id)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 30)
                    .frame(maxWidth: 1080, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: currentIndex) { _, index in
                    let jumped = Date().timeIntervalSince(lastKeyJump) < 1
                    guard follow, player.isPlaying || jumped, let index, Date().timeIntervalSince(lastWordClick) > 1 else { return }
                    withAnimation(Theme.travel(reduceMotion)) {
                        proxy.scrollTo(transcript.utterances[index].id, anchor: .center)
                    }
                }
                .onChange(of: query) { _, _ in
                    matchCursor = 0
                    if let first = matches.first { proxy.scrollTo(first.id, anchor: .center) }
                }
                .onChange(of: matchCursor) { _, i in
                    guard !matches.isEmpty else { return }
                    withAnimation(Theme.travel(reduceMotion)) { proxy.scrollTo(matches[i].id, anchor: .center) }
                }
                .focusable()
                .focused($transcriptFocused)
                .focusEffectDisabled() // the speaker strip shows the keys instead of a ring round the whole page
                .onKeyPress(.space) { press(.playPause); return .handled }
                // ↑ and ↓ move playback to the previous or next paragraph.
                .onKeyPress(.upArrow) { press(.previous); return .handled }
                .onKeyPress(.downArrow) { press(.next); return .handled }
                .onAppear {
                    // Opened from a search result: land on that moment.
                    if let pending = state.pendingSeek, pending.meeting == meeting.id,
                       let target = transcript.utterances.last(where: { $0.start <= pending.time + 0.01 }) {
                        DispatchQueue.main.async { proxy.scrollTo(target.id, anchor: .center) }
                    } else if let first = matches.first {
                        DispatchQueue.main.async { proxy.scrollTo(first.id, anchor: .center) }
                    }
                }
            }
        }
        .sheet(item: $editing) { u in
            EditTextSheet(original: u.text) { text in editor.editText(utterance: u.id, to: text) }
        }
        .confirmationDialog(
            "Merge “\(pendingMerge?.speaker.name ?? "")” into “\(pendingMerge?.into ?? "")”?",
            isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
            titleVisibility: .visible
        ) {
            Button("Merge Speakers") {
                if let m = pendingMerge { editor.rename(speaker: m.speaker.id, to: m.into) }
                pendingMerge = nil
            }
            Button("Cancel", role: .cancel) { pendingMerge = nil }
        } message: {
            Text("Everything \(pendingMerge?.speaker.name ?? "") said will be attributed to \(pendingMerge?.into ?? ""). To fix a single paragraph instead, right-click it and choose Change Speaker for This Paragraph.")
        }
        .confirmationDialog(
            "Delete this paragraph?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Paragraph", role: .destructive) {
                if let u = pendingDelete { editor.deleteUtterance(u.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The text is removed from the transcript and exports. The recording keeps the audio. You can undo this with ⌘Z.")
        }
    }

    // MARK: Speakers

    private var speakerStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                let talk = shares
                ForEach(transcript.speakers) { s in
                    HStack(spacing: 6) {
                        LineDot(color: SpeakerColors.color(for: s, in: transcript))
                        InlineNameField(name: s.name, placeholder: TranscriptEditor.isPlaceholder(s.name),
                                        font: Theme.bodyEmphasis, color: Theme.ink) { rename(s, to: $0) }
                        if s.autoIdentified {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .font(Theme.caption).foregroundStyle(Theme.inkTertiary)
                                .help("Recognized by voice. Click the name to correct it.")
                                .accessibilityLabel("Recognized by voice")
                        }
                        Text(talk[s.id] ?? "").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.inkTertiary)
                        speakerMenu(s)
                    }
                }
                }
                }
                // More speakers than fit: the strip scrolls, and its edge fades instead of cutting a name.
                // The margin lets the last speaker scroll clear of the fade.
                .contentMargins(.trailing, 28, for: .scrollContent)
                .mask(HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                })
                Spacer(minLength: 12)
                if !query.isEmpty {
                    HStack(spacing: 6) {
                        Text(matches.isEmpty ? "No matches" : "\(matchCursor + 1) of \(matches.count)")
                            .font(Theme.caption.monospacedDigit())
                            .foregroundStyle(Theme.inkSecondary)
                        Button { matchCursor = (matchCursor - 1 + matches.count) % max(matches.count, 1) } label: { Image(systemName: "chevron.up") }
                            .keyboardShortcut("g", modifiers: [.command, .shift])
                            .help("Previous match (⇧⌘G)")
                            .accessibilityLabel("Previous match")
                        Button { matchCursor = (matchCursor + 1) % max(matches.count, 1) } label: { Image(systemName: "chevron.down") }
                            .keyboardShortcut("g", modifiers: .command)
                            .help("Next match (⌘G)")
                            .accessibilityLabel("Next match")
                    }
                    .buttonStyle(.borderless)
                    .disabled(matches.isEmpty)
                }
                if transcriptFocused || paragraphFocused {
                    // Shows the transcript has the keyboard, and what the keys do there.
                    Text("Space plays or pauses · ↑ ↓ paragraphs")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .transition(.opacity)
                }
                Toggle("Follow playback", isOn: $follow)
                    .toggleStyle(.checkbox)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 10)
            .frame(maxWidth: 1080 + Theme.gutter * 2, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func suggestions(excluding speaker: Speaker) -> [String] {
        let taken = Set(transcript.speakers.filter { $0.id != speaker.id }.map(\.name))
        var seen = Set<String>()
        return (meeting.attendees + voiceprints.names)
            .filter { !taken.contains($0) && $0 != speaker.name && seen.insert($0).inserted }
    }

    private func speakerMenu(_ s: Speaker) -> some View {
        Menu {
            let names = suggestions(excluding: s)
            if !names.isEmpty {
                Section("This is…") {
                    ForEach(names.prefix(12), id: \.self) { name in
                        Button(name) { editor.rename(speaker: s.id, to: name) }
                    }
                }
            }
            if !s.isMe {
                Button("Mark as Me") { editor.markAsMe(speaker: s.id) }
            }
            let others = transcript.speakers.filter { $0.id != s.id }
            if !others.isEmpty {
                Menu("Same Person As…") {
                    ForEach(others) { o in Button(o.name) { editor.rename(speaker: s.id, to: o.name) } }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(minWidth: 20, minHeight: 20)
        .contentShape(Rectangle())
        .fixedSize()
        .foregroundStyle(Theme.inkTertiary)
        .help("Suggestions and merging for \(s.name)")
        .accessibilityLabel("More options for \(s.name)")
    }

    // MARK: Rows

    /// The paragraph being played: the latest to have started, unless it has already finished while an
    /// earlier, longer turn is still going (someone's "yeah" in the middle of another person's point).
    private var currentIndex: Int? {
        guard player.isLoaded, player.currentTime > 0 || player.isPlaying else { return nil }
        let t = player.currentTime
        let us = transcript.utterances
        var lo = 0, hi = us.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if us[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let found else { return nil }
        if t > us[found].end + 0.3 {
            for i in stride(from: found - 1, through: max(0, found - 12), by: -1) where us[i].end + 0.3 >= t {
                return i
            }
        }
        return found
    }

    private func row(_ u: Utterance) -> some View {
        let speaker = transcript.speaker(u.speakerID)
        let color = speaker.map { SpeakerColors.color(for: $0, in: transcript) } ?? Theme.inkTertiary
        let isCurrent = currentIndex.map { transcript.utterances[$0].id == u.id } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Button {
                    player.seek(to: u.start)
                    player.play()
                } label: {
                    Text(u.start.clockString)
                        .font(Theme.timeRow)
                        .foregroundStyle(isCurrent ? Theme.signal : Theme.inkSecondary)
                        .opacity(isCurrent ? 0 : 1) // the travelling now-line carries the time on this row
                        .frame(width: Theme.timeColumn, alignment: .leading)
                        .frame(minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Play from \(u.start.clockString)")
                .accessibilityLabel("Play from \(u.start.clockString)")

                HStack(spacing: 6) {
                    LineDot(color: color)
                    if let speaker {
                        InlineNameField(name: speaker.name, placeholder: TranscriptEditor.isPlaceholder(speaker.name),
                                        font: .system(size: 13, weight: .semibold), color: Theme.ink) {
                            rename(speaker, to: $0)
                        }
                    }
                }
                .frame(width: TimetableColumns.line, alignment: .leading)

                TranscriptParagraph(utterance: u, lit: isCurrent ? litWord(in: u) : nil, query: query,
                                    onKey: press, onFocus: { paragraphFocused = $0 }) { start in
                    lastWordClick = Date()
                    player.seek(to: start)
                    player.play()
                }
                .frame(maxWidth: TranscriptParagraph.maxWidth, alignment: .leading)
                // AppKit text has no SwiftUI baseline: give the first line's, so it sits level with the time and name.
                .alignmentGuide(.firstTextBaseline) { _ in ceil(Theme.NS.body.ascender) }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            HairlineRule()
        }
        .overlay(alignment: .topLeading) {
            // The signature now-line rides down the time column through the paragraph being played,
            // proportional to playback. It stays in that column, so it never strikes a name or a word.
            if isCurrent {
                GeometryReader { geo in
                    let span = max(u.end - u.start, 0.1)
                    let fraction = min(1, max(0, (player.currentTime - u.start) / span))
                    NowLine(label: player.currentTime.clockString)
                        .frame(width: Theme.timeColumn - 14)
                        .offset(y: 4 + (geo.size.height - 22) * fraction)
                        .animation(Theme.travel(reduceMotion), value: fraction)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .contextMenu {
            Button("Play from Here") { player.seek(to: u.start); player.play() }
            Button("Copy Paragraph") { copy("\(speaker?.name ?? ""): \(u.text)") }
            Button("Edit Text…") { editing = u }
            Menu("Change Speaker for This Paragraph") {
                ForEach(transcript.speakers) { s in
                    Button(s.name) { editor.move(utterance: u.id, to: s.id) }
                }
            }
            Divider()
            Button("Delete Paragraph…", role: .destructive) { pendingDelete = u }
        }
    }

    private func press(_ key: TranscriptKey) {
        switch key {
        case .playPause: player.toggle()
        case .previous:
            lastKeyJump = Date()
            player.seek(to: TranscriptNavigation.previous(in: transcript, from: player.currentTime))
        case .next:
            lastKeyJump = Date()
            if let t = TranscriptNavigation.next(in: transcript, from: player.currentTime) { player.seek(to: t) }
        }
    }

    /// The word being spoken in a playing paragraph; none during a pause of more than 0.4 s.
    private func litWord(in u: Utterance) -> Int? {
        let t = player.currentTime
        var lit: Int?
        for (i, w) in u.words.enumerated() where w.start <= t + 0.03 { lit = i }
        if let i = lit, t > u.words[i].end + 0.4 { return nil }
        return lit
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Paragraph-to-paragraph moves for the keyboard and the Playback menu.
enum TranscriptNavigation {
    /// The start of the paragraph before the one playing (or of this one, more than a second in).
    static func previous(in t: Transcript, from time: Double) -> Double {
        let starts = t.utterances.map(\.start)
        guard let i = starts.lastIndex(where: { $0 <= time + 0.05 }) else { return 0 }
        if time - starts[i] > 1 { return starts[i] }
        return i > 0 ? starts[i - 1] : 0
    }

    static func next(in t: Transcript, from time: Double) -> Double? {
        t.utterances.first { $0.start > time + 0.05 }?.start
    }
}

/// A name you edit where it stands: click it, type, press Return. Escape cancels.
struct InlineNameField: View {
    let name: String
    var placeholder = false
    var font: Font
    var color: Color
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var cursorPushed = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(font)
                    .frame(width: 150)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                    .onAppear {
                        draft = placeholder ? "" : name
                        focused = true
                    }
            } else {
                // A real button, so Tab / Full Keyboard Access and VoiceOver reach it too.
                Button {
                    releaseCursor()
                    editing = true
                } label: {
                    Text(name)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside, !cursorPushed { NSCursor.iBeam.push(); cursorPushed = true }
                    if !inside { releaseCursor() }
                }
                .onDisappear(perform: releaseCursor)
                .help("Click to rename \(name) everywhere in this meeting")
                .accessibilityLabel(placeholder ? name : "Speaker \(name)") // not "Speaker Speaker 2"
                .accessibilityHint("Rename this speaker")
            }
        }
    }

    private func releaseCursor() {
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let new = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !new.isEmpty, new != name { onCommit(new) }
    }
}

struct EditTextSheet: View {
    let original: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit paragraph").font(Theme.section)
            TextEditor(text: $text)
                .font(Theme.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.rule))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { text = original }
    }
}
