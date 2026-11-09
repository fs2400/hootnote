import Foundation

/// Transcribes finished recordings one at a time, in the background.
/// Recording never waits on this: a new call can be recorded while the last one is processed.
@MainActor
final class ProcessingQueue: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var progress: String = ""
    @Published private(set) var pendingIDs: [UUID] = []
    /// Model download/loading state shown in Settings and onboarding.
    @Published private(set) var modelStatus: String?
    @Published private(set) var modelsReady = false

    private let store: MeetingStore
    private let voiceprints: VoiceprintStore
    private let settings = AppSettings.shared
    private let engine = TranscriptionEngine.shared
    private var running = false
    /// Clean-ups asked for from the Meeting menu; they run between transcriptions.
    private var cleanupIDs: [UUID] = []
    /// Joins asked for from the Meeting menu (earlier meeting, later meeting); also between transcriptions.
    private var joins: [(first: UUID, second: UUID)] = []
    /// Both meetings of each join waiting or running, so nothing else changes them meanwhile.
    @Published private(set) var joiningIDs: Set<UUID> = []
    /// Joins that didn't finish, by earlier meeting: the later one, for Try Again.
    @Published private(set) var failedJoins: [UUID: UUID] = [:]
    /// The last join that finished, for the notice in the joined meeting.
    @Published private(set) var lastJoined: (id: UUID, at: Date)?
    /// Bumped when a meeting's playback file is rebuilt, so an open player reloads it.
    @Published private(set) var playbackVersion: [UUID: Int] = [:]

    init(store: MeetingStore, voiceprints: VoiceprintStore) {
        self.store = store
        self.voiceprints = voiceprints
    }

    func enqueue(_ id: UUID) {
        guard activeID != id, !pendingIDs.contains(id), !joiningIDs.contains(id) else { return }
        pendingIDs.append(id)
        store.update(id) { $0.status = .queued; $0.statusDetail = nil }
        runNext()
    }

    /// Loads (downloading on first run) the models ahead of the first meeting.
    func warmUp() {
        guard !modelsReady, modelStatus == nil else { return }
        Task {
            do {
                try await prepareModels()
            } catch {
                modelStatus = "Couldn't load speech models: \(error.localizedDescription)"
            }
        }
    }

    /// Loads the speech models if they aren't already (used by dictation).
    func ensureModelsReady() async throws {
        if !modelsReady { try await prepareModels() }
    }

    /// Called when the speech model setting changes.
    func reloadModels() {
        modelsReady = false
        modelStatus = nil
        warmUp()
    }

    private func prepareModels() async throws {
        let model = settings.transcriptionModel
        try await engine.prepare(model: model) { text in
            Task { @MainActor [weak self] in self?.modelStatus = text }
        }
        modelStatus = nil
        modelsReady = true
    }

    func enqueueCleanUp(_ id: UUID) {
        guard activeID != id, !pendingIDs.contains(id), !cleanupIDs.contains(id), !joiningIDs.contains(id) else { return }
        cleanupIDs.append(id)
        store.setTransientDetail(id, "Waiting to clean up…")
        runNext()
    }

    /// Joins `second` onto the end of `first` (see MeetingJoiner), then moves `second` to the Trash.
    func enqueueJoin(_ first: UUID, _ second: UUID) {
        let ids: Set = [first, second]
        guard !isBusy(first), !isBusy(second) else { return }
        joins.append((first, second))
        joiningIDs.formUnion(ids)
        failedJoins[first] = nil
        store.setTransientDetail(first, "Waiting to join…")
        store.setTransientDetail(second, "Waiting to join…")
        runNext()
    }

    /// Snapshot tool only: show meetings as being joined, or a join as just finished.
    func previewJoining(_ ids: Set<UUID>) { joiningIDs = ids }
    func previewJoined(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.lastJoined = (id, Date()) }
    }

    /// Being transcribed, cleaned up or joined, or waiting to be.
    func isBusy(_ id: UUID) -> Bool {
        activeID == id || pendingIDs.contains(id) || cleanupIDs.contains(id) || joiningIDs.contains(id)
    }

    private enum Job {
        case transcribe(UUID), cleanUp(UUID), join(UUID, UUID)
    }

    private func runNext() {
        guard !running else { return }
        // New calls first, so the next transcript is never held up by work on older ones.
        let job: Job
        if !pendingIDs.isEmpty {
            job = .transcribe(pendingIDs.removeFirst())
        } else if !joins.isEmpty {
            let next = joins.removeFirst()
            job = .join(next.first, next.second)
        } else if !cleanupIDs.isEmpty {
            job = .cleanUp(cleanupIDs.removeFirst())
        } else {
            return
        }
        running = true
        switch job {
        case .transcribe(let id), .cleanUp(let id), .join(let id, _): activeID = id
        }
        Task {
            switch job {
            case .transcribe(let id): await process(id)
            case .cleanUp(let id): await cleanUp(id)
            case .join(let first, let second): await join(first, second)
            }
            activeID = nil
            progress = ""
            running = false
            runNext()
        }
    }

    /// A progress callback that reports "<label>… 40%" from the engine's background work.
    private func progressReporter(_ id: UUID, _ label: String) -> @Sendable (Double) -> Void {
        setProgress(id, "\(label)…")
        return { fraction in
            Task { @MainActor [weak self] in self?.setProgress(id, "\(label)… \(Int(fraction * 100))%") }
        }
    }

    private func setProgress(_ id: UUID, _ text: String) {
        progress = text
        store.setTransientDetail(id, text)
    }

    private func process(_ id: UUID) async {
        guard let meeting = store.meeting(id) else { return }
        playbackVersion[id, default: 0] += 1
        store.update(id) { $0.status = .processing }
        do {
            setProgress(id, "Loading speech models…")
            try await prepareModels()
            // In-person recordings and uploaded files: one mixed track, everyone separated by voice.
            let inPerson = meeting.appID == MeetingApps.manual.id || meeting.appID == MeetingApps.upload.id
            let hasCallTrack = meeting.audioURL(.system) != nil

            // 1. Decode both isolated tracks (16 kHz mono) and line them up sample-for-sample.
            setProgress(id, "Preparing audio…")
            let fromCapture = FileManager.default.fileExists(atPath: meeting.rawCaptureURL(.mic).path)
            var mic = try await meeting.audioURL(.mic).asyncMap { try await engine.loadSamples($0) } ?? []
            var system = try await meeting.audioURL(.system).asyncMap { try await engine.loadSamples($0) } ?? []
            let length = max(mic.count, system.count)
            mic += [Float](repeating: 0, count: length - mic.count)
            system += [Float](repeating: 0, count: length - system.count)

            // 2. Remove any call audio your mic picked up from the speakers. Whisper gets the fully
            //    suppressed version; playback gets the linear one, which never chops your voice.
            var echoNote: String?
            var heard = mic, listen = mic
            var echoPresent = false
            if !inPerson, length > 0 {
                setProgress(id, "Removing speaker echo from your microphone…")
                let result = await engine.cancelEcho(mic: mic, reference: system, parts: meeting.parts)
                heard = result.output
                listen = result.linear
                echoPresent = result.report.applied
                echoNote = result.report.description
                log.info("Echo canceller: \(result.report.description)")
            }

            // 3. Whisper on each track separately: your voice and the call never mix. Parakeet then
            //    puts every word on its exact time.
            let options = WhisperOptions(language: settings.language == "auto" ? nil : settings.language,
                                         vocabulary: settings.customVocabulary)
            let micWords = try await engine.transcribe(samples: heard, options: options,
                                                       progress: progressReporter(id, "Transcribing your microphone"))
            let systemWords = try await engine.transcribe(samples: system, options: options,
                                                          progress: progressReporter(id, "Transcribing the other participants"))

            // 4. pyannote on the call track only. Your voice is already known (it's the mic track),
            //    so it can never be confused with a remote speaker, even when you talk over each other.
            setProgress(id, "Working out who said what…")
            var systemDiarization = TranscriptionEngine.Diarization(segments: [], speakers: [])
            if !systemWords.isEmpty {
                systemDiarization = (try? await engine.diarize(samples: system)) ?? systemDiarization
            }
            // In-person recordings (no call app): everyone is on your mic, so split it by voice instead.
            // On a call with speaker echo, the voices on your mic tell your words from the call's echo.
            var micDiarization: TranscriptionEngine.Diarization?
            if (inPerson || echoPresent), !micWords.isEmpty {
                micDiarization = try? await engine.diarize(samples: heard)
            }

            var built = TranscriptBuilder.build(micWords: micWords, systemWords: systemWords,
                                                systemSegments: systemDiarization.segments,
                                                micSegments: inPerson ? micDiarization?.segments : nil)
            if built.echoWordsRemoved > 0 {
                log.info("Text echo filter removed \(built.echoWordsRemoved) words from the mic track")
            }

            // 5. Clean up before anyone reads it: echo fragments under your name, Whisper's loops.
            setProgress(id, "Cleaning up the transcript…")
            let uncleaned = built.utterances
            let voices = (echoPresent ? micDiarization : nil).map {
                TranscriptCleaner.Voices(micSegments: $0.segments, micSpeakers: $0.speakers,
                                         callVoices: systemDiarization.speakers.map(\.embedding))
            }
            let cleaned = TranscriptCleaner.clean(built.utterances, audio: .init(mic: heard, system: system),
                                                  voices: voices, echoPresent: echoPresent)
            built.utterances = cleaned.utterances
            log.info("Clean-up: \(cleaned.report.description)")

            let speakers = nameSpeakers(built: built, system: systemDiarization, mic: inPerson ? micDiarization : nil,
                                        meeting: meeting)
            let engineName = "\(settings.transcriptionModel.shortName) · pyannote Community-1 diarization"
            let transcript = Transcript(speakers: speakers, utterances: built.utterances, engine: engineName, createdAt: Date())
            if cleaned.report.changed {
                store.saveUncleaned(Transcript(speakers: speakers, utterances: uncleaned, engine: engineName, createdAt: Date()),
                                    for: id)
            } else {
                store.removeUncleaned(for: id)
            }
            store.saveTranscript(transcript, for: id)
            UndoTarget.transcriptReplaced(id)

            // 6. Keep the audio: what the player plays (levelled, echo kept out), a stereo master
            //    (channel 1 = you, 2 = the call), and the two tracks as recorded so they can be processed
            //    again. Raw captures are removed only once everything is written.
            setProgress(id, "Saving audio…")
            let folder = meeting.folder
            let call = system, raw = mic, you = listen
            let yourWords = built.utterances.filter { $0.speakerID == TranscriptBuilder.meID }.flatMap(\.words)
            let mixWords = inPerson ? [] : yourWords
            try await Task.detached(priority: .utility) {
                let playback = PlaybackMixer.mix(mic: you, system: hasCallTrack ? call : nil,
                                                 yourWords: mixWords, echoPresent: echoPresent)
                try AudioFiles.replaceAAC(channels: [playback], at: folder.appendingPathComponent("playback.m4a"),
                                          bitRatePerChannel: 48_000)
                if hasCallTrack {
                    try AudioFiles.replaceAAC(channels: [you, call], at: folder.appendingPathComponent("recording.m4a"))
                }
                // Already-compressed tracks (a re-transcribe) are kept as they are: re-encoding loses quality.
                guard fromCapture else { return }
                for (name, samples) in hasCallTrack ? [("mic", raw), ("system", call)] : [("mic", raw)] {
                    try AudioFiles.replaceAAC(channels: [samples], at: folder.appendingPathComponent("\(name).m4a"),
                                              bitRatePerChannel: 48_000)
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(name).caf"))
                }
            }.value
            if fromCapture { store.update(id) { $0.micIsRaw = true } }

            store.update(id) { $0.status = .ready; $0.statusDetail = nil; $0.echoNote = echoNote }
            playbackVersion[id, default: 0] += 1

            if settings.summaryEnabled, !transcript.utterances.isEmpty {
                await summarize(id)
            }
            exportIfEnabled(id)
            let name = store.meeting(id)?.title ?? "Meeting"
            var body = "\(name) · \(transcript.speakers.count) speakers"
            // A call that dropped and came back: the meeting's header offers the join.
            if let meeting = store.meeting(id), let previous = MeetingJoiner.continuation(of: meeting, store: store) {
                body += "\nLooks like the rest of the \(JoinRequest.time(previous)) meeting. Open it to join them."
            }
            Notifier.shared.post(title: "Transcript ready", body: body, meetingID: id)
        } catch {
            log.error("Processing failed: \(error.localizedDescription)")
            store.update(id) { $0.status = .failed; $0.statusDetail = error.localizedDescription }
            Notifier.shared.post(title: "Transcription failed", body: error.localizedDescription, meetingID: id)
        }
    }

    // MARK: - Clean up and playback for existing meetings

    /// The processed signals, re-derived from a meeting's stored tracks: what Whisper heard from your mic,
    /// what playback uses, and the call.
    private func storedTracks(_ meeting: Meeting) async throws -> (heard: [Float], listen: [Float], system: [Float]?, echoPresent: Bool) {
        var mic = try await meeting.audioURL(.mic).asyncMap { try await engine.loadSamples($0) } ?? []
        guard var system = try await meeting.audioURL(.system).asyncMap({ try await engine.loadSamples($0) }) else {
            return (mic, mic, nil, false)
        }
        let length = max(mic.count, system.count)
        mic += [Float](repeating: 0, count: length - mic.count)
        system += [Float](repeating: 0, count: length - system.count)
        if meeting.micIsRaw == true {
            let result = await engine.cancelEcho(mic: mic, reference: system, parts: meeting.parts)
            return (result.output, result.linear, system, result.report.applied)
        }
        // Older meetings stored the echo-cancelled mic.
        return (mic, mic, system, meeting.echoNote?.hasPrefix("echo cancelled") == true)
    }

    /// Clean Up for a meeting transcribed before it existed (or again after edits). The transcript as it
    /// was is kept, so Restore Original can bring it back.
    private func cleanUp(_ id: UUID) async {
        guard let meeting = store.meeting(id), meeting.status == .ready, var transcript = store.transcript(for: id) else {
            store.setTransientDetail(id, nil); return
        }
        let inPerson = meeting.appID == MeetingApps.manual.id || meeting.appID == MeetingApps.upload.id
        do {
            setProgress(id, "Cleaning up: reading the audio…")
            let tracks = try await storedTracks(meeting)
            var voices: TranscriptCleaner.Voices?
            if tracks.echoPresent, !inPerson {
                setProgress(id, "Cleaning up: telling your voice from the call's echo…")
                try await prepareModels()
                let d = try await engine.diarize(samples: tracks.heard)
                voices = .init(micSegments: d.segments, micSpeakers: d.speakers,
                               callVoices: transcript.speakers.compactMap(\.embedding))
            }
            // Edits made while the audio was being analysed are kept: clean the transcript as it is now.
            transcript = store.transcript(for: id) ?? transcript
            let original = transcript
            let cleaned = TranscriptCleaner.clean(transcript.utterances,
                                                  audio: tracks.system.map { .init(mic: tracks.heard, system: $0) },
                                                  voices: voices, echoPresent: tracks.echoPresent && !inPerson)
            log.info("Clean-up of \(meeting.title): \(cleaned.report.description)")
            if cleaned.report.changed {
                if store.uncleaned(for: id) == nil { store.saveUncleaned(original, for: id) }
                transcript.utterances = cleaned.utterances
                store.saveTranscript(transcript, for: id)
                UndoTarget.transcriptReplaced(id)
            }
            setProgress(id, "Cleaning up: levelling the audio…")
            try await buildPlayback(meeting, transcript: transcript, tracks: tracks)
            store.setTransientDetail(id, nil)
            let summary = cleaned.report.echoWords > 0
                ? "Removed \(cleaned.report.echoWords) words of speaker echo."
                : "Nothing needed removing."
            Notifier.shared.post(title: "Transcript cleaned up", body: "\(meeting.title): \(summary)", meetingID: id)
            exportIfEnabled(id)
        } catch {
            log.error("Clean-up failed: \(error.localizedDescription)")
            store.setTransientDetail(id, nil)
            store.update(id) { $0.statusDetail = "Clean up didn't finish: \(error.localizedDescription)" }
        }
    }

    /// Puts back the transcript as it was before Clean Up (speaker names stay as they are now).
    func restoreUncleaned(_ id: UUID) {
        guard var original = store.uncleaned(for: id), let current = store.transcript(for: id) else { return }
        let used = Set(original.utterances.map(\.speakerID))
        original.speakers = current.speakers + original.speakers.filter { s in
            used.contains(s.id) && !current.speakers.contains { $0.id == s.id }
        }
        store.saveTranscript(original, for: id)
        UndoTarget.transcriptReplaced(id)
        store.removeUncleaned(for: id)
        exportIfEnabled(id)
    }

    /// Writes playback.m4a: the levelled mix, with your track ducked while only the call talks.
    /// - Parameter stereoMaster: also write recording.m4a (you, the call) again, after a join.
    private func buildPlayback(_ meeting: Meeting, transcript: Transcript,
                               tracks: (heard: [Float], listen: [Float], system: [Float]?, echoPresent: Bool),
                               stereoMaster: Bool = false) async throws {
        let inPerson = meeting.appID == MeetingApps.manual.id || meeting.appID == MeetingApps.upload.id
        let words = inPerson ? [] : transcript.utterances.filter { $0.speakerID == TranscriptBuilder.meID }.flatMap(\.words)
        let url = meeting.playbackURL, stereoURL = meeting.stereoRecordingURL
        try await Task.detached(priority: .utility) {
            let mix = PlaybackMixer.mix(mic: tracks.listen, system: tracks.system, yourWords: words,
                                        echoPresent: tracks.echoPresent && !inPerson)
            try AudioFiles.replaceAAC(channels: [mix], at: url, bitRatePerChannel: 48_000)
            if stereoMaster, let system = tracks.system {
                try AudioFiles.replaceAAC(channels: [tracks.listen, system], at: stereoURL)
            }
        }.value
        playbackVersion[meeting.id, default: 0] += 1
    }

    /// Writes one meeting's playback file again (after the mixer changes).
    func rebuildPlayback(_ id: UUID) async throws {
        guard let meeting = store.meeting(id), let transcript = store.transcript(for: id) else { return }
        try await buildPlayback(meeting, transcript: transcript, tracks: try await storedTracks(meeting))
    }

    // MARK: - Join

    /// The join itself, for the queue and the --join-test diagnostic: joined audio, then the transcripts
    /// as they are now (edits made meanwhile are kept), then `removeSecond`, then playback.
    /// - Returns: the joined transcript, and the folder holding the earlier meeting's replaced files.
    func joinMeetings(_ firstID: UUID, _ secondID: UUID,
                      removeSecond: (UUID) -> Void) async throws -> (transcript: Transcript, originals: URL) {
        guard let first = store.meeting(firstID), let second = store.meeting(secondID) else { throw MeetingJoiner.JoinError.changed }
        if let problem = MeetingJoiner.problem(joining: first, with: second, store: store) {
            throw NSError(domain: "Hootnote", code: 2, userInfo: [NSLocalizedDescriptionKey: problem])
        }
        store.setTransientDetail(secondID, "Joining with the previous meeting…")
        setProgress(firstID, "Joining: reading both recordings…")
        let audio: MeetingJoiner.JoinedAudio
        do {
            let engine = engine
            audio = try await Task.detached(priority: .utility) {
                try await MeetingJoiner.writeJoinedAudio(first: first, second: second, engine: engine)
            }.value
        } catch {
            MeetingJoiner.discardJoinedAudio(in: first.folder)
            throw error
        }

        guard let a = store.transcript(for: firstID), let b = store.transcript(for: secondID),
              let secondNow = store.meeting(secondID), store.meeting(firstID)?.status == .ready, secondNow.status == .ready else {
            MeetingJoiner.discardJoinedAudio(in: first.folder)
            throw MeetingJoiner.JoinError.changed
        }
        let originalA = store.uncleaned(for: firstID), originalB = store.uncleaned(for: secondID)
        let plan = MeetingJoiner.planSpeakers(first: a, second: b, alsoSecond: originalB,
                                              threshold: Float(settings.voiceMatchThreshold))
        let joined = MeetingJoiner.join(a, b, offset: audio.offset, plan: plan)
        let joinedOriginal = (originalA != nil || originalB != nil)
            ? MeetingJoiner.join(originalA ?? a, originalB ?? b, offset: audio.offset, plan: plan) : nil

        let originals = MeetingJoiner.backupFolder(for: first)
        do {
            try MeetingJoiner.commitAudio(in: first.folder, hasSystem: audio.hasSystem, backup: originals)
        } catch {
            MeetingJoiner.discardJoinedAudio(in: first.folder)
            throw error
        }
        store.saveTranscript(joined, for: firstID)
        UndoTarget.transcriptReplaced(firstID)
        if let joinedOriginal { store.saveUncleaned(joinedOriginal, for: firstID) } else { store.removeUncleaned(for: firstID) }
        store.removeSummary(for: firstID)
        store.update(firstID) { m in
            m.endedAt = secondNow.endedAt ?? m.startedAt.addingTimeInterval(audio.duration)
            m.attendees += secondNow.attendees.filter { !m.attendees.contains($0) }
            m.micIsRaw = audio.micIsRaw
            m.echoNote = audio.echoNote
            m.parts = audio.parts
            m.statusDetail = nil
        }
        // Everything in the second meeting is in the first now.
        removeSecond(secondID)
        UndoTarget.meetingDeleted(secondID)
        playbackVersion[firstID, default: 0] += 1

        setProgress(firstID, "Joining: levelling the audio…")
        do {
            if let m = store.meeting(firstID) {
                try await buildPlayback(m, transcript: joined, tracks: try await storedTracks(m), stereoMaster: true)
            }
        } catch {
            // The join is done; the player uses the tracks until the next launch writes playback again.
            log.error("Playback after join failed: \(error.localizedDescription)")
        }
        store.setTransientDetail(firstID, nil)
        return (joined, originals)
    }

    private func join(_ firstID: UUID, _ secondID: UUID) async {
        defer { joiningIDs.subtract([firstID, secondID]) }
        do {
            let result = try await joinMeetings(firstID, secondID) { id in
                store.moveToTrash(id)
                // Its auto-exported file covered only the second part.
                for url in Exporter.autoExports(of: id, in: settings.exportFolder) {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }
            // The earlier meeting as it was goes to the Trash too, so nothing is lost.
            do {
                try FileManager.default.trashItem(at: result.originals, resultingItemURL: nil)
            } catch {
                log.error("Could not trash \(result.originals.path): \(error.localizedDescription)")
            }
            joiningIDs.subtract([firstID, secondID])
            lastJoined = (firstID, Date())
            if let m = store.meeting(firstID) {
                AppState.shared.announce("Meetings joined: \(m.duration.durationString).")
                Notifier.shared.post(title: "Meetings joined", body: "\(m.title) · \(m.duration.durationString)", meetingID: firstID)
            }
            if settings.summaryEnabled, !result.transcript.utterances.isEmpty { await summarize(firstID) }
            exportIfEnabled(firstID)
        } catch {
            log.error("Join failed: \(error.localizedDescription)")
            store.setTransientDetail(secondID, nil)
            failedJoins[firstID] = secondID
            store.update(firstID) { $0.statusDetail = "Join didn't finish: \(error.localizedDescription) Both meetings are unchanged." }
        }
    }

    /// Runs a join that didn't finish again.
    func retryJoin(_ firstID: UUID) {
        guard let second = failedJoins[firstID] else { return }
        store.update(firstID) { $0.statusDetail = nil }
        enqueueJoin(firstID, second)
    }

    /// One at a time, in the background: meetings that predate playback.m4a.
    func buildMissingPlayback() {
        let missing = store.meetings.filter {
            $0.status == .ready && !FileManager.default.fileExists(atPath: $0.playbackURL.path) && $0.audioURL(.mic) != nil
        }
        guard !missing.isEmpty else { return }
        Task {
            for m in missing {
                // A transcription in progress comes first.
                while running { try? await Task.sleep(for: .seconds(5)) }
                guard let meeting = store.meeting(m.id), meeting.status == .ready,
                      let transcript = store.transcript(for: m.id) else { continue }
                do {
                    try await buildPlayback(meeting, transcript: transcript, tracks: try await storedTracks(meeting))
                } catch {
                    log.error("Playback file for \(meeting.title) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// You for the mic track; saved voiceprints, then the calendar, for everyone else.
    private func nameSpeakers(built: TranscriptBuilder.Output, system: TranscriptionEngine.Diarization,
                              mic: TranscriptionEngine.Diarization?, meeting: Meeting) -> [Speaker] {
        var speakers: [Speaker] = []
        let used = Set(built.utterances.map(\.speakerID))
        if used.contains(TranscriptBuilder.meID) {
            speakers.append(Speaker(id: TranscriptBuilder.meID, name: settings.userName, isMe: true))
        }

        var embeddings: [String: [Float]] = [:]
        for (key, sid) in built.speakerMap {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let source = parts[0] == "mic" ? mic : system
            if let e = source?.speakers.first(where: { $0.id == parts[1] })?.embedding { embeddings[sid] = e }
        }

        let others = built.speakerMap.values.sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
        let matches = voiceprints.identify(speakers: others.compactMap { sid in embeddings[sid].map { (sid, $0) } },
                                           threshold: Float(settings.voiceMatchThreshold))
        let unmatched = others.filter { matches[$0] == nil }
        // A one-on-one on the calendar with a single unknown voice: that voice is the other attendee.
        let calendarName: String? = (meeting.attendees.count == 1 && unmatched.count == 1
                                     && !matches.values.contains(meeting.attendees[0])) ? meeting.attendees[0] : nil
        var counter = 1
        for sid in others {
            if let name = matches[sid] {
                speakers.append(Speaker(id: sid, name: name, embedding: embeddings[sid], autoIdentified: true))
            } else if let calendarName, unmatched.first == sid {
                speakers.append(Speaker(id: sid, name: calendarName, embedding: embeddings[sid], autoIdentified: true))
            } else {
                speakers.append(Speaker(id: sid, name: "Speaker \(counter)", embedding: embeddings[sid]))
                counter += 1
            }
        }
        return speakers
    }

    // MARK: - Summary / export (also used from the UI)

    func summarize(_ id: UUID) async {
        guard let meeting = store.meeting(id), let transcript = store.transcript(for: id) else { return }
        // Not set up yet: the Summary tab offers ChatGPT sign-in or a Claude key instead of an error.
        guard AIConnection.isReady else { return }
        do {
            let progress: @Sendable (String) -> Void = { text in
                Task { @MainActor [weak self] in self?.setProgress(id, text) }
            }
            let ai = try await AIConnection.current()
            func write() async throws -> String {
                try await Summarizer.summarize(meeting: meeting, transcript: transcript, using: ai, progress: progress)
            }
            let markdown: String
            do {
                markdown = try await write()
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
                // Usually the Mac slept mid-summary; the connection is back once it wakes, so try once more.
                try await Task.sleep(for: .seconds(5))
                markdown = try await write()
            }
            store.saveSummary(MeetingSummary(markdown: markdown, model: ai.modelName, createdAt: Date(), app: ai.app), for: id)
            store.update(id) { $0.statusDetail = nil }
        } catch {
            log.error("Summary failed: \(error.localizedDescription)")
            store.update(id) { $0.statusDetail = "Summary skipped: \(error.localizedDescription)" }
        }
    }

    func exportIfEnabled(_ id: UUID) {
        guard settings.autoExportMarkdown, let meeting = store.meeting(id), let transcript = store.transcript(for: id) else { return }
        Exporter.autoExport(meeting: meeting, transcript: transcript, summary: store.summary(for: id), folder: settings.exportFolder)
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        switch self {
        case .some(let value): return try await transform(value)
        case .none: return nil
        }
    }
}
