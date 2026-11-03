import Foundation

/// Hidden commands about why recordings stopped (Meeting.stopReason):
///   Hootnote --stop-reasons [count]     print id, times, app and stop reason of recent meetings (no titles)
///   Hootnote --stop-test run|recover    record a few seconds and stop each way, then print each stop reason
extension Diagnostics {
    static func stopReasons(_ count: Int) {
        let store = MeetingStore()
        for m in store.meetings.prefix(count) {
            let ended = m.endedAt.map(AppState.stamp) ?? "-"
            print("\(m.id)  \(AppState.stamp(m.startedAt)) → \(ended)  \(m.appID ?? "-")  \(m.status.rawValue)")
            print("    \(m.stopReason ?? "(no stop reason: recorded before stop reasons were kept)")")
        }
    }

    /// Drives AppState with made-up detector states (Teams, then another enabled calling app), using
    /// real capture: run it with `open -n` so the app's own mic and system audio permissions apply, and
    /// with HOOTNOTE_MEETINGS_DIR set to a scratch folder. Nothing is transcribed and no indicator shows.
    /// `run` ends with a recording left going and the process killed (a crash); `recover` then recovers it.
    static func stopTest(_ phase: String) async {
        guard ProcessInfo.processInfo.environment["HOOTNOTE_MEETINGS_DIR"] != nil else {
            print("Set HOOTNOTE_MEETINGS_DIR to a scratch folder: the test makes recordings.")
            return
        }
        // Line-buffered, so output written to a file survives the deliberate kill at the end.
        setvbuf(stdout, nil, _IOLBF, 0)
        let state = AppState.shared
        state.processesRecordings = false
        print("Meetings folder: \(AppPaths.meetings.path)")

        if phase == "recover" {
            let crashed = state.store.meetings.filter { $0.status == .recording }.map(\.id)
            state.recoverInterruptedWork()
            for id in crashed { printReason(id, "crash") }
            return
        }

        let settings = AppSettings.shared
        guard let teams = MeetingApps.app(id: "teams"),
              let other = MeetingApps.all.first(where: { !$0.isBrowser && $0.id != teams.id && !settings.disabledApps.contains($0.id) })
        else { print("No other enabled calling app to test with"); return }
        print("Grace period: \(settings.endGraceSeconds) s; other calling app: \(other.id)")

        func start() async -> RecordingSession? {
            state.startRecording(app: teams)
            for _ in 0..<50 where state.recording == nil { try? await Task.sleep(for: .milliseconds(100)) }
            // Don't depend on whatever is on your calendar right now.
            state.recording?.calendarEvent = nil
            if state.recording == nil { print("  recording didn't start") }
            return state.recording
        }
        /// One detector tick a second, as CallDetector does, until the recording stops or time runs out.
        func feed(_ rec: RecordingSession, _ micApps: Set<String>, for seconds: Int) async {
            for _ in 0..<seconds where state.recording === rec {
                state.updateAutoStop(rec, CallDetector.State(micApps: micApps, outputApps: []))
                try? await Task.sleep(for: .seconds(1))
            }
        }

        if let rec = await start() {
            await feed(rec, [teams.id], for: 2)
            await feed(rec, [], for: settings.endGraceSeconds + 5)
            printReason(rec.id, "grace")
        }
        if let rec = await start() {
            await feed(rec, [teams.id], for: 2)
            await feed(rec, [], for: 7)
            await feed(rec, [teams.id], for: 2)
            printReason(rec.id, "newCall")
        }
        if let rec = await start() {
            await feed(rec, [teams.id], for: 2)
            await feed(rec, [other.id], for: 3)
            printReason(rec.id, "otherCall")
        }
        if let rec = await start() {
            await feed(rec, [teams.id], for: 2)
            state.stopRecording(.manual(from: "the floating indicator"))
            printReason(rec.id, "manual")
        }
        if let rec = await start() {
            await feed(rec, [teams.id], for: 2)
            state.stopRecording(.quit) // what AppDelegate.applicationShouldTerminate calls after "Stop and Quit"
            printReason(rec.id, "quit")
        }
        if let rec = await start() {
            await feed(rec, [teams.id], for: 2)
            state.discardRecording()
            let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rec.id.uuidString)")
            printReason(rec.id, "discard", file: trashed.appendingPathComponent("meeting.json"))
        }
        if let rec = await start() {
            await feed(rec, [teams.id], for: 2)
            print("crash: killing this process while \(rec.id) records; run `--stop-test recover` next")
            kill(getpid(), SIGKILL)
        }
    }

    /// Reads stopReason back from meeting.json on disk, not from memory.
    private static func printReason(_ id: UUID, _ expected: String, file: URL? = nil) {
        let url = file ?? AppPaths.folder(for: id).appendingPathComponent("meeting.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let m = try? decoder.decode(Meeting.self, from: data) else {
            print("[\(expected)] \(id): FAILED, no meeting.json at \(url.path)"); return
        }
        let reason = m.stopReason ?? "nil"
        let ok = reason.hasPrefix(expected + ":")
        print("[\(expected)] \(ok ? "OK" : "WRONG") \(id) (\(String(format: "%.1f", m.duration)) s)\n    \(reason)")
    }
}
