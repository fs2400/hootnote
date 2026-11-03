import AppKit
import Foundation

/// All meetings on disk. Each meeting lives in its own folder:
/// meeting.json, transcript.json, summary.json, mic.(caf|m4a), system.(caf|m4a)
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    /// Bumped whenever a transcript or summary on disk changes, so open views reload.
    @Published private(set) var contentVersion: [UUID: Int] = [:]

    private var transcriptCache: [UUID: Transcript] = [:]
    private var cacheOrder: [UUID] = []
    private let transcriptCacheLimit = 12
    private var summaryCache: [UUID: MeetingSummary?] = [:]
    /// Folded (case- and accent-insensitive) transcript text per meeting, built off the main thread.
    private var searchIndex: [UUID: String] = [:]
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        load()
        buildSearchIndex()
    }

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func buildSearchIndex() {
        let ids = meetings.map(\.id)
        Task.detached(priority: .utility) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            var index: [UUID: String] = [:]
            var names: [UUID: [String]] = [:]
            for id in ids {
                let url = AppPaths.folder(for: id).appendingPathComponent("transcript.json")
                guard let data = try? Data(contentsOf: url), let t = try? d.decode(Transcript.self, from: data) else { continue }
                index[id] = MeetingStore.fold(t.plainText)
                names[id] = t.speakers.map(\.name)
            }
            await MainActor.run { [index, names] in
                self.searchIndex.merge(index) { _, new in new }
                for (id, n) in names where self.meeting(id)?.speakerNames == nil {
                    self.update(id) { $0.speakerNames = n }
                }
            }
        }
    }

    /// Snapshot tool only: show a meeting without saving it.
    func previewInsert(_ meeting: Meeting) {
        meetings.insert(meeting, at: 0)
    }

    /// Updates a meeting's status line in memory only (progress ticks shouldn't rewrite meeting.json).
    func setTransientDetail(_ id: UUID, _ detail: String?) {
        guard let i = meetings.firstIndex(where: { $0.id == id }), meetings[i].statusDetail != detail else { return }
        meetings[i].statusDetail = detail
    }

    func load() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: AppPaths.meetings, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Meeting] = []
        for dir in dirs {
            let file = dir.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: file),
                  let m = try? decoder.decode(Meeting.self, from: data) else { continue }
            loaded.append(m)
        }
        meetings = loaded.sorted { $0.startedAt > $1.startedAt }
    }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    /// The meeting that started most recently before this one.
    func meeting(before m: Meeting) -> Meeting? {
        meetings.first { $0.id != m.id && $0.startedAt < m.startedAt }
    }

    func upsert(_ meeting: Meeting) {
        try? FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
        if let data = try? encoder.encode(meeting) {
            try? data.write(to: meeting.folder.appendingPathComponent("meeting.json"), options: .atomic)
        }
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.append(meeting)
        }
        meetings.sort { $0.startedAt > $1.startedAt }
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard var m = meeting(id) else { return }
        change(&m)
        upsert(m)
    }

    // MARK: Transcript

    func transcript(for id: UUID) -> Transcript? {
        if let t = transcriptCache[id] { return t }
        let url = AppPaths.folder(for: id).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url), let t = try? decoder.decode(Transcript.self, from: data) else { return nil }
        remember(t, for: id)
        return t
    }

    /// Keeps the most recently used transcripts decoded; older ones are reloaded on demand.
    private func remember(_ t: Transcript, for id: UUID) {
        transcriptCache[id] = t
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > transcriptCacheLimit {
            transcriptCache[cacheOrder.removeFirst()] = nil
        }
    }

    func saveTranscript(_ transcript: Transcript, for id: UUID) {
        remember(transcript, for: id)
        searchIndex[id] = Self.fold(transcript.plainText)
        if let data = try? encoder.encode(transcript) {
            try? data.write(to: AppPaths.folder(for: id).appendingPathComponent("transcript.json"), options: .atomic)
        }
        let names = transcript.speakers.map(\.name)
        if meeting(id)?.speakerNames != names { update(id) { $0.speakerNames = names } }
        bump(id)
    }

    /// The transcript as it was before Clean Up, so it can be restored.
    func uncleaned(for id: UUID) -> Transcript? {
        let url = AppPaths.folder(for: id).appendingPathComponent("transcript.uncleaned.json")
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Transcript.self, from: $0) }
    }

    func saveUncleaned(_ transcript: Transcript, for id: UUID) {
        guard let data = try? encoder.encode(transcript) else { return }
        try? data.write(to: AppPaths.folder(for: id).appendingPathComponent("transcript.uncleaned.json"), options: .atomic)
    }

    func removeUncleaned(for id: UUID) {
        try? FileManager.default.removeItem(at: AppPaths.folder(for: id).appendingPathComponent("transcript.uncleaned.json"))
    }

    // MARK: Summary

    func summary(for id: UUID) -> MeetingSummary? {
        if let cached = summaryCache[id] { return cached }
        let url = AppPaths.folder(for: id).appendingPathComponent("summary.json")
        let summary = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(MeetingSummary.self, from: $0) }
        summaryCache[id] = summary
        return summary
    }

    func saveSummary(_ summary: MeetingSummary, for id: UUID) {
        summaryCache[id] = summary
        if let data = try? encoder.encode(summary) {
            try? data.write(to: AppPaths.folder(for: id).appendingPathComponent("summary.json"), options: .atomic)
        }
        update(id) { $0.hasSummary = true }
        bump(id)
    }

    /// Removes a summary that no longer matches the transcript (after two meetings are joined).
    func removeSummary(for id: UUID) {
        summaryCache[id] = .some(nil)
        try? FileManager.default.removeItem(at: AppPaths.folder(for: id).appendingPathComponent("summary.json"))
        update(id) { $0.hasSummary = false }
        bump(id)
    }

    private func bump(_ id: UUID) { contentVersion[id, default: 0] += 1 }

    // MARK: Delete (to Trash, so it can be recovered)

    func moveToTrash(_ id: UUID) {
        let folder = AppPaths.folder(for: id)
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } catch {
            log.error("Could not trash \(folder.path): \(error.localizedDescription)")
        }
        transcriptCache[id] = nil
        summaryCache[id] = nil
        searchIndex[id] = nil
        meetings.removeAll { $0.id == id }
    }

    // MARK: Search

    /// Matches title, source, speaker names and transcript text, ignoring case and accents.
    func search(_ query: String) -> [Meeting] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return meetings }
        return meetings.filter { m in
            if Self.fold(m.title).contains(q) || Self.fold(m.appName).contains(q) { return true }
            if (m.speakerNames ?? []).contains(where: { Self.fold($0).contains(q) }) { return true }
            return searchIndex[m.id]?.contains(q) ?? false
        }
    }

    /// Paragraphs in a meeting that mention `query`, for search results that jump to the moment.
    func moments(in id: UUID, matching query: String, limit: Int = 3) -> [(utterance: Utterance, speaker: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, searchIndex[id]?.contains(Self.fold(q)) ?? true, let t = transcript(for: id) else { return [] }
        return t.utterances.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .prefix(limit)
            .map { ($0, t.speakerName($0.speakerID)) }
    }

    var totalStorageBytes: Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: AppPaths.meetings, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
