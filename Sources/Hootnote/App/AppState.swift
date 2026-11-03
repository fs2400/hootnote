import AppKit
import Foundation
import SwiftUI

/// Ties call detection, recording, and processing together.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings = AppSettings.shared
    let store = MeetingStore()
    let voiceprints = VoiceprintStore()
    let detector = CallDetector()
    let panels = FloatingPanels()
    lazy var processor = ProcessingQueue(store: store, voiceprints: voiceprints)

    let dictations = DictationStore()
    lazy var dictation = DictationController(store: dictations)

    enum Route: Hashable {
        case home, meetings, dictations
        case meeting(UUID)
    }

    @Published private(set) var recording: RecordingSession?
    /// A calling app we detected and are asking about.
    @Published private(set) var prompt: MeetingApp?
    @Published var route: Route = .home
    @Published var lastError: String?
    /// A moment to jump to when a meeting opens (from a search result).
    @Published var pendingSeek: (meeting: UUID, time: Double)?
    /// The search text, shared so an open meeting can highlight matches instead of leaving.
    @Published var searchQuery = ""

    /// Opens a meeting at a moment in its recording.
    func open(meeting id: UUID, at time: Double) {
        pendingSeek = (id, time)
        route = .meeting(id)
    }

    /// Speaks a status change for VoiceOver users.
    func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    var selectedMeetingID: UUID? {
        if case .meeting(let id) = route { return id }
        return nil
    }

    /// Apps you said "Not now" to (or stopped manually) for the call that's still going.
    private var declined: Set<String> = []
    /// When the recorded app let go of the mic, if it has.
    private var micReleasedAt: Date?
    private var heardRemoteSinceRelease = false
    var openMainWindow: (() -> Void)?
    /// Off only in the --stop-test diagnostic: its test recordings aren't transcribed and show no indicator.
    var processesRecordings = true

    /// Why a recording stopped. Saved as Meeting.stopReason and logged at notice level, so a split
    /// call can be explained afterwards (info-level lines aren't kept by macOS).
    enum StopCause {
        /// The grace period, or the longer reconnect wait during a calendar event, ran out.
        case waitEnded(seconds: TimeInterval, reconnect: Bool)
        /// The app took the mic again after letting go of it in silence: a new back-to-back call.
        case newCall(gap: TimeInterval)
        /// Another calling app took the mic (MeetingApps ids, plus every process using the mic).
        case otherCall(apps: [String], micUsers: [String])
        /// You stopped it; `from` names the control.
        case manual(from: String)
        /// You chose to record another calling app instead.
        case switched(to: String)
        case quit
    }

    private init() {}

    func bootstrap() {
        Notifier.shared.setUp()
        Notifier.shared.onOpenMeeting = { [weak self] id in self?.show(meeting: id) }
        applyDockIconSetting()
        recoverInterruptedWork()

        detector.onTick = { [weak self] state in self?.handle(state) }
        if settings.detectionEnabled { detector.start() }
        if settings.hasCompletedOnboarding { processor.warmUp() }
        // Meetings from before levelled playback get their playback file in the background.
        processor.buildMissingPlayback()

        dictation.transcribe = { [weak self] samples in
            guard let self else { return "" }
            return try await self.transcribeDictation(samples)
        }
        dictation.activate()
    }

    /// Work interrupted by a quit, crash or restart picks up again here.
    func recoverInterruptedWork() {
        for m in store.meetings where m.status == .recording || m.status == .queued || m.status == .processing {
            if m.appID == MeetingApps.upload.id, m.endedAt == nil {
                // The upload stopped while the file was still being read: don't transcribe half a file.
                try? FileManager.default.removeItem(at: m.rawCaptureURL(.mic))
                store.update(m.id) {
                    $0.status = .failed
                    $0.statusDetail = "The upload was interrupted before Hootnote finished reading the file. Upload it again."
                }
                continue
            }
            // A recording cut short keeps what was captured.
            if m.status == .recording {
                let lastWrite = (try? m.rawCaptureURL(.mic).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let reason = "crash: Hootnote stopped without ending the recording (crash, force quit or restart)"
                    + " · audio last written \(lastWrite.map(Self.stamp) ?? "unknown") · recovered at launch \(Self.stamp(Date()))"
                store.update(m.id) {
                    $0.endedAt = $0.endedAt ?? Date()
                    $0.stopReason = $0.stopReason ?? reason
                }
                log.notice("Recording \(m.id, privacy: .public) stopped: \(reason, privacy: .public)")
            }
            if processesRecordings { processor.enqueue(m.id) }
        }
    }

    private func transcribeDictation(_ samples: [Float]) async throws -> String {
        try await processor.ensureModelsReady()
        let options = WhisperOptions(language: settings.language == "auto" ? nil : settings.language,
                                     vocabulary: settings.customVocabulary)
        let words = try await TranscriptionEngine.shared.transcribe(samples: samples, options: options, retime: false) { _ in }
        return words.map(\.text).joined(separator: " ")
    }

    // MARK: - Upload

    /// Transcribes audio or video files as in-person meetings (everyone separated by voice).
    func importFiles(_ urls: [URL]) {
        for (index, url) in urls.enumerated() {
            let id = UUID()
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            var meeting = Meeting(id: id, title: url.deletingPathExtension().lastPathComponent,
                                  appName: MeetingApps.upload.name, appID: MeetingApps.upload.id,
                                  startedAt: created, endedAt: nil, status: .queued)
            meeting.statusDetail = "Reading the file…"
            store.upsert(meeting)
            if index == 0 { route = .meeting(id) }
            let destination = meeting.rawCaptureURL(.mic)
            Task {
                do {
                    let duration = try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try await AudioImporter.extract(from: url, to: destination)
                    }.value
                    store.update(id) { $0.endedAt = $0.startedAt.addingTimeInterval(duration); $0.statusDetail = nil }
                    processor.enqueue(id)
                } catch {
                    store.update(id) { $0.status = .failed; $0.statusDetail = error.localizedDescription; $0.endedAt = $0.startedAt }
                }
            }
        }
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AudioImporter.allowedTypes
        panel.message = "Choose recordings or videos to transcribe"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    // MARK: - Delete

    func delete(meeting id: UUID) {
        if recording?.id == id { discardRecording(from: "deleting the meeting"); return }
        // A join reads both meetings' files until it finishes.
        guard !processor.joiningIDs.contains(id) else { return }
        store.moveToTrash(id)
        UndoTarget.meetingDeleted(id)
        if selectedMeetingID == id { route = .meetings }
    }

    // MARK: - Join

    /// The meeting "Join with Previous Meeting" would join this one to, and why it can't (nil when it can).
    func joinCandidate(for id: UUID) -> (previous: Meeting, problem: String?)? {
        guard let meeting = store.meeting(id), let previous = store.meeting(before: meeting) else { return nil }
        return (previous, MeetingJoiner.problem(joining: previous, with: meeting, store: store))
    }

    /// Joins a meeting onto the end of the one before it; the joined meeting opens while it works.
    func joinWithPrevious(_ id: UUID) {
        guard let candidate = joinCandidate(for: id), candidate.problem == nil else { return }
        processor.enqueueJoin(candidate.previous.id, id)
        route = .meeting(candidate.previous.id)
        announce("Joining the two meetings.")
    }

    var isRecording: Bool { recording != nil }

    func setDetection(_ enabled: Bool) {
        settings.detectionEnabled = enabled
        if enabled { detector.start() } else { detector.stop(); dismissPrompt() }
    }

    func applyDockIconSetting() {
        NSApp.setActivationPolicy(settings.hideDockIcon ? .accessory : .regular)
    }

    // MARK: - Detection

    private func isEnabled(_ appID: String) -> Bool { !settings.disabledApps.contains(appID) }

    private func handle(_ state: CallDetector.State) {
        declined.formIntersection(state.micApps)
        if let p = prompt, !state.micApps.contains(p.id) { dismissPrompt() }

        if let rec = recording {
            guard rec.app.id != MeetingApps.manual.id else { return }
            updateAutoStop(rec, state)
            if recording != nil {
                // A second calling app is using the mic while we record the first: offer to switch.
                if prompt == nil,
                   let other = state.micApps.first(where: { $0 != rec.app.id && isEnabled($0) && !declined.contains($0) }),
                   let app = MeetingApps.app(id: other) {
                    showPrompt(app)
                }
                return
            }
        }
        // Not recording (or the last call just ended, e.g. back-to-back): look for a call to record.
        startOrPromptIfNeeded(state)
    }

    private func startOrPromptIfNeeded(_ state: CallDetector.State) {
        guard settings.detectionEnabled, recording == nil, prompt == nil else { return }
        let candidates = state.micApps.filter { isEnabled($0) && !declined.contains($0) }
        // Prefer dedicated calling apps over browsers when both hold the mic.
        guard let id = candidates.sorted(by: { (MeetingApps.app(id: $0)?.isBrowser ?? true ? 1 : 0) < (MeetingApps.app(id: $1)?.isBrowser ?? true ? 1 : 0) }).first,
              let app = MeetingApps.app(id: id) else { return }
        if settings.shouldAutoRecord(appID: app.id) {
            startRecording(app: app)
        } else {
            showPrompt(app)
        }
    }

    /// How long to wait for the call to come back while its calendar event is still on: Teams and
    /// Zoom let go of the mic while they reconnect, which split one call into two meetings.
    static let reconnectWait: TimeInterval = 180

    /// Ends the recording when the call does. The calling app releasing the mic is the main signal;
    /// a grace period covers device switches, and call audio still playing means you're just muted.
    /// Not private so the --stop-test diagnostic can drive it with made-up detector states.
    func updateAutoStop(_ rec: RecordingSession, _ state: CallDetector.State) {
        let now = Date()
        let micHeld = state.micApps.contains(rec.app.id)
        if micHeld {
            if let released = micReleasedAt, now.timeIntervalSince(released) >= 6, !heardRemoteSinceRelease,
               !isEventStillOn(rec, at: now) {
                // The app let go of the mic for a while in silence and then took it again:
                // that's a new call (back-to-back in the same app), not a device switch.
                stopRecording(.newCall(gap: now.timeIntervalSince(released)), endedAt: released, at: now)
                return
            }
            // Same call: a device switch, or a reconnect while its calendar event is still on.
            if let released = micReleasedAt {
                let gap = String(format: "%.1f", now.timeIntervalSince(released))
                log.notice("Recording \(rec.id, privacy: .public): \(rec.app.id, privacy: .public) took the mic back after \(gap, privacy: .public) s; recording continues")
            }
            if rec.endingAt != nil { announce("The call is back. Hootnote keeps recording.") }
            micReleasedAt = nil
            rec.endingAt = nil
            rec.setPaused(false)
            return
        }
        if micReleasedAt == nil {
            micReleasedAt = now
            heardRemoteSinceRelease = false
            let event = eventCheck(rec, at: now).note
            log.notice("Recording \(rec.id, privacy: .public): \(rec.app.id, privacy: .public) released the mic at \(Self.stamp(now), privacy: .public) · \(event, privacy: .public)")
        }
        if now.timeIntervalSince(rec.lastRemoteAudio) < 1.5 { heardRemoteSinceRelease = true }

        let stillPlaying = !rec.app.isBrowser && state.outputApps.contains(rec.app.id)
            && now.timeIntervalSince(rec.lastRemoteAudio) < 30
        if rec.keepRecording || stillPlaying {
            rec.endingAt = nil
            rec.setPaused(false)
            return
        }
        let released = micReleasedAt ?? now
        let grace = TimeInterval(settings.endGraceSeconds)
        // While the meeting's calendar event is on, wait longer for the call to reconnect. Past the
        // usual grace period nothing is recorded, so a call that really ended adds no room audio.
        let waitForReconnect = isEventStillOn(rec, at: now)
        let wait = waitForReconnect ? max(grace, Self.reconnectWait) : grace
        let deadline = released.addingTimeInterval(wait)
        if rec.endingAt == nil {
            announce(waitForReconnect
                ? "The call seems to have ended. Hootnote waits \(Int(Self.reconnectWait / 60)) minutes in case it reconnects."
                : "The call seems to have ended. Recording stops in \(settings.endGraceSeconds) seconds.")
        }
        rec.endingAt = deadline
        rec.setPaused(waitForReconnect && now >= released.addingTimeInterval(grace))
        // Joining another call right away (back-to-back): end this one now. A browser using the mic
        // during the same calendar event isn't enough: browsers use the mic for many things.
        let otherCalls = state.micApps.filter { id in
            id != rec.app.id && isEnabled(id) && !(waitForReconnect && MeetingApps.app(id: id)?.isBrowser == true)
        }
        if !otherCalls.isEmpty {
            stopRecording(.otherCall(apps: otherCalls.sorted(), micUsers: detector.micUsers), endedAt: micReleasedAt, at: now)
        } else if now >= deadline {
            stopRecording(.waitEnded(seconds: wait, reconnect: waitForReconnect), endedAt: micReleasedAt, at: now)
        }
    }

    /// True while the calendar event this recording belongs to is still the one you're in.
    private func isEventStillOn(_ rec: RecordingSession, at now: Date) -> Bool {
        eventCheck(rec, at: now).isOn
    }

    /// isEventStillOn, plus a short note on why, for the stop reason.
    private func eventCheck(_ rec: RecordingSession, at now: Date) -> (isOn: Bool, note: String) {
        guard settings.useCalendar else { return (false, "event still on: no (calendar off)") }
        guard let event = rec.calendarEvent else { return (false, "event still on: no (no calendar event)") }
        guard now < event.end else { return (false, "event still on: no (it ended \(Self.stamp(event.end)))") }
        guard let current = CalendarHelper.shared.currentEvent(at: now) else {
            return (false, "event still on: no (no current event)")
        }
        return current.id == event.id
            ? (true, "event still on: yes (same event id, ends \(Self.stamp(event.end)))")
            : (false, "event still on: no (another event is current)")
    }

    /// UTC with milliseconds, comparable with meeting.json's dates.
    nonisolated static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // MARK: - Prompt

    private func showPrompt(_ app: MeetingApp) {
        prompt = app
        panels.showPrompt(CallPromptView(app: app, isSwitch: recording != nil).environmentObject(self))
        NSSound(named: "Tink")?.play()
        announce("\(app.name) call detected. Record and transcribe this call?")
    }

    func dismissPrompt() {
        prompt = nil
        panels.hidePrompt()
    }

    func acceptPrompt(always: Bool) {
        guard let app = prompt else { return }
        if always { settings.autoRecordApps.insert(app.id) }
        dismissPrompt()
        if recording != nil { stopRecording(.switched(to: app.id)) }
        startRecording(app: app)
    }

    func declinePrompt() {
        if let app = prompt { declined.insert(app.id) }
        dismissPrompt()
    }

    // MARK: - Recording

    func startManualRecording() {
        startRecording(app: MeetingApps.manual)
    }

    func startRecording(app: MeetingApp) {
        guard recording == nil else { return }
        Task { await startRecordingAsync(app: app) }
    }

    private func startRecordingAsync(app: MeetingApp) async {
        if Permissions.microphone == .notAsked { _ = await Permissions.requestMicrophone() }
        guard recording == nil else { return }

        let now = Date()
        var meeting = Meeting(id: UUID(), title: defaultTitle(for: app, at: now), appName: app.name, appID: app.id,
                              startedAt: now, endedAt: nil, status: .recording)
        let event = settings.useCalendar ? CalendarHelper.shared.currentEvent(at: now) : nil
        if let event {
            meeting.title = event.title
            meeting.attendees = event.attendees
        }
        store.upsert(meeting)

        let session = RecordingSession(meetingID: meeting.id, app: app)
        session.calendarEvent = event.map { ($0.id, $0.end) }
        do {
            try session.start(in: meeting.folder)
        } catch {
            store.update(meeting.id) { $0.status = .failed; $0.statusDetail = error.localizedDescription; $0.endedAt = Date() }
            lastError = "Couldn't start recording: \(error.localizedDescription)"
            Notifier.shared.post(title: "Couldn't start recording", body: error.localizedDescription)
            return
        }
        recording = session
        micReleasedAt = nil
        declined.remove(app.id)
        if settings.showFloatingIndicator, processesRecordings {
            panels.showHUD(RecordingHUDView(session: session).environmentObject(self))
        }
        let eventNote = eventCheck(session, at: now).note
        log.notice("Recording \(meeting.id, privacy: .public) started for \(app.id, privacy: .public) · \(eventNote, privacy: .public)")
        announce("Hootnote is recording \(app.name)")
    }

    /// - Parameters:
    ///   - cause: why, saved as Meeting.stopReason.
    ///   - endedAt: when the call actually ended (the trailing grace period is not counted).
    ///   - now: the moment the decision was made, so the reason's calendar check matches it.
    func stopRecording(_ cause: StopCause, endedAt: Date? = nil, at now: Date = Date()) {
        guard let rec = recording else { return }
        let reason = stopReason(cause, rec, at: now)
        rec.stop()
        recording = nil
        micReleasedAt = nil
        panels.hideHUD()
        // Stopping by hand mid-call means "don't ask me again for this call".
        switch cause {
        case .manual, .quit: declined.insert(rec.app.id)
        default: break
        }
        store.update(rec.id) { $0.endedAt = endedAt ?? Date(); $0.status = .queued; $0.stopReason = reason }
        if processesRecordings { processor.enqueue(rec.id) }
        log.notice("Recording \(rec.id, privacy: .public) stopped: \(reason, privacy: .public)")
        announce("Recording stopped. Transcribing.")
    }

    /// - Parameter source: the control used, for the stop reason kept in the trashed meeting.json.
    func discardRecording(from source: String = "the Discard button") {
        guard let rec = recording else { return }
        let reason = "discard: you discarded the recording from \(source); moved to the Trash · " + releaseNote(rec, at: Date())
        rec.stop()
        recording = nil
        micReleasedAt = nil
        panels.hideHUD()
        declined.insert(rec.app.id)
        store.update(rec.id) { $0.endedAt = Date(); $0.stopReason = reason }
        log.notice("Recording \(rec.id, privacy: .public) stopped: \(reason, privacy: .public)")
        store.moveToTrash(rec.id)
        if selectedMeetingID == rec.id { route = .home }
    }

    /// One line, e.g. "otherCall: zoom took the mic (mic users: …) · mic released … · event still on: no (…)".
    private func stopReason(_ cause: StopCause, _ rec: RecordingSession, at now: Date) -> String {
        let what: String
        switch cause {
        case .waitEnded(let seconds, let reconnect):
            what = (reconnect ? "reconnectWait" : "grace")
                + ": the call didn't come back within \(Int(seconds)) s of the mic being released"
        case .newCall(let gap):
            what = "newCall: \(rec.app.id) took the mic again after \(String(format: "%.1f", gap)) s of silence"
                + " (6 s rule: a new back-to-back call)"
        case .otherCall(let apps, let micUsers):
            what = "otherCall: \(apps.joined(separator: ", ")) took the mic"
                + " (mic users: \(micUsers.isEmpty ? "none" : micUsers.joined(separator: ", ")))"
        case .manual(let source):
            what = "manual: you stopped it from \(source)"
        case .switched(let app):
            what = "switch: you chose to record \(app) instead"
        case .quit:
            what = "quit: you quit Hootnote while recording"
        }
        return what + " · " + releaseNote(rec, at: now)
    }

    /// When the recorded app let go of the mic, and whether its calendar event is still on.
    private func releaseNote(_ rec: RecordingSession, at now: Date) -> String {
        let mic: String
        if rec.app.id == MeetingApps.manual.id {
            mic = "no call app (in person)"
        } else if let released = micReleasedAt {
            mic = "mic released \(Self.stamp(released)) (\(String(format: "%.1f", now.timeIntervalSince(released))) s before the stop)"
        } else {
            mic = "mic still held by \(rec.app.id)"
        }
        return "\(mic) · \(eventCheck(rec, at: now).note)" + (rec.keepRecording ? " · Keep recording was on" : "")
    }

    private func defaultTitle(for app: MeetingApp, at date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if app.id == MeetingApps.manual.id { return "In-person meeting at \(time)" }
        let name = app.isBrowser ? "Browser" : app.name.replacingOccurrences(of: " huddle", with: "")
        return "\(name) call at \(time)"
    }

    // MARK: - Navigation

    func show(meeting id: UUID) {
        route = .meeting(id)
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}
