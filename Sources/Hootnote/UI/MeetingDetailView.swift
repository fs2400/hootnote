import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    let meetingID: UUID
    /// Used by the snapshot tool to show a tab or a moment of playback.
    var initialTab: Tab = .transcript
    var previewTime: Double?
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var processor: ProcessingQueue

    // Held in @State (not observed here) so 20 playback ticks a second only redraw the views that show time.
    @State private var player = PlayerModel()
    @State private var ask = AskSession()
    @State private var tab: Tab = .transcript
    @State private var title = ""
    @State private var pendingDelete: Meeting?
    @State private var pendingRetranscribe: Meeting?
    @State private var pendingRestore: Meeting?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingJoin: JoinRequest?
    /// Shown for a few seconds when a join into this meeting finishes.
    @State private var joinedNotice = false
    @State private var savedExport: URL?
    @State private var hasStereoRecording = false
    @FocusState private var titleFocused: Bool

    enum Tab: String, CaseIterable { case transcript = "Transcript", summary = "Summary", ask = "Ask" }

    var body: some View {
        if let meeting = store.meeting(meetingID) {
            VStack(spacing: 0) {
                header(meeting)
                content(meeting)
            }
            .toolbar { toolbar(meeting) }
            .deleteConfirmation($pendingDelete)
            .navigationTitle(meeting.title)
            .overlay(alignment: .bottom) { exportNotice }
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "hootnote", url.host == "seek" else { return .systemAction }
                let parts = url.lastPathComponent.split(separator: ":").compactMap { Double($0) }
                let seconds = parts.reduce(0) { $0 * 60 + $1 }
                tab = .transcript
                state.pendingSeek = (meeting.id, seconds)
                player.seek(to: seconds)
                return .handled
            })
            .focusedSceneValue(\.meetingActions, actions(meeting))
            // Undo (or a rename elsewhere) changed the title: show it, unless you're typing one.
            .onChange(of: meeting.title) { _, new in if !titleFocused { title = new } }
            .confirmationDialog("Re-transcribe this meeting?", isPresented: Binding(
                get: { pendingRetranscribe != nil }, set: { if !$0 { pendingRetranscribe = nil } }), titleVisibility: .visible) {
                Button("Re-transcribe") {
                    if let m = pendingRetranscribe { processor.enqueue(m.id) }
                    pendingRetranscribe = nil
                }
                Button("Cancel", role: .cancel) { pendingRetranscribe = nil }
            } message: {
                Text("The transcript is made again from the recording. Text you edited, paragraphs you moved or deleted, and speaker names are replaced; voices you've named before are recognized again. Edits made before this can't be undone.")
            }
            .confirmationDialog("Join with the previous meeting?", isPresented: Binding(
                get: { pendingJoin?.problem == nil && pendingJoin != nil }, set: { if !$0 { pendingJoin = nil } }),
                titleVisibility: .visible, presenting: pendingJoin) { request in
                Button("Join Meetings") {
                    state.joinWithPrevious(request.meeting.id)
                    pendingJoin = nil
                }
                Button("Cancel", role: .cancel) { pendingJoin = nil }
            } message: { request in
                Text(request.explanation(summaryEnabled: state.settings.summaryEnabled))
            }
            .alert("These meetings can't be joined", isPresented: Binding(
                get: { pendingJoin?.problem != nil }, set: { if !$0 { pendingJoin = nil } }), presenting: pendingJoin) { _ in
                Button("OK") { pendingJoin = nil }
            } message: { request in
                Text(request.problem ?? "")
            }
            .confirmationDialog("Restore the original transcript?", isPresented: Binding(
                get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }), titleVisibility: .visible) {
                Button("Restore Original") {
                    if let m = pendingRestore { processor.restoreUncleaned(m.id) }
                    pendingRestore = nil
                }
                Button("Cancel", role: .cancel) { pendingRestore = nil }
            } message: {
                Text("This puts back the echo fragments Clean Up removed. Speaker names stay; text edits made since Clean Up are replaced. Edits made before this can't be undone.")
            }
            .task(id: meeting.status) {
                title = meeting.title
                tab = initialTab
                hasStereoRecording = FileManager.default.fileExists(atPath: meeting.stereoRecordingURL.path)
            }
            // One place loads the player: when the meeting becomes ready, and again when its audio is
            // rebuilt (Clean Up, or levelled playback made for an older meeting).
            .task(id: "\(meeting.status.rawValue)·\(processor.playbackVersion[meeting.id] ?? 0)") {
                guard meeting.status == .ready else { return }
                await player.load(meeting, version: processor.playbackVersion[meeting.id] ?? 0)
                if let previewTime { player.seek(to: previewTime) }
                if let pending = state.pendingSeek, pending.meeting == meeting.id {
                    tab = .transcript
                    player.seek(to: pending.time)
                    state.pendingSeek = nil
                }
            }
            .onChange(of: processor.lastJoined?.at) { _, at in
                guard at != nil, processor.lastJoined?.id == meeting.id else { return }
                joinedNotice = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { joinedNotice = false }
            }
            .onDisappear {
                player.pause()
                commitTitle(meeting)
            }
        }
    }

    // MARK: Header

    private func header(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.title)
                .foregroundStyle(Theme.ink)
                .focused($titleFocused)
                .onSubmit { commitTitle(m) }
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle(m) } }
                .onExitCommand { title = m.title; titleFocused = false }
                .accessibilityLabel("Meeting title")
            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    LineDot(color: Theme.line(forApp: m.appID))
                    Text(MeetingApps.name(for: m.appID))
                }
                Text(m.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                Text(m.duration.durationString).monospacedDigit()
                Spacer()
                if m.status == .ready {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .font(Theme.body)
            .foregroundStyle(Theme.inkSecondary)
            if m.status == .ready, processor.activeID == m.id || processor.joiningIDs.contains(m.id)
                || m.statusDetail?.hasPrefix("Waiting to clean up") == true {
                // Clean Up or a join is running on this meeting.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(m.statusDetail ?? "Working…").font(Theme.caption).foregroundStyle(Theme.working)
                }
            } else if m.status == .ready, let detail = m.statusDetail, detail.hasPrefix("Clean up didn't finish") {
                HStack(spacing: 10) {
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.caution)
                    Button("Try again") { processor.enqueueCleanUp(m.id) }.controlSize(.small)
                }
            } else if m.status == .ready, let detail = m.statusDetail, detail.hasPrefix("Join didn't finish") {
                HStack(spacing: 10) {
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.caution)
                    if processor.failedJoins[m.id] != nil {
                        Button("Try Again") { processor.retryJoin(m.id) }.controlSize(.small)
                    }
                    Button("Dismiss") { store.update(m.id) { $0.statusDetail = nil } }.controlSize(.small)
                }
            } else if m.status == .ready, !processor.isBusy(m.id), let previous = MeetingJoiner.continuation(of: m, store: store),
                      !processor.isBusy(previous.id) {
                joinOffer(m, previous)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// The call dropped and came back as a second meeting: offer the join here rather than in a menu.
    /// Join only opens the confirmation; nothing is joined until you confirm there.
    private func joinOffer(_ m: Meeting, _ previous: Meeting) -> some View {
        let time = JoinRequest.time(previous)
        let pickedUp = JoinRequest.gap(from: previous, to: m).map { "picked up \($0) after it stopped" } ?? "picked up as it stopped"
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The time is what finds the other meeting in the sidebar, so it carries the weight.
            (Text("Looks like the rest of the ") + Text(time).fontWeight(.semibold).foregroundStyle(Theme.ink)
                + Text(" meeting, \(pickedUp)."))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Join…") { requestJoin(m) }
                .controlSize(.small)
                .fixedSize()
                .help("Joins this meeting onto the end of the \(time) one, once you confirm.")
                .accessibilityLabel("Join with the \(time) meeting…")
            Button("Not now") {
                withAnimation(Theme.travel(reduceMotion)) {
                    Self.setJoinOfferDeclined(m.id, previous.id, store: store, undoManager: undoManager)
                }
                state.announce("Hootnote won't suggest this again. Join with Previous Meeting, in the Meeting menu, still joins them.")
            }
            .controlSize(.small)
            .fixedSize()
            .help("Stops suggesting this. Meeting › Join with Previous Meeting… still joins them.")
            .accessibilityLabel("Not now: keep separate from the \(time) meeting")
        }
        .font(Theme.caption.monospacedDigit())
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Join suggestion")
    }

    /// "Not now" on the join offer, with undo.
    private static func setJoinOfferDeclined(_ id: UUID, _ value: UUID?, store: MeetingStore, undoManager: UndoManager?) {
        let old = store.meeting(id)?.joinOfferDeclined
        store.update(id) { $0.joinOfferDeclined = value }
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: UndoTarget.title(id, in: undoManager)) { _ in
            MainActor.assumeIsolated { setJoinOfferDeclined(id, old, store: store, undoManager: undoManager) }
        }
        undoManager.setActionName("Hide Join Suggestion")
    }

    private func commitTitle(_ m: Meeting) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != m.title else { return }
        MeetingTitle.set(m.id, to: t, from: m.title, store: store, processor: processor, undoManager: undoManager)
    }

    // MARK: Content by status

    @ViewBuilder private func content(_ m: Meeting) -> some View {
        switch m.status {
        case .recording:
            if let rec = state.recording, rec.id == m.id {
                LiveRecordingView(session: rec)
            } else {
                StatusPanel(title: "Recording interrupted", detail: "What was captured will be transcribed shortly.")
            }
        case .queued, .processing:
            VStack(alignment: .leading, spacing: 10) {
                TimetableRule()
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(m.status == .queued ? (m.statusDetail ?? "Waiting to transcribe") : (m.statusDetail ?? "Transcribing"))
                        .font(Theme.bodyEmphasis).foregroundStyle(Theme.working)
                }
                .padding(.top, 8)
                Text("Everything runs on this Mac. You can keep working, or record another call meanwhile.")
                    .font(Theme.body).foregroundStyle(Theme.inkSecondary)
                Spacer()
            }
            .padding(.horizontal, Theme.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                TimetableRule()
                Text("Transcription failed").font(Theme.section).foregroundStyle(Theme.caution).padding(.top, 8)
                Text(m.statusDetail ?? "Unknown error").font(Theme.body).foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
                Button("Try again") { processor.enqueue(m.id) }
                Spacer()
            }
            .padding(.horizontal, Theme.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .ready:
            if let transcript = store.transcript(for: m.id) {
                VStack(spacing: 0) {
                    if transcript.utterances.isEmpty {
                        StatusPanel(title: "No speech found",
                                    detail: "Nothing was said loud enough to transcribe. If others were talking, check that Hootnote has System Audio Recording permission.")
                    } else {
                        switch tab {
                        case .transcript:
                            TranscriptView(meeting: m, transcript: transcript, player: player)
                        case .summary:
                            SummaryView(meeting: m, transcript: transcript)
                        case .ask:
                            AskView(meeting: m, transcript: transcript, session: ask)
                        }
                    }
                    PlayerBar(player: player)
                }
            } else {
                StatusPanel(title: "Transcript missing", detail: "Re-transcribe to rebuild it from the recording.")
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private func toolbar(_ m: Meeting) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if m.status == .ready, let transcript = store.transcript(for: m.id) {
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button("\(format.label)…") { save(m, transcript, format) }
                    }
                    Divider()
                    Button("Copy transcript") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Exporter.text(meeting: m, transcript: transcript), forType: .string)
                    }
                    if let summary = store.summary(for: m.id) {
                        Button("Copy summary") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary.markdown, forType: .string)
                        }
                    }
                    if hasStereoRecording {
                        Divider()
                        Button("Show recording in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.stereoRecordingURL]) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export as Word, PDF, Markdown, text or subtitles")
            }
            let joining = processor.joiningIDs.contains(m.id)
            Menu {
                Button("Clean Up Transcript") { processor.enqueueCleanUp(m.id) }
                    .disabled(m.status != .ready || processor.isBusy(m.id))
                    .help("Removes speaker echo under your name and Whisper's repeated phrases")
                if FileManager.default.fileExists(atPath: m.uncleanedTranscriptURL.path) {
                    Button("Restore Original Transcript…") { pendingRestore = m }
                        .disabled(joining)
                }
                Button("Re-transcribe…") { pendingRetranscribe = m }
                    .disabled(m.status == .recording || m.status == .processing || joining)
                Button("Join with Previous Meeting…") { requestJoin(m) }
                    .disabled(!canJoin(m))
                    .help("For one call saved as two meetings: joins this one onto the end of the meeting before it")
                Button("Show files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.folder]) }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = m }
                    .disabled(joining)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Join

    /// Cheap enough for every redraw; the full check runs when the item is chosen.
    private func canJoin(_ m: Meeting) -> Bool {
        guard m.status == .ready, !processor.isBusy(m.id), let previous = store.meeting(before: m) else { return false }
        return !processor.isBusy(previous.id)
    }

    private func requestJoin(_ m: Meeting) {
        guard let candidate = state.joinCandidate(for: m.id) else { return }
        pendingJoin = JoinRequest(previous: candidate.previous, meeting: m, problem: candidate.problem)
    }

    private func save(_ m: Meeting, _ t: Transcript, _ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Exporter.fileName(for: m, format: format)
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.write(format, meeting: m, transcript: t, summary: store.summary(for: m.id), to: url)
            savedExport = url
            state.announce("Saved \(url.lastPathComponent)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if savedExport == url { savedExport = nil } }
        } catch {
            state.lastError = "Couldn't save the \(format.label): \(error.localizedDescription). Try another folder."
        }
    }

    /// Confirms an export, with a way to find the file; or that two meetings were joined.
    @ViewBuilder private var exportNotice: some View {
        if joinedNotice, let m = store.meeting(meetingID) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ready).accessibilityHidden(true)
                Text("Joined into one \(m.duration.durationString) meeting. The later part is in the Trash.")
                    .font(Theme.bodyEmphasis).foregroundStyle(Theme.ink).lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.rule))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.bottom, 70)
            .transition(.opacity)
        } else if let url = savedExport {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ready).accessibilityHidden(true)
                Text("Saved \(url.lastPathComponent)").font(Theme.bodyEmphasis).foregroundStyle(Theme.ink).lineLimit(1)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button { savedExport = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.rule))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.bottom, 70)
            .transition(.opacity)
        }
    }

    /// What the Playback, Meeting and View menus act on.
    private func actions(_ m: Meeting) -> MeetingActions {
        let transcript = store.transcript(for: m.id)
        return MeetingActions(
            id: m.id,
            canPlay: m.status == .ready,
            playPause: { player.toggle() },
            back: { player.skip(-15) },
            forward: { player.skip(15) },
            export: { format in if let transcript { save(m, transcript, format) } },
            delete: { pendingDelete = m },
            previousParagraph: { if let transcript { player.seek(to: TranscriptNavigation.previous(in: transcript, from: player.currentTime)) } },
            nextParagraph: { if let transcript, let t = TranscriptNavigation.next(in: transcript, from: player.currentTime) { player.seek(to: t) } },
            retranscribe: { pendingRetranscribe = m },
            cleanUp: { processor.enqueueCleanUp(m.id) },
            restoreOriginal: FileManager.default.fileExists(atPath: m.uncleanedTranscriptURL.path) && !processor.joiningIDs.contains(m.id)
                ? { pendingRestore = m } : nil,
            joinWithPrevious: canJoin(m) ? { requestJoin(m) } : nil,
            isJoining: processor.joiningIDs.contains(m.id),
            showTab: { name in tab = Tab(rawValue: name) ?? .transcript }
        )
    }
}

/// "Join with Previous Meeting…": the two meetings, and why they can't be joined if they can't.
struct JoinRequest {
    let previous: Meeting
    let meeting: Meeting
    let problem: String?

    /// When a meeting started, as the sidebar shows it.
    static func time(_ m: Meeting) -> String { m.startedAt.formatted(date: .omitted, time: .shortened) }

    /// Lengths never break across lines ("1 hr / 53 min").
    static func unbroken(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{00A0}") }

    /// The time between one meeting's end and the next one's start ("48 s", "1 min 14 s"); nil under a second.
    static func gap(from previous: Meeting, to meeting: Meeting) -> String? {
        let gap = Int(meeting.startedAt.timeIntervalSince(previous.endedAt ?? previous.startedAt).rounded())
        guard gap >= 1 else { return nil }
        let length = gap < 60 ? "\(gap) s" : gap < 600 ? (gap % 60 == 0 ? "\(gap / 60) min" : "\(gap / 60) min \(gap % 60) s")
            : TimeInterval(gap).durationString
        return unbroken(length)
    }

    func explanation(summaryEnabled: Bool) -> String {
        let unbroken = Self.unbroken, time = Self.time
        var paragraphs: [String] = []

        // The pair is simply the meeting before this one, so say when they don't look like one call.
        var differences: [String] = []
        if previous.title != meeting.title { differences.append("have different titles") }
        if previous.appID != meeting.appID { differences.append("were recorded from different apps") }
        if !differences.isEmpty {
            paragraphs.append("These may be separate calls: they \(differences.joined(separator: " and ")). "
                              + "The joined meeting keeps the earlier title.")
        }

        let total = (meeting.endedAt ?? Date()).timeIntervalSince(previous.startedAt)
        var what = "“\(previous.title)” at \(time(previous)) and this meeting at \(time(meeting)) become one "
            + "\(unbroken(total.durationString)) meeting"
        if let gap = Self.gap(from: previous, to: meeting) {
            what += ", with the \(gap) between them kept as silence"
        }
        let summary = summaryEnabled ? ", and a new summary is written."
            : previous.hasSummary || meeting.hasSummary ? ". Their summaries are removed, since each covers only one part." : "."
        paragraphs.append(what + ". Speakers heard in both are matched by voice" + summary)

        paragraphs.append("Hootnote can't split them again, but nothing is lost: this meeting and the earlier "
                          + "one as it was go to the Trash.")
        return paragraphs.joined(separator: "\n\n")
    }
}

private struct StatusPanel: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimetableRule()
            Text(title).font(Theme.section).foregroundStyle(Theme.ink).padding(.top, 8)
            Text(detail).font(Theme.body).foregroundStyle(Theme.inkSecondary).frame(maxWidth: 560, alignment: .leading)
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct LiveRecordingView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var session: RecordingSession
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TimetableRule()
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                // Red means live; while paused for a dropped call nothing is captured.
                Circle().fill(session.isPaused ? Theme.caution : Theme.signal).frame(width: 12, height: 12)
                Text(session.elapsed.clockString)
                    .font(.system(size: 48, weight: .semibold).monospacedDigit())
                    .foregroundStyle(session.isPaused ? Theme.ink : Theme.signal)
                // Waiting for a dropped call: the clock runs on, but nothing is being captured.
                Text(session.isPaused ? "Paused" : "Recording").font(Theme.section)
                    .foregroundStyle(session.isPaused ? Theme.caution : Theme.signal)
            }
            .padding(.top, 8)
            Text(session.app.id == MeetingApps.manual.id
                 ? "Recording everyone in the room on your microphone."
                 : session.isPaused ? "Nothing is recorded until the call comes back."
                 : "Your microphone and the call are captured on separate tracks.")
                .font(Theme.body).foregroundStyle(Theme.inkSecondary)
            HStack(spacing: 28) {
                meter("You", session.isPaused ? 0 : session.micLevel)
                if session.app.id != MeetingApps.manual.id { meter("Call", session.isPaused ? 0 : session.systemLevel) }
            }
            if let ending = session.endingAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = ending.timeIntervalSinceNow.countdownString
                    Text(session.isPaused
                         ? "The call app let go of the microphone. If the call comes back in the next \(left), this recording carries on."
                         : "The call seems to have ended. Stopping in \(left).")
                        .font(Theme.bodyEmphasis).foregroundStyle(Theme.caution)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                Button("Keep recording") { session.keepRecording = true }
            }
            ForEach(session.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(Theme.body).foregroundStyle(Theme.caution)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button {
                    state.stopRecording(.manual(from: "the meeting window's Stop and transcribe button"))
                } label: {
                    Label("Stop and transcribe", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.signal)
                .controlSize(.large)
                Button("Discard…", role: .destructive) { confirmDiscard = true }
                    .controlSize(.large)
            }
            .discardConfirmation($confirmDiscard)
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func meter(_ label: String, _ level: Float) -> some View {
        let db = 20 * log10(max(Double(level), 1e-5))
        let fraction = min(1, max(0, (db + 50) / 40))
        return HStack(spacing: 10) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.inkSecondary).frame(width: 32, alignment: .leading)
            ProgressView(value: fraction).frame(width: 180).tint(Theme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue(fraction < 0.05 ? "silent" : "\(Int(fraction * 100)) percent")
    }
}

/// Renaming a meeting, with undo.
@MainActor
enum MeetingTitle {
    static func set(_ id: UUID, to new: String, from old: String, store: MeetingStore, processor: ProcessingQueue,
                    undoManager: UndoManager?) {
        store.update(id) { $0.title = new }
        processor.exportIfEnabled(id)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: UndoTarget.title(id, in: undoManager)) { _ in
            MainActor.assumeIsolated {
                guard store.meeting(id) != nil else { return }
                let state = AppState.shared
                if state.selectedMeetingID != id { state.route = .meeting(id) }
                state.announce("\(undoManager.isRedoing ? "Renamed" : "Changed back to") “\(old)”")
                set(id, to: old, from: new, store: store, processor: processor, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Rename Meeting")
    }
}

/// What the menu bar's Playback, Meeting and View menus act on (the meeting on screen).
struct MeetingActions {
    let id: UUID
    let canPlay: Bool
    let playPause: () -> Void
    let back: () -> Void
    let forward: () -> Void
    let export: (ExportFormat) -> Void
    let delete: () -> Void
    let previousParagraph: () -> Void
    let nextParagraph: () -> Void
    let retranscribe: () -> Void
    let cleanUp: () -> Void
    /// Set when Clean Up changed this transcript and the original can be put back.
    let restoreOriginal: (() -> Void)?
    /// Set when there's a meeting before this one to join it to.
    let joinWithPrevious: (() -> Void)?
    /// Being joined with another meeting: nothing else may change it meanwhile.
    let isJoining: Bool
    let showTab: (String) -> Void
}

struct MeetingActionsKey: FocusedValueKey {
    typealias Value = MeetingActions
}

extension FocusedValues {
    var meetingActions: MeetingActions? {
        get { self[MeetingActionsKey.self] }
        set { self[MeetingActionsKey.self] = newValue }
    }
}

extension View {
    /// Asks before throwing away a recording that's in progress.
    func discardConfirmation(_ isPresented: Binding<Bool>) -> some View {
        modifier(DiscardConfirmation(isPresented: isPresented))
    }
}

private struct DiscardConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    @EnvironmentObject var state: AppState

    func body(content: Content) -> some View {
        content.confirmationDialog("Discard this recording?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) { state.discardRecording() }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("Hootnote stops recording and moves what was captured to the Trash. Nothing is transcribed.")
        }
    }
}
