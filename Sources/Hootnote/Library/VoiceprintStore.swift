import Foundation

/// Remembers what named people sound like, so a speaker you name once is
/// recognized automatically in later meetings.
@MainActor
final class VoiceprintStore: ObservableObject {
    @Published private(set) var voiceprints: [Voiceprint] = []
    private let maxEmbeddingsPerPerson = 12

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.voiceprints) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        voiceprints = (try? d.decode([Voiceprint].self, from: data)) ?? []
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(voiceprints) {
            try? data.write(to: AppPaths.voiceprints, options: .atomic)
        }
    }

    var names: [String] { voiceprints.map(\.name).sorted() }

    /// Adds a voice sample for `name` (creating the person if new).
    func learn(name: String, embedding: [Float]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !embedding.isEmpty else { return }
        if let i = voiceprints.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            voiceprints[i].embeddings.append(embedding)
            if voiceprints[i].embeddings.count > maxEmbeddingsPerPerson {
                voiceprints[i].embeddings.removeFirst(voiceprints[i].embeddings.count - maxEmbeddingsPerPerson)
            }
            voiceprints[i].updatedAt = Date()
        } else {
            voiceprints.append(Voiceprint(name: trimmed, embeddings: [embedding], updatedAt: Date()))
        }
        save()
    }

    /// Removes one meeting's sample (used when a speaker is renamed away from a wrong guess).
    func unlearn(name: String, embedding: [Float]) {
        guard let i = voiceprints.firstIndex(where: { $0.name == name }) else { return }
        voiceprints[i].embeddings.removeAll { Cosine.similarity($0, embedding) > 0.999 }
        if voiceprints[i].embeddings.isEmpty { voiceprints.remove(at: i) }
        save()
    }

    func delete(_ id: UUID) {
        voiceprints.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = voiceprints.firstIndex(where: { $0.id == id }) else { return }
        voiceprints[i].name = name
        save()
    }

    /// Best similarity of `embedding` to each known person.
    func scores(for embedding: [Float]) -> [(name: String, score: Float)] {
        voiceprints.map { vp in
            // Average of the top-3 sample similarities: robust to one odd recording.
            let sims = vp.embeddings.map { Cosine.similarity($0, embedding) }.sorted(by: >)
            let top = sims.prefix(3)
            let score = top.isEmpty ? 0 : top.reduce(0, +) / Float(top.count)
            return (vp.name, score)
        }
    }

    /// Assigns names to diarized speakers. Each name is used at most once per meeting.
    func identify(speakers: [(id: String, embedding: [Float])], threshold: Float) -> [String: String] {
        var pairs: [(speaker: String, name: String, score: Float)] = []
        for s in speakers {
            for (name, score) in scores(for: s.embedding) where score >= threshold {
                pairs.append((s.id, name, score))
            }
        }
        pairs.sort { $0.score > $1.score }
        var result: [String: String] = [:]
        var usedNames = Set<String>()
        for p in pairs where result[p.speaker] == nil && !usedNames.contains(p.name) {
            result[p.speaker] = p.name
            usedNames.insert(p.name)
        }
        return result
    }
}
