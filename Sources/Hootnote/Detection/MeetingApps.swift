import AppKit
import Foundation

/// A calling app we know how to recognize from the bundle IDs of its audio processes.
struct MeetingApp: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePrefixes: [String]
    /// Browsers use the mic for many things, so the call-end heuristics are stricter for them.
    let isBrowser: Bool
    /// Bundle ID of the main app, used to show its icon.
    let iconBundleID: String

    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: iconBundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum MeetingApps {
    static let all: [MeetingApp] = [
        MeetingApp(id: "zoom", name: "Zoom", bundlePrefixes: ["us.zoom."], isBrowser: false, iconBundleID: "us.zoom.xos"),
        MeetingApp(id: "teams", name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams"], isBrowser: false, iconBundleID: "com.microsoft.teams2"),
        MeetingApp(id: "webex", name: "Webex", bundlePrefixes: ["com.cisco.webex", "com.webex.", "Cisco-Systems.Spark"], isBrowser: false, iconBundleID: "Cisco-Systems.Spark"),
        MeetingApp(id: "slack", name: "Slack huddle", bundlePrefixes: ["com.tinyspeck.slackmacgap"], isBrowser: false, iconBundleID: "com.tinyspeck.slackmacgap"),
        MeetingApp(id: "facetime", name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"], isBrowser: false, iconBundleID: "com.apple.FaceTime"),
        MeetingApp(id: "discord", name: "Discord", bundlePrefixes: ["com.hnc.Discord"], isBrowser: false, iconBundleID: "com.hnc.Discord"),
        MeetingApp(id: "whatsapp", name: "WhatsApp", bundlePrefixes: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"], isBrowser: false, iconBundleID: "net.whatsapp.WhatsApp"),
        MeetingApp(id: "goto", name: "GoTo Meeting", bundlePrefixes: ["com.logmein.", "com.goto."], isBrowser: false, iconBundleID: "com.logmein.goto"),
        MeetingApp(id: "ringcentral", name: "RingCentral", bundlePrefixes: ["com.ringcentral."], isBrowser: false, iconBundleID: "com.ringcentral.glip"),
        MeetingApp(id: "chrome", name: "Google Chrome", bundlePrefixes: ["com.google.Chrome"], isBrowser: true, iconBundleID: "com.google.Chrome"),
        MeetingApp(id: "safari", name: "Safari", bundlePrefixes: ["com.apple.Safari", "com.apple.WebKit.GPU"], isBrowser: true, iconBundleID: "com.apple.Safari"),
        MeetingApp(id: "edge", name: "Microsoft Edge", bundlePrefixes: ["com.microsoft.edgemac"], isBrowser: true, iconBundleID: "com.microsoft.edgemac"),
        MeetingApp(id: "firefox", name: "Firefox", bundlePrefixes: ["org.mozilla.firefox"], isBrowser: true, iconBundleID: "org.mozilla.firefox"),
        MeetingApp(id: "arc", name: "Arc", bundlePrefixes: ["company.thebrowser."], isBrowser: true, iconBundleID: "company.thebrowser.Browser"),
        MeetingApp(id: "brave", name: "Brave", bundlePrefixes: ["com.brave.Browser"], isBrowser: true, iconBundleID: "com.brave.Browser"),
    ]

    static func match(bundleID: String) -> MeetingApp? {
        all.first { app in app.bundlePrefixes.contains { bundleID.hasPrefix($0) } }
    }

    static func app(id: String) -> MeetingApp? { all.first { $0.id == id } }

    /// Used for manual (in-person) recordings, which aren't tied to a calling app.
    static let manual = MeetingApp(id: "manual", name: "In person", bundlePrefixes: [], isBrowser: false, iconBundleID: "")
    /// Used for transcribed audio and video files.
    static let upload = MeetingApp(id: "import", name: "Uploaded file", bundlePrefixes: [], isBrowser: false, iconBundleID: "")

    /// Display name for any meeting source, including manual and uploaded ones.
    static func name(for appID: String?) -> String {
        if appID == manual.id { return manual.name }
        if appID == upload.id { return upload.name }
        return app(id: appID ?? "")?.name ?? "Call"
    }
}
