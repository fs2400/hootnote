import Foundation

/// The services Hootnote can use for summaries and Ask.
enum AIProvider: String, CaseIterable, Identifiable {
    case chatgpt, claude
    var id: String { rawValue }
    var label: String { self == .chatgpt ? "ChatGPT" : "Claude" }
    /// Where to see how much of your ChatGPT plan, or your Claude API credits, Hootnote has used.
    var usageURL: URL {
        URL(string: self == .chatgpt ? "https://chatgpt.com/settings/usage" : "https://platform.claude.com/settings/billing")!
    }
    /// Signed in to ChatGPT, or a Claude key saved.
    @MainActor var isConnected: Bool {
        self == .chatgpt ? ChatGPTAccount.shared.isSignedIn : ClaudeAccount.shared.hasKey
    }
}

/// One model on one service, as the model menus list it.
struct AIModelChoice: Hashable, Identifiable {
    let provider: AIProvider
    let modelID: String
    let name: String
    var id: String { "\(provider.rawValue)/\(modelID)" }

    static func == (a: Self, b: Self) -> Bool { a.provider == b.provider && a.modelID == b.modelID }
    func hash(into hasher: inout Hasher) {
        hasher.combine(provider)
        hasher.combine(modelID)
    }
}

/// The models ChatGPT and Claude offer right now, and which one is the default.
@MainActor
enum AIModels {
    /// The connected services, the default one first.
    static var connected: [AIProvider] {
        let preferred = AppSettings.shared.aiProvider
        return ([preferred] + AIProvider.allCases.filter { $0 != preferred }).filter(\.isConnected)
    }

    /// Every model the service lists, in its order (Claude's newest first).
    static func choices(_ provider: AIProvider) -> [AIModelChoice] {
        switch provider {
        case .chatgpt:
            return ChatGPTAccount.shared.models.map { AIModelChoice(provider: .chatgpt, modelID: $0.slug, name: $0.displayName) }
        case .claude:
            return ClaudeAccount.shared.models.map { AIModelChoice(provider: .claude, modelID: $0.id, name: $0.displayName) }
        }
    }

    /// The menu's top level and its More Models submenu. Claude lists every model it still serves, so the
    /// top level keeps the newest of each family (Opus, Sonnet, Haiku first); ChatGPT's list is short already.
    static func menu(_ provider: AIProvider) -> (main: [AIModelChoice], more: [AIModelChoice]) {
        let all = choices(provider)
        guard provider == .claude else { return (all, []) }
        var seen = Set<String>()
        var main: [AIModelChoice] = [], more: [AIModelChoice] = []
        for choice in all {
            if seen.insert(family(choice.modelID)).inserted { main.append(choice) } else { more.append(choice) }
        }
        let order = ["opus", "sonnet", "haiku"]
        let ranked = main.enumerated().sorted { a, b in
            let ra = order.firstIndex(of: family(a.element.modelID)) ?? order.count
            let rb = order.firstIndex(of: family(b.element.modelID)) ?? order.count
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        return (ranked.map(\.element), more)
    }

    /// "opus" for claude-opus-5-5, "haiku" for claude-3-5-haiku-20241022.
    private static func family(_ id: String) -> String {
        id.split(separator: "-").dropFirst().first { $0.allSatisfy(\.isLetter) }.map(String.init) ?? id
    }

    /// The default model from Settings › AI, on a connected service; nil when neither is connected.
    /// A model the service no longer offers shows as the one Hootnote will use instead.
    static var defaultChoice: AIModelChoice? {
        let settings = AppSettings.shared
        guard let provider = connected.first else { return nil }
        switch provider {
        case .claude:
            if let m = ClaudeAccount.shared.resolve(settings.claudeModel) {
                return AIModelChoice(provider: .claude, modelID: m.id, name: m.displayName)
            }
            let id = settings.claudeModel.isEmpty ? ClaudeAccount.defaultModel : settings.claudeModel
            return AIModelChoice(provider: .claude, modelID: id, name: id == ClaudeAccount.defaultModel ? "Claude Opus 5.5" : id)
        case .chatgpt:
            if let m = ChatGPTAccount.shared.resolve(settings.chatGPTModel) {
                return AIModelChoice(provider: .chatgpt, modelID: m.slug, name: m.displayName)
            }
            let slug = settings.chatGPTModel
            return AIModelChoice(provider: .chatgpt, modelID: slug, name: slug.isEmpty ? "ChatGPT" : slug)
        }
    }

    /// Makes `choice` the default in Settings › AI.
    static func setDefault(_ choice: AIModelChoice) {
        let settings = AppSettings.shared
        settings.aiProvider = choice.provider
        switch choice.provider {
        case .claude: settings.claudeModel = choice.modelID
        case .chatgpt: settings.chatGPTModel = choice.modelID
        }
    }

    /// Fetches the model lists again when they're a few minutes old, so new models show up.
    static func refresh() async {
        async let claude: Void = ClaudeAccount.shared.refreshModels()
        async let chatGPT: Void = ChatGPTAccount.shared.refreshModels()
        _ = await (claude, chatGPT)
    }
}

/// One way to reach a service: the model, how to label what it writes, and how to ask it.
struct AIConnection {
    let modelName: String
    /// Saved as MeetingSummary.app ("ChatGPT" or "Claude").
    let app: String
    let respond: @MainActor (_ instructions: String, _ input: [ChatMessage], _ cache: Bool,
                             _ onText: ((String) -> Void)?) async throws -> String

    /// Whether ChatGPT or Claude is set up.
    @MainActor static var isReady: Bool { !AIModels.connected.isEmpty }

    /// The default model from Settings › AI.
    @MainActor static func current() async throws -> AIConnection { try await make(nil) }

    /// `choice`, or the default model when nil. A model the service no longer offers falls back to its default.
    @MainActor static func make(_ choice: AIModelChoice?) async throws -> AIConnection {
        guard let choice = choice ?? AIModels.defaultChoice else {
            throw ClaudeError.message("Connect ChatGPT or Claude in Settings › AI.")
        }
        switch choice.provider {
        case .chatgpt:
            let account = ChatGPTAccount.shared
            guard account.isSignedIn else { throw ChatGPTError.notSignedIn }
            let model = try await account.model(preferring: choice.modelID)
            return AIConnection(modelName: model.displayName, app: "ChatGPT") { instructions, input, _, onText in
                try await account.respond(model: model.slug, instructions: instructions, input: input, onText: onText)
            }
        case .claude:
            let account = ClaudeAccount.shared
            let model = try await account.model(preferring: choice.modelID)
            return AIConnection(modelName: model.displayName, app: "Claude") { instructions, input, cache, onText in
                try await account.respond(model: model.id, instructions: instructions, input: input, cache: cache, onText: onText)
            }
        }
    }
}
