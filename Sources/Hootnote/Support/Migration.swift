import Foundation

/// One-time move from the app's earlier name (MeetingScribe) to Hootnote: recordings, voiceprints,
/// downloaded models and settings carry over.
enum Migration {
    private static let oldDomain = "com.local.MeetingScribe" as CFString
    private static let doneKey = "migratedFromMeetingScribe"

    static func run() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("MeetingScribe", isDirectory: true)
        let new = base.appendingPathComponent("Hootnote", isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            do { try fm.moveItem(at: old, to: new) } catch { log.error("Data migration failed: \(error.localizedDescription)") }
        }

        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        let keys = ["userName", "detectionEnabled", "recordMode", "disabledApps", "autoRecordApps", "endGraceSeconds",
                    "transcriptionModel", "language", "customVocabulary", "voiceMatchThreshold", "autoExportMarkdown",
                    "exportFolderPath", "summaryEnabled", "useCalendar", "showFloatingIndicator",
                    "hideDockIcon", "hasCompletedOnboarding"]
        for key in keys where d.object(forKey: key) == nil {
            if let value = CFPreferencesCopyAppValue(key as CFString, oldDomain) { d.set(value, forKey: key) }
        }
        // Downloaded Whisper model locations moved with the data folder.
        if let all = CFPreferencesCopyKeyList(oldDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            for key in all where key.hasPrefix("whisperModelFolder.") {
                if let path = CFPreferencesCopyAppValue(key as CFString, oldDomain) as? String {
                    d.set(path.replacingOccurrences(of: "/MeetingScribe/", with: "/Hootnote/"), forKey: key)
                }
            }
        }
        d.set(true, forKey: doneKey)
    }
}
