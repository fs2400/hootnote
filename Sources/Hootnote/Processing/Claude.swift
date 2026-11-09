import Foundation

/// Claude through the Claude API, with an API key from the Claude Console. On Claude Max, Ultra and
/// Team plans, the plan's monthly API credits pay for it. The key is kept in the Keychain.
@MainActor
final class ClaudeAccount: ObservableObject {
    static let shared = ClaudeAccount()

    struct Model: Identifiable, Hashable {
        let id: String
        let displayName: String
        /// The most output the model can write in one answer.
        var maxTokens: Int?
        var created: Date?
    }

    static let defaultModel = "claude-opus-5-5"
    static let keysURL = URL(string: "https://platform.claude.com/settings/keys")!

    @Published private(set) var hasKey: Bool
    @Published private(set) var models: [Model] = []

    private static let keychain = KeychainItem(service: "com.local.Hootnote.claude", account: "api-key")
    private static let apiBase = URL(string: "https://api.anthropic.com/v1")!
    private static let apiVersion = "2026-10-21"
    /// Models whose safety classifiers can decline a request. With `fallbacks: "default"` the API
    /// re-runs a declined request on the model Anthropic recommends for that kind of decline.
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5",
                                                      "claude-fable-5-1", "claude-fable-5"]

    private var modelsLoadedAt: Date?
    private var refreshing = false

    private init() { hasKey = Self.keychain.read() != nil }

    /// Checks the key with Claude, then saves it.
    func connect(key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClaudeError.message("Paste your Claude API key.") }
        models = try await Self.fetchModels(key: key)
        modelsLoadedAt = Date()
        Self.keychain.write(Data(key.utf8))
        hasKey = true
    }

    func disconnect() {
        Self.keychain.delete()
        hasKey = false
        models = []
        modelsLoadedAt = nil
    }

    func loadModels() async throws {
        models = try await Self.fetchModels(key: try apiKey())
        modelsLoadedAt = Date()
    }

    /// Loads the list again when it's more than five minutes old; keeps the old list if Claude can't be reached.
    func refreshModels() async {
        guard hasKey, !refreshing, Date().timeIntervalSince(modelsLoadedAt ?? .distantPast) > 300 else { return }
        refreshing = true
        defer { refreshing = false }
        try? await loadModels()
    }

    /// The chosen model if the key can use it, otherwise Claude Opus 5.5, otherwise the newest listed.
    func model(preferring id: String) async throws -> Model {
        if models.isEmpty { try await loadModels() }
        guard let model = resolve(id) else { throw ClaudeError.message("This API key can't use any Claude models.") }
        return model
    }

    /// `model(preferring:)` from the list already loaded; nil before it loads.
    func resolve(_ id: String) -> Model? {
        let wanted = id.isEmpty ? Self.defaultModel : id
        return models.first(where: { $0.id == wanted }) ?? models.first(where: { $0.id == Self.defaultModel }) ?? models.first
    }

    /// Streams one answer from the Messages API. `input` is the conversation so far (user and assistant turns).
    /// `cache` keeps the input cached for a few minutes, so follow-up questions about the same transcript cost less.
    func respond(model: String, instructions: String, input: [ChatMessage], cache: Bool = false,
                 onText: ((String) -> Void)? = nil) async throws -> String {
        var req = Self.request("messages", key: try apiKey())
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Older models can write less than 64,000 tokens per answer and reject a larger limit.
        let limit = min(64_000, models.first(where: { $0.id == model })?.maxTokens ?? 64_000)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": limit,
            "stream": true,
            "system": instructions,
            "messages": input.map { ["role": $0.role, "content": $0.content] },
        ]
        if cache { body["cache_control"] = ["type": "ephemeral"] }
        if Self.fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw Self.error(status: http.statusCode, data: data)
        }
        // A fallback after a decline continues on the same stream, so all text deltas belong to the answer.
        var text = ""
        var stopReason: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let piece = delta?["text"] as? String {
                    text += piece
                    onText?(piece)
                }
            case "message_delta":
                if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            case "message_stop":
                if stopReason == "refusal" { throw ClaudeError.message("Claude declined to answer this one.") }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "error":
                throw Self.error(status: 0, data: data)
            default:
                continue
            }
        }
        throw ClaudeError.message("The connection to Claude ended before the answer was complete.")
    }

    // MARK: Helpers

    private func apiKey() throws -> String {
        guard let data = Self.keychain.read(), let key = String(data: data, encoding: .utf8) else {
            throw ClaudeError.message("Add your Claude API key in Settings › AI.")
        }
        return key
    }

    private static func request(_ path: String, key: String) -> URLRequest {
        var req = URLRequest(url: apiBase.appendingPathComponent(path))
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        return req
    }

    private static func fetchModels(key: String) async throws -> [Model] {
        var req = request("models", key: key)
        req.url = URL(string: apiBase.absoluteString + "/models?limit=100")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw error(status: http.statusCode, data: data) }
        let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        let models: [Model] = list.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return Model(id: id, displayName: m["display_name"] as? String ?? id, maxTokens: m["max_tokens"] as? Int,
                         created: (m["created_at"] as? String).flatMap(parseDate))
        }
        // Newest first; models without a date keep Claude's order, after the dated ones.
        return models.enumerated().sorted { a, b in
            switch (a.element.created, b.element.created) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    private static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }

    private static func error(status: Int, data: Data) -> ClaudeError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = json["error"] as? [String: Any] ?? [:]
        let type = error["type"] as? String ?? ""
        let message = error["message"] as? String ?? "Claude returned HTTP \(status)."
        if type == "authentication_error" || status == 401 {
            return .message("Claude didn't accept this API key. Check it in Settings › AI.")
        }
        if type == "billing_error" || message.localizedCaseInsensitiveContains("credit balance") {
            return .message("Your Claude API credits are used up. They refill each month, or you can add more in the Claude Console.")
        }
        if ["rate_limit_error", "overloaded_error", "api_error"].contains(type) || [429, 500, 529].contains(status) {
            return .message("Claude is busy right now. Try again in a minute.")
        }
        return .message("Claude: \(message)")
    }
}

enum ClaudeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
