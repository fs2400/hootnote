import ApplicationServices
import EventKit
import SwiftUI

/// Home: three actions on the timetable rule, then today's calls as a timetable cut by the
/// red now-line, then earlier meetings and recent dictations.
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var dictations: DictationStore
    @State private var pendingDelete: Meeting?
    @State private var dropTargeted = false
    @State private var upcoming: [CalendarHelper.Event] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                actions
                today
                if !earlier.isEmpty {
                    SectionHeading(title: "Earlier", detail: nil)
                    TimetableHeader()
                    ForEach(earlier) { m in
                        MeetingTimetableRow(meeting: m, showDay: true)
                            .contextMenu { MeetingContextMenu(meeting: m, pendingDelete: $pendingDelete) }
                    }
                }
                recentDictations
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { if dropTargeted { DropOverlay() } }
        .dropDestination(for: URL.self) { urls, _ in
            state.importFiles(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .deleteConfirmation($pendingDelete)
        .navigationTitle("Home")
        .task {
            // Calendar reads stay out of the drawing code: once now, then every minute.
            while !Task.isCancelled {
                refreshUpcoming()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in refreshUpcoming() }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 0) {
            TimetableRule()
            HStack(alignment: .top, spacing: 0) {
                ActionCell(symbol: state.isRecording ? "record.circle.fill" : "record.circle",
                           tint: state.isRecording ? Theme.signal : Theme.ink, title: "Record in person",
                           detail: "Everyone in the room, separated by voice.") {
                    state.startManualRecording()
                }
                .disabled(state.isRecording)
                Rectangle().fill(Theme.rule).frame(width: 1)
                ActionCell(symbol: "waveform.badge.plus", tint: Theme.ink, title: "Upload audio",
                           detail: "Choose or drop a recording or video to transcribe it.") {
                    state.chooseFilesToImport()
                }
                Rectangle().fill(Theme.rule).frame(width: 1)
                DictationCell()
            }
            HairlineRule()
        }
    }

    // MARK: Today

    private var todaysMeetings: [Meeting] {
        store.meetings.filter { Calendar.current.isDateInToday($0.startedAt) }
    }

    private var earlier: [Meeting] {
        Array(store.meetings.filter { !Calendar.current.isDateInToday($0.startedAt) }.prefix(5))
    }

    private func refreshUpcoming() {
        upcoming = settings.useCalendar ? CalendarHelper.shared.upcomingToday() : []
    }

    @ViewBuilder private var today: some View {
        let meetings = todaysMeetings
        let total = meetings.reduce(0) { $0 + $1.duration }
        SectionHeading(title: "Today",
                       detail: [Date().formatted(.dateTime.weekday(.wide).month(.wide).day()),
                                meetings.isEmpty ? nil : "\(meetings.count) \(meetings.count == 1 ? "meeting" : "meetings")",
                                meetings.isEmpty ? nil : total.durationString].compactMap { $0 }.joined(separator: " · "))
        TimetableHeader()
        // A real timetable: morning to evening, cut by the now-line between what's done and what's next.
        if meetings.isEmpty {
            Text(settings.detectionEnabled
                 ? "No calls yet today. When a call starts in Zoom, Teams, Meet, Webex or Slack, Hootnote asks to record it."
                 : "No calls yet today. Call detection is off; record by hand with Record in person.")
                .font(Theme.body)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.vertical, 16)
        } else {
            ForEach(meetings.sorted { $0.startedAt < $1.startedAt }) { m in
                MeetingTimetableRow(meeting: m, showDay: false)
                    .contextMenu { MeetingContextMenu(meeting: m, pendingDelete: $pendingDelete) }
            }
        }
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 12) {
                NowLine(label: context.date.timetableTime)
                if calendarConnected {
                    Text(nextLine(now: context.date))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize()
                } else {
                    Button {
                        Task { await connectCalendar() }
                    } label: {
                        Label("Connect calendar to see upcoming calls", systemImage: "calendar")
                            .font(Theme.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
                    .help("Lets Hootnote show your next calls here and name meetings after calendar events")
                }
            }
            .padding(.vertical, 6)
        }
        ForEach(upcoming) { event in
            UpcomingRow(event: event)
        }
    }

    private var calendarConnected: Bool { settings.useCalendar && CalendarHelper.shared.isAuthorized }

    /// Asks for calendar access right here; if it was refused before, opens the privacy setting instead.
    private func connectCalendar() async {
        var granted = CalendarHelper.shared.isAuthorized
        if !granted { granted = await CalendarHelper.shared.requestAccess() }
        if granted {
            settings.useCalendar = true
            refreshUpcoming()
        } else {
            Permissions.openSettings("Privacy_Calendars")
        }
    }

    /// What the now-line divides: the next call on the calendar.
    private func nextLine(now: Date) -> String {
        guard calendarConnected else { return "" }
        guard let next = upcoming.first else { return "Nothing else on your calendar today." }
        let minutes = Int(next.start.timeIntervalSince(now) / 60)
        let wait = minutes < 60 ? "in \(max(minutes, 1)) min" : "in \(minutes / 60) hr \(minutes % 60) min"
        return "Next: \(next.title), \(wait)"
    }

    // MARK: Dictations

    @ViewBuilder private var recentDictations: some View {
        SectionHeading(title: "Recent dictations", detail: nil)
        if dictations.items.isEmpty {
            Text("Hold \(settings.dictationHotkey.keyName) in any app and speak. When you let go, the text is typed where your cursor is and kept here.")
                .font(Theme.body)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.vertical, 12)
        } else {
            TimetableRule()
            ForEach(dictations.items.prefix(3)) { d in
                DictationRow(dictation: d, compact: true)
            }
        }
    }
}

// MARK: - Pieces

struct SectionHeading: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(Theme.title).foregroundStyle(Theme.ink)
            if let detail { Text(detail).font(Theme.body).foregroundStyle(Theme.inkSecondary) }
        }
        .padding(.top, 34)
        .padding(.bottom, 10)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ActionCell: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.bodyEmphasis).foregroundStyle(Theme.ink)
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.groundRaised : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

/// The dictation action: how to use it, or what's missing.
private struct DictationCell: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var granted = AccessibilityWatcher.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: settings.dictationHotkey == .fn ? "fn" : "option")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Dictation").font(Theme.bodyEmphasis).foregroundStyle(Theme.ink)
                if !settings.dictationEnabled {
                    Text("Off. Turn it on in Settings › Dictation.").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                } else if !granted.trusted {
                    Text("Needs Accessibility access to hear the key and paste.").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    Button("Allow access…") { state.dictation.requestAccessibility() }
                        .controlSize(.small)
                        .padding(.top, 2)
                } else {
                    Text("Hold \(settings.dictationHotkey.keyName) anywhere and speak; let go to paste. Tap it for hands-free.")
                        .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Theme.ground.opacity(0.92)
            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.plus").font(.system(size: 34, weight: .medium))
                Text("Drop to transcribe").font(Theme.section)
                Text("Audio or video. Everyone in it is separated by voice.").font(Theme.body).foregroundStyle(Theme.inkSecondary)
            }
            .foregroundStyle(Theme.ink)
        }
        .overlay(Rectangle().strokeBorder(Theme.ink, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(12))
        .allowsHitTesting(false)
    }
}

private struct UpcomingRow: View {
    let event: CalendarHelper.Event

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                TimetableTime(date: event.start, color: Theme.inkTertiary)
                    .frame(width: Theme.timeColumn, alignment: .leading)
                HStack(spacing: 7) { LineDot(color: Theme.rule); Text("Calendar") }
                    .font(Theme.caption).foregroundStyle(Theme.inkTertiary)
                    .frame(width: TimetableColumns.line, alignment: .leading)
                Text(event.title).font(Theme.bodyEmphasis).foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(event.end.timeIntervalSince(event.start).durationString).font(Theme.body).foregroundStyle(Theme.inkTertiary)
                    .frame(width: TimetableColumns.length, alignment: .leading)
                Text("Upcoming").font(Theme.bodyEmphasis).foregroundStyle(Theme.inkTertiary)
                    .frame(width: TimetableColumns.state, alignment: .leading)
            }
            .padding(.vertical, 12)
            HairlineRule()
        }
    }
}

@MainActor
final class AccessibilityWatcher: ObservableObject {
    static let shared = AccessibilityWatcher()
    @Published private(set) var trusted = AXIsProcessTrusted()
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = AXIsProcessTrusted()
                if self?.trusted != now { self?.trusted = now }
            }
        }
    }
}
