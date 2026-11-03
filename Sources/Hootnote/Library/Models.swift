import Foundation

enum MeetingStatus: String, Codable {
    case recording, queued, processing, ready, failed
}

struct Meeting: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var appName: String
    var appID: String?
    var startedAt: Date
    var endedAt: Date?
    var status: MeetingStatus
    var statusDetail: String?
    /// Names pulled from the calendar event, offered as speaker-name suggestions.
    var attendees: [String] = []
    var hasSummary: Bool = false
    /// What the echo canceller did, e.g. "echo cancelled (delay 52 ms, …)".
    var echoNote: String?
    /// Speaker names, kept here so lists don't have to load whole transcripts.
    var speakerNames: [String]?
    /// True when mic.m4a is the microphone as recorded (echo and all), so it can be processed again.
    /// Older meetings stored the echo-cancelled version there.
    var micIsRaw: Bool?
    /// Where each separately recorded part starts, in seconds, for a meeting joined from two recordings.
    /// The echo canceller treats each part on its own, since the speaker-to-mic delay can differ.
    var parts: [Double]?
    /// Why the recording stopped, e.g. "grace: …", "otherCall: …", "manual: …" (see AppState.StopCause).
    /// For diagnostics only; never shown in the main window.
    var stopReason: String?
    /// The earlier meeting you said "Not now" to joining this one with: the header doesn't offer that join again.
    var joinOfferDeclined: UUID?

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    var folder: URL { AppPaths.folder(for: id) }

    /// Raw capture files (crash-safe CAF) are compressed to m4a after processing.
    func audioURL(_ track: AudioTrack) -> URL? {
        let fm = FileManager.default
        for ext in ["m4a", "caf"] {
            let url = folder.appendingPathComponent("\(track.rawValue).\(ext)")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func rawCaptureURL(_ track: AudioTrack) -> URL {
        folder.appendingPathComponent("\(track.rawValue).caf")
    }

    /// Stereo master: channel 1 = you (echo-cancelled), channel 2 = the call.
    var stereoRecordingURL: URL { folder.appendingPathComponent("recording.m4a") }

    /// What the player plays: both tracks levelled and mixed, with speaker echo kept out.
    var playbackURL: URL { folder.appendingPathComponent("playback.m4a") }

    /// The original transcript, kept when Clean Up changes an older one.
    var uncleanedTranscriptURL: URL { folder.appendingPathComponent("transcript.uncleaned.json") }
}

enum AudioTrack: String, CaseIterable {
    /// Your microphone: everything here is you.
    case mic
    /// Everything the Mac plays (the other participants).
    case system
}

struct Speaker: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var isMe: Bool = false
    /// Voice embedding centroid for this speaker in this meeting (used to learn voices).
    var embedding: [Float]?
    /// True when the name came from a saved voiceprint match rather than from the user.
    var autoIdentified: Bool = false
}

struct Word: Codable, Hashable {
    var text: String
    var start: Double
    var end: Double
    /// Whisper's confidence in this word, 0...1 (nil for older transcripts and Parakeet).
    var p: Float?
}

struct Utterance: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var speakerID: String
    var start: Double
    var end: Double
    var text: String
    var words: [Word]
}

struct Transcript: Codable {
    var speakers: [Speaker]
    var utterances: [Utterance]
    var engine: String
    var createdAt: Date

    func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }
    func speakerName(_ id: String) -> String { speaker(id)?.name ?? "Unknown" }

    var plainText: String { utterances.map(\.text).joined(separator: " ") }

    /// "[00:12] Name: text" lines, used for summaries and plain-text export.
    func dialogue(includeTimestamps: Bool = true) -> String {
        utterances.map { u in
            let ts = includeTimestamps ? "[\(u.start.clockString)] " : ""
            return "\(ts)\(speakerName(u.speakerID)): \(u.text)"
        }.joined(separator: "\n")
    }
}

struct MeetingSummary: Codable {
    var markdown: String
    var model: String
    var createdAt: Date
}

struct Voiceprint: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Most recent embeddings for this person (capped), one per meeting they were named in.
    var embeddings: [[Float]]
    var updatedAt: Date
}
