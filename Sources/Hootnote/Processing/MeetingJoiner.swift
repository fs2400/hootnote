import Foundation

/// Joins one call that was saved as two meetings (the call app let go of the microphone for a while)
/// back into one: the audio end to end with the real gap between the recordings kept as silence, the
/// second transcript moved to its place in time, and voices heard in both parts given one name.
enum MeetingJoiner {
    /// Meetings further apart than this aren't one call.
    static let maxGap: TimeInterval = 60 * 60

    enum JoinError: LocalizedError {
        case missingAudio, changed
        var errorDescription: String? {
            switch self {
            case .missingAudio: return "A recording is missing from its folder."
            case .changed: return "One of the meetings changed while the audio was being joined. Try again."
            }
        }
    }

    /// Why these two can't be joined, in words for the dialog; nil when they can. `first` started earlier;
    /// the dialog is shown on `second`.
    @MainActor
    static func problem(joining first: Meeting, with second: Meeting, store: MeetingStore) -> String? {
        func which(_ m: Meeting) -> String { m.id == second.id ? "This meeting" : "The earlier meeting, “\(first.title)”," }
        if let failed = [first, second].first(where: { $0.status == .failed }) {
            return "\(which(failed)) wasn't transcribed. Re-transcribe it, then join them."
        }
        guard first.status == .ready, second.status == .ready else {
            return "Both meetings need to finish recording and transcribing first."
        }
        if let m = [first, second].first(where: { $0.audioURL(.mic) == nil }) {
            return "\(which(m)) has no recording in its folder, so the audio can't be joined."
        }
        if let m = [first, second].first(where: { store.transcript(for: $0.id) == nil }) {
            return "\(which(m)) has no transcript. Re-transcribe it, then join them."
        }
        guard (first.audioURL(.system) == nil) == (second.audioURL(.system) == nil) else {
            return "One was recorded from a call and the other in person or uploaded, so their audio can't be lined up."
        }
        guard second.startedAt.timeIntervalSince(first.endedAt ?? first.startedAt) <= maxGap else {
            return "“\(first.title)” ended more than an hour before this meeting started."
        }
        return nil
    }

    /// The earlier meeting `meeting` looks like the rest of, so Hootnote can offer the join instead of leaving
    /// it to the Meeting menu: the same app and title (both named from the calendar event), started within
    /// the reconnect wait of that meeting's end, and joinable now. Nil once you've said "Not now" to the pair.
    @MainActor
    static func continuation(of meeting: Meeting, store: MeetingStore) -> Meeting? {
        // Uploads take their file's dates, not when anything was recorded.
        guard let app = meeting.appID, app != MeetingApps.upload.id,
              let previous = store.meeting(before: meeting), meeting.joinOfferDeclined != previous.id,
              previous.appID == app, previous.title == meeting.title,
              (0...AppState.reconnectWait).contains(meeting.startedAt.timeIntervalSince(previous.endedAt ?? previous.startedAt)),
              problem(joining: previous, with: meeting, store: store) == nil else { return nil }
        return previous
    }

    // MARK: - Audio

    struct JoinedAudio: Sendable {
        /// Where the second recording starts in the joined one, in seconds.
        var offset: Double
        var duration: Double
        var hasSystem: Bool
        /// False when either part's mic was stored echo-cancelled (meetings from older versions):
        /// the part kept as recorded is then echo-cancelled too, so the whole track is one format.
        var micIsRaw: Bool
        var echoNote: String?
        /// Start of each separately recorded part (see Meeting.parts).
        var parts: [Double]
    }

    /// Writes the joined tracks beside the first meeting's (mic.joined.m4a, system.joined.m4a).
    /// Nothing either meeting uses changes until `commitAudio`.
    static func writeJoinedAudio(first: Meeting, second: Meeting, engine: TranscriptionEngine) async throws -> JoinedAudio {
        let rate = AudioTrackWriter.sampleRate
        guard let firstMicURL = first.audioURL(.mic), let secondMicURL = second.audioURL(.mic) else { throw JoinError.missingAudio }
        var firstMic = try await engine.loadSamples(firstMicURL)
        var secondMic = try await engine.loadSamples(secondMicURL)
        var firstSystem: [Float]?, secondSystem: [Float]?
        if let url = first.audioURL(.system) { firstSystem = try await engine.loadSamples(url) }
        if let url = second.audioURL(.system) { secondSystem = try await engine.loadSamples(url) }
        let hasSystem = firstSystem != nil && secondSystem != nil
        let firstLength = max(firstMic.count, firstSystem?.count ?? 0)
        let secondLength = max(secondMic.count, secondSystem?.count ?? 0)
        // The second recording starts where it did in real time; never earlier than the first one's end.
        let offset = max(firstLength, Int((second.startedAt.timeIntervalSince(first.startedAt) * rate).rounded()))

        let raw = first.micIsRaw == true && second.micIsRaw == true
        var notes = (first.echoNote, second.echoNote)
        if !raw, hasSystem, let firstSystem, let secondSystem {
            if first.micIsRaw == true {
                let r = EchoCanceller.process(mic: padded(firstMic, to: firstLength), reference: padded(firstSystem, to: firstLength),
                                              parts: first.parts)
                firstMic = r.linear
                notes.0 = r.report.description
            }
            if second.micIsRaw == true {
                let r = EchoCanceller.process(mic: padded(secondMic, to: secondLength), reference: padded(secondSystem, to: secondLength),
                                              parts: second.parts)
                secondMic = r.linear
                notes.1 = r.report.description
            }
        }

        let folder = first.folder
        func write(_ a: [Float], _ b: [Float], to name: String) throws {
            try AudioFiles.replaceAAC(pieces: [.samples(a), .silence(offset - a.count), .samples(b), .silence(secondLength - b.count)],
                                      at: folder.appendingPathComponent("\(name).joined.m4a"), bitRate: 48_000)
        }
        try write(firstMic, secondMic, to: AudioTrack.mic.rawValue)
        if hasSystem, let firstSystem, let secondSystem {
            try write(firstSystem, secondSystem, to: AudioTrack.system.rawValue)
        }

        let offsetSeconds = Double(offset) / rate
        let echoNote = [notes.0, notes.1].compactMap { $0 }.first { $0.hasPrefix("echo cancelled") } ?? notes.0
        return JoinedAudio(offset: offsetSeconds, duration: Double(offset + secondLength) / rate, hasSystem: hasSystem,
                           micIsRaw: raw, echoNote: echoNote,
                           parts: (first.parts ?? [0]) + (second.parts ?? [0]).map { $0 + offsetSeconds })
    }

    /// Puts the joined tracks in place of the first meeting's. Everything they replace moves to `backup`
    /// (meant for the Trash), with a copy of its transcript, summary and details, so a join loses nothing.
    /// The playback file and stereo master covered only the first part, so they go too (the player falls
    /// back to the tracks until they're rebuilt). If a move fails, what was moved is put back.
    static func commitAudio(in folder: URL, hasSystem: Bool, backup: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["meeting.json", "transcript.json", "transcript.uncleaned.json", "summary.json"]
        where fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            try fm.copyItem(at: folder.appendingPathComponent(name), to: backup.appendingPathComponent(name))
        }
        let tracks = hasSystem ? [AudioTrack.mic, .system] : [.mic]
        let replaced = tracks.flatMap { ["\($0.rawValue).m4a", "\($0.rawValue).caf"] } + ["playback.m4a", "recording.m4a"]
        var moved: [String] = []
        do {
            for name in replaced where fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
                try fm.moveItem(at: folder.appendingPathComponent(name), to: backup.appendingPathComponent(name))
                moved.append(name)
            }
            for track in tracks {
                try fm.moveItem(at: folder.appendingPathComponent("\(track.rawValue).joined.m4a"),
                                to: folder.appendingPathComponent("\(track.rawValue).m4a"))
            }
        } catch {
            for track in tracks where !moved.isEmpty {
                try? fm.removeItem(at: folder.appendingPathComponent("\(track.rawValue).m4a"))
            }
            for name in moved {
                try? fm.moveItem(at: backup.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
            try? fm.removeItem(at: backup)
            throw error
        }
    }

    /// Where a join keeps the earlier meeting's replaced files until they go to the Trash. Outside the
    /// meetings folder, so putting it back from the Trash never adds a second copy of the meeting.
    static func backupFolder(for meeting: Meeting) -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted)).replacingOccurrences(of: ":", with: "")
        return AppPaths.meetings.deletingLastPathComponent()
            .appendingPathComponent("Before joining", isDirectory: true)
            .appendingPathComponent("\(meeting.title.sanitizedFileName) (before joining \(stamp))", isDirectory: true)
    }

    /// Removes joined tracks left by a join that didn't finish.
    static func discardJoinedAudio(in folder: URL) {
        for track in AudioTrack.allCases {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(track.rawValue).joined.m4a"))
        }
    }

    private static func padded(_ x: [Float], to count: Int) -> [Float] {
        x.count >= count ? x : x + [Float](repeating: 0, count: count - x.count)
    }

    // MARK: - Speakers and transcript

    /// Who the second part's speakers are in the joined meeting.
    struct SpeakerPlan {
        /// Second part's speaker ID -> joined speaker ID.
        var ids: [String: String]
        var speakers: [Speaker]
    }

    /// "Speaker 3" and the like: a placeholder, not a name you gave.
    static func isPlaceholder(_ name: String) -> Bool {
        name == "Unknown" || name.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    /// Matches the second part's speakers to the first's: you to you, the same name you gave in both,
    /// otherwise the closest voice above `threshold` (each person at most once). Two different names
    /// you gave are never combined, however alike the voices.
    /// - Parameter alsoSecond: the second part's original transcript, if Clean Up kept one: its speakers
    ///   get IDs too, so Restore Original still works on the joined meeting.
    static func planSpeakers(first: Transcript, second: Transcript, alsoSecond: Transcript?, threshold: Float) -> SpeakerPlan {
        var speakers = first.speakers
        var ids: [String: String] = [:]
        var taken = Set<String>()

        var secondSpeakers: [Speaker] = []
        for s in second.speakers + (alsoSecond?.speakers ?? []) where !secondSpeakers.contains(where: { $0.id == s.id }) {
            secondSpeakers.append(s)
        }

        // You, and names you gave in both parts.
        for s in secondSpeakers {
            if s.isMe || s.id == TranscriptBuilder.meID, let me = speakers.first(where: { $0.isMe || $0.id == TranscriptBuilder.meID }) {
                ids[s.id] = me.id
                taken.insert(me.id)
            } else if !isPlaceholder(s.name),
                      let same = speakers.first(where: { !taken.contains($0.id) && $0.name.caseInsensitiveCompare(s.name) == .orderedSame }) {
                ids[s.id] = same.id
                taken.insert(same.id)
            }
        }

        // Voices, best pairs first.
        var pairs: [(second: String, first: String, score: Float)] = []
        for s in secondSpeakers where ids[s.id] == nil {
            guard let e = s.embedding else { continue }
            for f in speakers where !f.isMe && !taken.contains(f.id) {
                guard let fe = f.embedding else { continue }
                // Two names you gave are two people.
                if !isPlaceholder(s.name), !isPlaceholder(f.name) { continue }
                let score = Cosine.similarity(e, fe)
                if score >= threshold { pairs.append((s.id, f.id, score)) }
            }
        }
        pairs.sort { $0.score > $1.score }
        for p in pairs where ids[p.second] == nil && !taken.contains(p.first) {
            ids[p.second] = p.first
            taken.insert(p.first)
            // A name you gave in the second part replaces a placeholder from the first.
            if let s = secondSpeakers.first(where: { $0.id == p.second }), !isPlaceholder(s.name),
               let i = speakers.firstIndex(where: { $0.id == p.first }) {
                speakers[i].name = s.name
                speakers[i].autoIdentified = s.autoIdentified
            }
        }

        // Everyone else joins as a new speaker, numbered on from the first part.
        var nextID = (speakers.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        var nextNumber = (speakers.compactMap { s in
            isPlaceholder(s.name) ? Int(s.name.split(separator: " ").last ?? "") : nil
        }.max() ?? 0) + 1
        for s in secondSpeakers where ids[s.id] == nil {
            var new = s
            if s.isMe || s.id == TranscriptBuilder.meID {
                new.id = TranscriptBuilder.meID
            } else {
                new.id = "S\(nextID)"
                nextID += 1
                if isPlaceholder(s.name) {
                    new.name = "Speaker \(nextNumber)"
                    nextNumber += 1
                }
            }
            ids[s.id] = new.id
            speakers.append(new)
        }
        return SpeakerPlan(ids: ids, speakers: speakers)
    }

    /// The first transcript followed by the second, moved `offset` seconds later, with the plan's speakers.
    static func join(_ first: Transcript, _ second: Transcript, offset: Double, plan: SpeakerPlan) -> Transcript {
        let moved = second.utterances.map { u -> Utterance in
            var u = u
            u.speakerID = plan.ids[u.speakerID] ?? u.speakerID
            u.start += offset
            u.end += offset
            for i in u.words.indices {
                u.words[i].start += offset
                u.words[i].end += offset
            }
            return u
        }
        let used = Set(first.utterances.map(\.speakerID) + moved.map(\.speakerID))
        // Speakers from the first part stay listed as they were; new ones only if they say something.
        let speakers = plan.speakers.filter { s in first.speakers.contains { $0.id == s.id } || used.contains(s.id) }
        return Transcript(speakers: speakers, utterances: first.utterances + moved, engine: first.engine, createdAt: Date())
    }
}

extension EchoCanceller {
    /// Cancels each separately recorded part on its own (see Meeting.parts): the speaker-to-mic delay
    /// can differ between them. The report is that of the first part where echo was found.
    static func process(mic: [Float], reference: [Float], parts: [Double]?) -> (output: [Float], linear: [Float], report: Report) {
        let bounds = (parts ?? []).map { Int(($0 * Double(sampleRate)).rounded()) }.filter { $0 > 0 && $0 < mic.count }.sorted()
        guard !bounds.isEmpty else { return process(mic: mic, reference: reference) }
        var output: [Float] = [], linear: [Float] = []
        output.reserveCapacity(mic.count)
        linear.reserveCapacity(mic.count)
        var reports: [Report] = []
        let edges = [0] + bounds + [mic.count]
        for (start, end) in zip(edges, edges.dropFirst()) where end > start {
            let ref = Array(reference[min(start, reference.count)..<min(end, reference.count)])
            let r = process(mic: Array(mic[start..<end]), reference: ref)
            output += r.output
            linear += r.linear
            reports.append(r.report)
        }
        return (output, linear, reports.first(where: \.applied) ?? reports[0])
    }
}
