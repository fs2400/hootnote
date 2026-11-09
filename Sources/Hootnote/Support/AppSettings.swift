import Foundation
import SwiftUI

enum RecordMode: String, CaseIterable, Identifiable {
    case ask, automatic
    var id: String { rawValue }
    var label: String { self == .ask ? "Ask me first" : "Start recording automatically" }
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case whisperTurbo = "whisper-large-v3-turbo"
    case whisperLarge = "whisper-large-v3"
    case parakeet = "parakeet-v2"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .whisperTurbo: return "OpenAI Whisper Large-v3 Turbo (recommended)"
        case .whisperLarge: return "OpenAI Whisper Large-v3 (slower, 3.2 GB)"
        case .parakeet: return "NVIDIA Parakeet v2 (fastest, English only)"
        }
    }

    var shortName: String {
        switch self {
        case .whisperTurbo: return "Whisper Large-v3 Turbo"
        case .whisperLarge: return "Whisper Large-v3"
        case .parakeet: return "Parakeet v2"
        }
    }

    var detail: String {
        switch self {
        case .whisperTurbo: return "1.6 GB download. Near Large-v3 accuracy at several times the speed; 99 languages."
        case .whisperLarge: return "3.2 GB download. The full Large-v3 model; slowest, for difficult audio."
        case .parakeet: return "0.6 GB download. Very fast, English only, no custom vocabulary."
        }
    }

    /// WhisperKit model folder name on huggingface.co/argmaxinc/whisperkit-coreml.
    /// ("large-v3-v20240930" is OpenAI's Large-v3 Turbo; "_turbo" is Argmax's Mac-optimized build.)
    var whisperVariant: String? {
        switch self {
        case .whisperTurbo: return "large-v3-v20240930_turbo"
        case .whisperLarge: return "large-v3_turbo"
        case .parakeet: return nil
        }
    }

    var isWhisper: Bool { whisperVariant != nil }
}

enum TranscriptionLanguage {
    /// Whisper language codes offered in Settings ("auto" = detect).
    static let options: [(code: String, name: String)] = [
        ("en", "English"), ("auto", "Detect automatically"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("ja", "Japanese"),
        ("zh", "Chinese"), ("ko", "Korean"), ("hi", "Hindi"), ("ar", "Arabic"), ("ru", "Russian"),
    ]
}

enum DictationHotkey: String, CaseIterable, Identifiable {
    case fn, rightOption
    var id: String { rawValue }
    var label: String { self == .fn ? "fn (Globe) key" : "Right Option key" }
    var keyName: String { self == .fn ? "fn" : "Right ⌥" }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var userName: String { didSet { d.set(userName, forKey: "userName") } }
    @Published var detectionEnabled: Bool { didSet { d.set(detectionEnabled, forKey: "detectionEnabled") } }
    @Published var recordMode: RecordMode { didSet { d.set(recordMode.rawValue, forKey: "recordMode") } }
    /// App IDs (see MeetingApps) that trigger the prompt. Stored as a disabled list so new apps default to on.
    @Published var disabledApps: Set<String> { didSet { d.set(Array(disabledApps), forKey: "disabledApps") } }
    /// App IDs the user chose "Always record" for, regardless of recordMode.
    @Published var autoRecordApps: Set<String> { didSet { d.set(Array(autoRecordApps), forKey: "autoRecordApps") } }
    @Published var endGraceSeconds: Int { didSet { d.set(endGraceSeconds, forKey: "endGraceSeconds") } }
    @Published var transcriptionModel: TranscriptionModel { didSet { d.set(transcriptionModel.rawValue, forKey: "transcriptionModel") } }
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    /// Names, companies and jargon, passed to Whisper as a prompt so it spells them right.
    @Published var customVocabulary: String { didSet { d.set(customVocabulary, forKey: "customVocabulary") } }
    @Published var voiceMatchThreshold: Double { didSet { d.set(voiceMatchThreshold, forKey: "voiceMatchThreshold") } }
    @Published var autoExportMarkdown: Bool { didSet { d.set(autoExportMarkdown, forKey: "autoExportMarkdown") } }
    @Published var exportFolderPath: String { didSet { d.set(exportFolderPath, forKey: "exportFolderPath") } }
    @Published var summaryEnabled: Bool { didSet { d.set(summaryEnabled, forKey: "summaryEnabled") } }
    /// ChatGPT model slug for summaries and Ask; empty means the first one ChatGPT lists.
    @Published var chatGPTModel: String { didSet { d.set(chatGPTModel, forKey: "chatGPTModel") } }
    @Published var aiProvider: AIProvider { didSet { d.set(aiProvider.rawValue, forKey: "aiProvider") } }
    /// Claude model ID for summaries and Ask; empty means Claude Opus 5.5.
    @Published var claudeModel: String { didSet { d.set(claudeModel, forKey: "claudeModel") } }
    @Published var dictationEnabled: Bool { didSet { d.set(dictationEnabled, forKey: "dictationEnabled") } }
    @Published var dictationHotkey: DictationHotkey { didSet { d.set(dictationHotkey.rawValue, forKey: "dictationHotkey") } }
    @Published var useCalendar: Bool { didSet { d.set(useCalendar, forKey: "useCalendar") } }
    @Published var showFloatingIndicator: Bool { didSet { d.set(showFloatingIndicator, forKey: "showFloatingIndicator") } }
    @Published var hideDockIcon: Bool { didSet { d.set(hideDockIcon, forKey: "hideDockIcon") } }
    @Published var hasCompletedOnboarding: Bool { didSet { d.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    var exportFolder: URL { URL(fileURLWithPath: (exportFolderPath as NSString).expandingTildeInPath, isDirectory: true) }

    private init() {
        d.register(defaults: [
            "userName": "Me",
            "detectionEnabled": true,
            "recordMode": RecordMode.ask.rawValue,
            "endGraceSeconds": 15,
            "transcriptionModel": TranscriptionModel.whisperTurbo.rawValue,
            "language": "en",
            "customVocabulary": "",
            "voiceMatchThreshold": 0.55,
            "autoExportMarkdown": true,
            "exportFolderPath": AppPaths.defaultExportFolder.path,
            "summaryEnabled": true,
            "chatGPTModel": "",
            "aiProvider": AIProvider.chatgpt.rawValue,
            "claudeModel": "",
            "dictationEnabled": true,
            "dictationHotkey": DictationHotkey.fn.rawValue,
            "useCalendar": false,
            "showFloatingIndicator": true,
            "hideDockIcon": false,
            "hasCompletedOnboarding": false,
        ])
        userName = d.string(forKey: "userName") ?? "Me"
        detectionEnabled = d.bool(forKey: "detectionEnabled")
        recordMode = RecordMode(rawValue: d.string(forKey: "recordMode") ?? "") ?? .ask
        disabledApps = Set(d.stringArray(forKey: "disabledApps") ?? [])
        autoRecordApps = Set(d.stringArray(forKey: "autoRecordApps") ?? [])
        endGraceSeconds = d.integer(forKey: "endGraceSeconds")
        transcriptionModel = TranscriptionModel(rawValue: d.string(forKey: "transcriptionModel") ?? "") ?? .whisperTurbo
        language = d.string(forKey: "language") ?? "en"
        customVocabulary = d.string(forKey: "customVocabulary") ?? ""
        voiceMatchThreshold = d.double(forKey: "voiceMatchThreshold")
        autoExportMarkdown = d.bool(forKey: "autoExportMarkdown")
        exportFolderPath = d.string(forKey: "exportFolderPath") ?? AppPaths.defaultExportFolder.path
        summaryEnabled = d.bool(forKey: "summaryEnabled")
        chatGPTModel = d.string(forKey: "chatGPTModel") ?? ""
        aiProvider = AIProvider(rawValue: d.string(forKey: "aiProvider") ?? "") ?? .chatgpt
        claudeModel = d.string(forKey: "claudeModel") ?? ""
        dictationEnabled = d.bool(forKey: "dictationEnabled")
        dictationHotkey = DictationHotkey(rawValue: d.string(forKey: "dictationHotkey") ?? "") ?? .fn
        useCalendar = d.bool(forKey: "useCalendar")
        showFloatingIndicator = d.bool(forKey: "showFloatingIndicator")
        hideDockIcon = d.bool(forKey: "hideDockIcon")
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
    }

    func shouldAutoRecord(appID: String) -> Bool {
        recordMode == .automatic || autoRecordApps.contains(appID)
    }
}
