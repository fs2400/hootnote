import SwiftUI

enum TimetableColumns {
    static let line: CGFloat = 170
    static let length: CGFloat = 96
    static let state: CGFloat = 150
}

struct TimetableHeader: View {
    var firstColumn = "Time"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(firstColumn).frame(width: Theme.timeColumn, alignment: .leading)
                Text("Source").frame(width: TimetableColumns.line, alignment: .leading)
                Text("Meeting").frame(maxWidth: .infinity, alignment: .leading)
                Text("Length").frame(width: TimetableColumns.length, alignment: .leading)
                Text("State").frame(width: TimetableColumns.state, alignment: .leading)
            }
            .font(Theme.columnHead)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.bottom, 6)
            TimetableRule()
        }
        .accessibilityHidden(true)
    }
}

/// One meeting as a timetable row: time, line (app), title and speakers, length, state.
struct MeetingTimetableRow: View {
    let meeting: Meeting
    var showDay: Bool
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: MeetingStore
    @State private var hovering = false

    var body: some View {
        Button {
            state.route = .meeting(meeting.id)
        } label: {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        TimetableTime(date: meeting.startedAt, color: meeting.status == .recording ? Theme.signal : Theme.ink)
                        if showDay {
                            Text(meeting.startedAt.formatted(.dateTime.month(.abbreviated).day()))
                                .font(Theme.caption).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    .frame(width: Theme.timeColumn, alignment: .leading)
                    HStack(spacing: 7) {
                        LineDot(color: Theme.line(forApp: meeting.appID))
                        Text(MeetingApps.name(for: meeting.appID)).lineLimit(1)
                    }
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .frame(width: TimetableColumns.line, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title).font(Theme.bodyEmphasis).foregroundStyle(Theme.ink).lineLimit(2)
                        if let people = subtitle {
                            Text(people).font(Theme.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)
                    Group {
                        if meeting.status == .recording, let rec = state.recording, rec.id == meeting.id {
                            LiveElapsed(session: rec)
                        } else {
                            Text(meeting.duration.durationString)
                        }
                    }
                    .font(Theme.body.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: TimetableColumns.length, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        MeetingStateLabel(meeting: meeting).font(Theme.state)
                        if meeting.status == .processing {
                            StateProgress(detail: meeting.statusDetail)
                        }
                    }
                    .frame(width: TimetableColumns.state, alignment: .leading)
                }
                .padding(.vertical, 12)
                .background(hovering ? Theme.groundRaised : .clear)
                HairlineRule()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meeting.title), \(meeting.startedAt.timetableTime), \(MeetingApps.name(for: meeting.appID)), \(meeting.duration.durationString), \(stateWord)")
        .accessibilityHint("Opens the meeting")
        .accessibilityAddTraits(.isButton)
    }

    private var stateWord: String {
        switch meeting.status {
        case .recording: return "Recording"
        case .queued: return "Waiting"
        case .processing: return "Transcribing"
        case .failed: return "Failed"
        case .ready: return "Ready"
        }
    }

    private var subtitle: String? {
        if meeting.status == .failed { return meeting.statusDetail }
        guard let names = meeting.speakerNames, !names.isEmpty else { return nil }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown), \(names.count - 3) more" : shown
    }
}

/// The sentences in a meeting that match a search, each opening the meeting at that moment.
struct MomentRows: View {
    let meeting: Meeting
    let query: String
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: MeetingStore

    var body: some View {
        let moments = store.moments(in: meeting.id, matching: query)
        if !moments.isEmpty {
            VStack(spacing: 0) {
                ForEach(moments, id: \.utterance.id) { moment in
                    Button {
                        state.open(meeting: meeting.id, at: moment.utterance.start)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(moment.utterance.start.clockString)
                                .font(Theme.timeRow)
                                .foregroundStyle(Theme.inkSecondary)
                                .frame(width: Theme.timeColumn, alignment: .leading)
                            Text(moment.speaker)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .frame(width: TimetableColumns.line, alignment: .leading)
                            Text(SearchHighlight.apply(snippet(moment.utterance.text), query: query))
                                .font(Theme.body)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open at \(moment.utterance.start.clockString)")
                    .accessibilityLabel("\(moment.speaker) at \(moment.utterance.start.clockString): \(moment.utterance.text)")
                }
                HairlineRule()
            }
        }
    }

    /// Trims a long paragraph to the part around the match.
    private func snippet(_ text: String) -> String {
        guard text.count > 220, let r = text.range(of: query, options: .caseInsensitive) else { return text }
        let start = text.index(r.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}

enum SearchHighlight {
    /// Marks every occurrence of `query` with the amber search wash.
    static func apply(_ text: String, query: String) -> AttributedString {
        var a = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return a }
        var range = a.startIndex..<a.endIndex
        while let found = a[range].range(of: q, options: .caseInsensitive) {
            a[found].backgroundColor = Theme.searchWash
            range = found.upperBound..<a.endIndex
        }
        return a
    }
}

/// Live progress under "Transcribing", read from the processing step's "… 40%" detail.
private struct StateProgress: View {
    let detail: String?

    var body: some View {
        let percent = detail.flatMap { d -> Double? in
            guard let r = d.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
            return Double(d[r].dropLast()).map { $0 / 100 }
        }
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rule)
                Capsule().fill(Theme.working).frame(width: 120 * (percent ?? 0.08))
            }
            .frame(width: 120, height: 3)
            if let detail {
                Text(stage(detail))
                    .font(Theme.caption).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail ?? "Transcribing")
    }

    /// "Transcribing the other participants… 62%" → "Call audio · 62%".
    private func stage(_ detail: String) -> String {
        let percent = detail.range(of: #"\d+%"#, options: .regularExpression).map { String(detail[$0]) }
        let step: String
        switch detail {
        case let d where d.contains("microphone"): step = "Your microphone"
        case let d where d.contains("other participants"): step = "Call audio"
        case let d where d.contains("who said what"): step = "Identifying speakers"
        case let d where d.contains("echo"): step = "Removing echo"
        case let d where d.contains("summar") || d.contains("Summar"): step = "Writing summary"
        case let d where d.contains("model"): step = "Loading models"
        case let d where d.contains("Saving") || d.contains("Preparing"): step = "Preparing audio"
        default: step = detail.replacingOccurrences(of: "…", with: "")
        }
        return percent.map { "\(step) · \($0)" } ?? step
    }
}

private struct LiveElapsed: View {
    @ObservedObject var session: RecordingSession
    var body: some View { Text(session.elapsed.clockString).foregroundStyle(Theme.signal) }
}

/// Every meeting, day by day.
struct MeetingsView: View {
    let query: String
    @EnvironmentObject var store: MeetingStore
    @State private var pendingDelete: Meeting?

    var body: some View {
        let meetings = store.search(query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if meetings.isEmpty {
                    SectionHeading(title: query.isEmpty ? "Meetings" : "No matches", detail: nil)
                    Text(query.isEmpty
                         ? "Recorded calls, in-person meetings and uploaded files appear here."
                         : "Nothing matches “\(query)” in titles, speaker names or transcripts.")
                        .font(Theme.body).foregroundStyle(Theme.inkSecondary)
                } else {
                    ForEach(MeetingGroups.byDay(meetings), id: \.day) { group in
                        SectionHeading(title: MeetingGroups.title(for: group.day),
                                       detail: "\(group.items.count) \(group.items.count == 1 ? "meeting" : "meetings") · \(group.items.reduce(0) { $0 + $1.duration }.durationString)")
                        TimetableHeader()
                        ForEach(group.items) { m in
                            MeetingTimetableRow(meeting: m, showDay: false)
                                .contextMenu { MeetingContextMenu(meeting: m, pendingDelete: $pendingDelete) }
                            MomentRows(meeting: m, query: query)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 40)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .deleteConfirmation($pendingDelete)
        .navigationTitle("Meetings")
    }
}

/// Search from Home: meetings and dictations together.
struct SearchResultsView: View {
    let query: String
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var dictations: DictationStore
    @State private var pendingDelete: Meeting?

    var body: some View {
        let meetings = store.search(query)
        let found = dictations.search(query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Meetings", detail: "\(meetings.count) matching “\(query)”")
                if !meetings.isEmpty {
                    TimetableHeader()
                    ForEach(meetings) { m in
                        MeetingTimetableRow(meeting: m, showDay: true)
                            .contextMenu { MeetingContextMenu(meeting: m, pendingDelete: $pendingDelete) }
                        MomentRows(meeting: m, query: query)
                    }
                }
                SectionHeading(title: "Dictations", detail: "\(found.count) matching")
                if !found.isEmpty {
                    TimetableRule()
                    ForEach(found) { DictationRow(dictation: $0, compact: false) }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 40)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .deleteConfirmation($pendingDelete)
    }
}
