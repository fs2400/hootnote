import SwiftUI

struct MainView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    private var search: String { state.searchQuery }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 360)
        } detail: {
            detail
                .background(Theme.ground)
        }
        .searchable(text: $state.searchQuery, placement: .toolbar,
                    prompt: state.selectedMeetingID == nil ? "Search meetings and dictations" : "Find in this meeting")
        .tint(Theme.ink)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ListeningStatus()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if state.isRecording {
                    Button {
                        state.stopRecording(.manual(from: "the toolbar"))
                    } label: {
                        Label("Stop recording", systemImage: "stop.circle.fill")
                    }
                    .foregroundStyle(Theme.signal)
                    .help("Stop recording and transcribe")
                } else {
                    Button {
                        state.startManualRecording()
                    } label: {
                        Label("Record in person", systemImage: "record.circle")
                    }
                    .help("Start recording an in-person meeting (⇧⌘R)")
                }
                Button {
                    state.chooseFilesToImport()
                } label: {
                    Label("Upload audio", systemImage: "waveform.badge.plus")
                }
                .help("Transcribe an audio or video file")
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .alert("Hootnote", isPresented: Binding(get: { state.lastError != nil }, set: { if !$0 { state.lastError = nil } })) {
            Button("OK") { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
        .onAppear { state.openMainWindow = { openWindow(id: "main") } }
    }

    @ViewBuilder private var detail: some View {
        if !settings.hasCompletedOnboarding {
            OnboardingView()
        } else {
            switch state.route {
            case .home:
                if search.isEmpty { HomeView() } else { SearchResultsView(query: search) }
            case .meetings:
                MeetingsView(query: search)
            case .dictations:
                DictationsView(query: search)
            case .meeting(let id):
                if store.meeting(id) != nil {
                    MeetingDetailView(meetingID: id).id(id)
                } else {
                    HomeView()
                }
            }
        }
    }
}

/// "Listening for calls" / "Recording Teams call" in the toolbar.
private struct ListeningStatus: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            if let rec = state.recording {
                Circle().fill(Theme.signal).frame(width: 7, height: 7)
                Text("Recording \(rec.app.name)").foregroundStyle(Theme.signal)
            } else {
                Circle().fill(settings.detectionEnabled ? Theme.ready : Theme.inkTertiary).frame(width: 7, height: 7)
                Text(settings.detectionEnabled ? "Listening for calls" : "Call detection off")
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: MeetingStore
    @State private var pendingDelete: Meeting?

    var body: some View {
        List(selection: Binding<AppState.Route?>(get: { state.route }, set: { if let r = $0 { state.route = r } })) {
            Label("Home", systemImage: "house").tag(AppState.Route.home)
            Label("Meetings", systemImage: "list.bullet.rectangle").tag(AppState.Route.meetings)
            Label("Dictations", systemImage: "mic").tag(AppState.Route.dictations)

            ForEach(MeetingGroups.byDay(Array(store.meetings.prefix(60))), id: \.day) { group in
                Section(MeetingGroups.title(for: group.day)) {
                    ForEach(group.items) { m in
                        HStack(spacing: 8) {
                            Text(m.startedAt.timetableTime)
                                .font(.body.monospacedDigit().weight(.semibold))
                                .foregroundStyle(m.status == .recording ? Theme.signal : Theme.ink)
                                .frame(width: 64, alignment: .leading)
                            Text(m.title).lineLimit(1)
                        }
                        .tag(AppState.Route.meeting(m.id))
                        .contextMenu { MeetingContextMenu(meeting: m, pendingDelete: $pendingDelete) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if let id = state.selectedMeetingID, let m = store.meeting(id) { pendingDelete = m }
        }
        .deleteConfirmation($pendingDelete)
    }
}

/// Right-click actions shared by the sidebar, Meetings and Home.
struct MeetingContextMenu: View {
    let meeting: Meeting
    @Binding var pendingDelete: Meeting?
    @EnvironmentObject var state: AppState

    var body: some View {
        Button("Open") { state.route = .meeting(meeting.id) }
        Button("Re-transcribe") { state.processor.enqueue(meeting.id) }
            .disabled(meeting.status == .recording || meeting.status == .processing)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = meeting }
    }
}

extension View {
    /// Asks before moving a meeting's recording, transcript and summary to the Trash.
    func deleteConfirmation(_ pending: Binding<Meeting?>) -> some View {
        modifier(DeleteConfirmation(pending: pending))
    }
}

private struct DeleteConfirmation: ViewModifier {
    @Binding var pending: Meeting?
    @EnvironmentObject var state: AppState

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete “\(pending?.title ?? "")”?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Recording and Transcript", role: .destructive) {
                if let m = pending { state.delete(meeting: m.id) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("The recording, transcript and summary move to the Trash. You can restore them from there until it's emptied.")
        }
    }
}

enum MeetingGroups {
    static func byDay(_ meetings: [Meeting]) -> [(day: Date, items: [Meeting])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: meetings) { cal.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.startedAt > $1.startedAt }) }
    }

    static func title(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}
