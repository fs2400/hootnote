import AVFoundation
import AppKit
import EventKit
import Foundation
import ServiceManagement
import UserNotifications

// MARK: - Permissions

enum Permissions {
    enum Status { case granted, denied, notAsked }

    static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notAsked
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // System-audio capture ("Screen & System Audio Recording › System Audio Recording Only") has no
    // public status API. These TCC calls are what macOS itself uses; fine for a personal app.
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @convention(block) @escaping (Bool) -> Void) -> Void
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var systemAudio: Status {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return .notAsked }
        let preflight = unsafeBitCast(sym, to: PreflightFn.self)
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notAsked
        }
    }

    static func requestSystemAudio() async -> Bool {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { return false }
        let request = unsafeBitCast(sym, to: RequestFn.self)
        return await withCheckedContinuation { cont in
            request("kTCCServiceAudioCapture" as CFString, nil) { granted in cont.resume(returning: granted) }
        }
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Calendar (meeting titles and attendee names)

@MainActor
final class CalendarHelper {
    static let shared = CalendarHelper()
    private let store = EKEventStore()

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
    }

    /// Today's timed events that haven't started yet, earliest first.
    func upcomingToday(now: Date = Date()) -> [Event] {
        guard isAuthorized, let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate) }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The calendar event you're most likely in right now. `id` names this occurrence (a repeating
    /// event's occurrences share an event identifier, so the start time is part of it).
    func currentEvent(at date: Date = Date()) -> (id: String, title: String, attendees: [String], end: Date)? {
        guard isAuthorized else { return nil }
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-4 * 3600),
                                                 end: date.addingTimeInterval(2 * 3600), calendars: nil)
        let candidates = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.startDate <= date.addingTimeInterval(15 * 60) && $0.endDate >= date.addingTimeInterval(-5 * 60)
        }
        func looksLikeCall(_ e: EKEvent) -> Bool {
            let text = [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
            return ["zoom.us", "teams.microsoft", "meet.google", "webex", "whereby", "gotomeet"].contains { text.contains($0) }
        }
        let best = candidates.sorted {
            let a = (looksLikeCall($0) ? 0 : 1, abs($0.startDate.timeIntervalSince(date)))
            let b = (looksLikeCall($1) ? 0 : 1, abs($1.startDate.timeIntervalSince(date)))
            return a < b
        }.first
        guard let event = best else { return nil }
        let attendees = (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { p -> String? in
            if let name = p.name, !name.isEmpty, !name.contains("@") { return name }
            let email = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            guard let local = email.split(separator: "@").first else { return nil }
            return local.split(whereSeparator: { ".-_".contains($0) }).map { $0.capitalized }.joined(separator: " ")
        }
        let id = "\(event.eventIdentifier ?? event.title ?? "")@\(Int(event.startDate.timeIntervalSince1970))"
        return (id, event.title ?? "Meeting", attendees, event.endDate)
    }
}

// MARK: - Notifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onOpenMeeting: ((UUID) -> Void)?

    func setUp() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(title: String, body: String, meetingID: UUID? = nil) {
        // The command-line diagnostics run without an app bundle, where notifications aren't available.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let meetingID { content.userInfo = ["meetingID": meetingID.uuidString] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let idString = response.notification.request.content.userInfo["meetingID"] as? String
        Task { @MainActor in
            if let idString, let id = UUID(uuidString: idString) { self.onOpenMeeting?(id) }
        }
        completionHandler()
    }
}
