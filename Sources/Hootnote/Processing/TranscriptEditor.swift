import AppKit

/// Edits made from the transcript view: naming speakers (which teaches their voiceprint),
/// merging speakers, reassigning a paragraph, and fixing text. Every edit can be undone (⌘Z) and redone,
/// voiceprint learning included.
@MainActor
struct TranscriptEditor {
    let meetingID: UUID
    let state: AppState
    /// The window's undo manager.
    var undoManager: UndoManager?

    private var store: MeetingStore { state.store }

    /// Default labels ("Speaker 2") aren't worth remembering as voices.
    static func isPlaceholder(_ name: String) -> Bool {
        name.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    func rename(speaker speakerID: String, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var t = store.transcript(for: meetingID),
              let index = t.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        let speaker = t.speakers[index]
        let merging = t.speakers.contains { $0.id != speakerID && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        var voice: [VoiceChange] = []

        if let other = t.speakers.first(where: { $0.id != speakerID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            // Same name as someone else here: they're one person, so merge.
            for i in t.utterances.indices where t.utterances[i].speakerID == speakerID {
                t.utterances[i].speakerID = other.id
            }
            t.speakers.remove(at: index)
        } else {
            t.speakers[index].name = name
            t.speakers[index].autoIdentified = false
        }
        if !speaker.isMe, !Self.isPlaceholder(name), let embedding = speaker.embedding {
            if speaker.autoIdentified, speaker.name != name {
                voice.append(.unlearned(speaker.name, embedding))
            }
            voice.append(.learned(name, embedding))
        }
        apply(voice)
        commit(t, action: merging ? "Merge Speakers" : "Rename Speaker", voice: voice)
    }

    /// Marks a diarized speaker as you (in-person recordings, where everyone is on your mic).
    func markAsMe(speaker speakerID: String) {
        guard var t = store.transcript(for: meetingID),
              let index = t.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        if let me = t.speakers.first(where: { $0.isMe && $0.id != speakerID }) {
            for i in t.utterances.indices where t.utterances[i].speakerID == speakerID {
                t.utterances[i].speakerID = me.id
            }
            t.speakers.remove(at: index)
        } else {
            t.speakers[index].isMe = true
            t.speakers[index].name = state.settings.userName
            t.speakers[index].autoIdentified = false
        }
        commit(t, action: "Mark as Me")
    }

    /// Fixes a diarization mistake for one paragraph.
    func move(utterance utteranceID: UUID, to speakerID: String) {
        guard var t = store.transcript(for: meetingID),
              let i = t.utterances.firstIndex(where: { $0.id == utteranceID }) else { return }
        t.utterances[i].speakerID = speakerID
        commit(t, action: "Change Speaker")
    }

    func editText(utterance utteranceID: UUID, to text: String) {
        guard var t = store.transcript(for: meetingID),
              let i = t.utterances.firstIndex(where: { $0.id == utteranceID }) else { return }
        let u = t.utterances[i]
        let pieces = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !pieces.isEmpty else { return }
        // Words you kept keep their exact times; new or changed words are placed between them.
        let step = (u.end - u.start) / Double(pieces.count)
        let spread = pieces.enumerated().map { k, w in
            Word(text: w, start: u.start + Double(k) * step, end: u.start + Double(k + 1) * step)
        }
        t.utterances[i].text = pieces.joined(separator: " ")
        t.utterances[i].words = WordTiming.align(spread, to: u.words).words
        commit(t, action: "Edit Text")
    }

    func deleteUtterance(_ utteranceID: UUID) {
        guard var t = store.transcript(for: meetingID) else { return }
        t.utterances.removeAll { $0.id == utteranceID }
        commit(t, action: "Delete Paragraph")
    }

    // MARK: - Saving, undo and redo

    /// A voiceprint change an edit made, so undo can take it back.
    enum VoiceChange {
        case learned(String, [Float])
        case unlearned(String, [Float])

        var inverse: VoiceChange {
            switch self {
            case let .learned(name, e): return .unlearned(name, e)
            case let .unlearned(name, e): return .learned(name, e)
            }
        }
    }

    private func apply(_ changes: [VoiceChange]) {
        for change in changes {
            switch change {
            case let .learned(name, e): state.voiceprints.learn(name: name, embedding: e)
            case let .unlearned(name, e): state.voiceprints.unlearn(name: name, embedding: e)
            }
        }
    }

    /// Saves an edit and registers its undo.
    private func commit(_ edited: Transcript, action: String, voice: [VoiceChange] = []) {
        guard let before = store.transcript(for: meetingID) else { return }
        let after = save(edited)
        registerUndo(action, restore: before, voice: voice.reversed().map(\.inverse), redo: after, redoVoice: voice)
    }

    /// Undo puts `restore` back (and reverses the voice changes); doing so registers the matching redo.
    private func registerUndo(_ action: String, restore: Transcript, voice: [VoiceChange],
                              redo: Transcript, redoVoice: [VoiceChange]) {
        guard let undoManager else { return }
        let target = UndoTarget.transcript(meetingID, in: undoManager)
        let editor = self
        undoManager.registerUndo(withTarget: target) { target in
            MainActor.assumeIsolated {
                // Clean Up, Re-transcribe and joins clear these steps when they save; this is the backstop.
                guard let current = editor.store.transcript(for: editor.meetingID),
                      current.utterances == redo.utterances, current.speakers == redo.speakers else {
                    NSSound.beep()
                    editor.state.announce("That edit can't be undone: the transcript was rebuilt since.")
                    editor.undoManager?.removeAllActions(withTarget: target)
                    return
                }
                // Undo shows what it changes: open the meeting if you're looking at another one.
                let redoing = editor.undoManager?.isRedoing == true
                if editor.state.selectedMeetingID != editor.meetingID { editor.state.route = .meeting(editor.meetingID) }
                editor.state.announce("\(redoing ? "Redid" : "Undid") \(action.lowercased()) in \(editor.store.meeting(editor.meetingID)?.title ?? "the meeting")")
                editor.apply(voice)
                let restored = editor.save(restore)
                editor.registerUndo(action, restore: redo, voice: redoVoice, redo: restored, redoVoice: voice)
            }
        }
        undoManager.setActionName(action)
    }

    @discardableResult
    private func save(_ t: Transcript) -> Transcript {
        var t = t
        // Drop speakers who no longer say anything.
        let used = Set(t.utterances.map(\.speakerID))
        t.speakers.removeAll { !used.contains($0.id) }
        store.saveTranscript(t, for: meetingID)
        state.processor.exportIfEnabled(meetingID)
        return t
    }
}

/// Undo targets per meeting (its transcript edits, and its title), so a meeting's steps can be dropped from
/// the undo stack together: when Clean Up, Re-transcribe, Restore or a join rebuild the transcript, the
/// Edit menu stops offering edits that no longer apply; when a meeting is deleted, all of its steps go.
@MainActor
final class UndoTarget {
    private static var transcripts: [UUID: UndoTarget] = [:]
    private static var titles: [UUID: UndoTarget] = [:]
    private static let managers = NSHashTable<UndoManager>.weakObjects()

    static func transcript(_ id: UUID, in manager: UndoManager) -> UndoTarget {
        managers.add(manager)
        return target(id, in: &transcripts)
    }

    static func title(_ id: UUID, in manager: UndoManager) -> UndoTarget {
        managers.add(manager)
        return target(id, in: &titles)
    }

    /// The transcript was rebuilt outside the editor.
    static func transcriptReplaced(_ id: UUID) {
        guard let t = transcripts[id] else { return }
        for m in managers.allObjects { m.removeAllActions(withTarget: t) }
    }

    static func meetingDeleted(_ id: UUID) {
        transcriptReplaced(id)
        guard let t = titles[id] else { return }
        for m in managers.allObjects { m.removeAllActions(withTarget: t) }
    }

    private static func target(_ id: UUID, in table: inout [UUID: UndoTarget]) -> UndoTarget {
        if let t = table[id] { return t }
        let t = UndoTarget()
        table[id] = t
        return t
    }
}
