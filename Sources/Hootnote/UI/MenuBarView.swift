import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var processor: ProcessingQueue

    var body: some View {
        if let rec = state.recording {
            RecordingMenuBarLabel(session: rec)
        } else if let owl = MenuBarIcon.image {
            Image(nsImage: owl)
        } else {
            Image(systemName: processor.activeID != nil ? "waveform.badge.ellipsis" : "waveform")
        }
    }
}

/// The owl as a template image for the menu bar (falls back to an SF Symbol if missing).
enum MenuBarIcon {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarOwl", withExtension: "pdf") ?? Bundle.main.url(forResource: "MenuBarOwl", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }()
}

private struct RecordingMenuBarLabel: View {
    @ObservedObject var session: RecordingSession
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "record.circle.fill")
            Text(session.elapsed.clockString).monospacedDigit()
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var processor: ProcessingQueue
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
                .padding(.bottom, 12)
            Rectangle().fill(Theme.ruleStrong).frame(height: 2)
            if recent.isEmpty {
                Text("Calls you record appear here.")
                    .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(recent) { m in
                    Button {
                        openMain()
                        state.route = .meeting(m.id)
                    } label: {
                        VStack(spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(m.startedAt.timetableTime)
                                    .font(Theme.timeRow)
                                    .foregroundStyle(m.status == .recording ? Theme.signal : Theme.ink)
                                    .frame(width: 66, alignment: .leading)
                                Text(m.title).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer(minLength: 6)
                                MeetingStateLabel(meeting: m).font(.system(size: 11, weight: .medium)).labelStyle(.titleOnly)
                            }
                            .padding(.vertical, 7)
                            HairlineRule()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle("Detect calls automatically", isOn: Binding(get: { settings.detectionEnabled },
                                                               set: { state.setDetection($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .padding(.top, 12)
            HStack {
                Button("Open Hootnote") { openMain() }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
                    .accessibilityLabel("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Quit Hootnote")
                    .accessibilityLabel("Quit Hootnote")
            }
            .padding(.top, 10)
        }
        .padding(14)
        .frame(width: 330)
        .tint(Theme.ink)
        .onAppear { state.openMainWindow = { openWindow(id: "main") } }
    }

    @ViewBuilder private var statusSection: some View {
        if let rec = state.recording {
            RecordingStatus(session: rec)
        } else if let app = state.prompt {
            HStack(spacing: 10) {
                AppIcon(app: app, size: 22)
                Text("\(app.name) call detected").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Record") { state.acceptPrompt(always: false) }
                    .buttonStyle(PillButtonStyle(fill: Theme.signal, foreground: Theme.onSignal))
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(settings.detectionEnabled ? Theme.ready : Theme.inkTertiary).frame(width: 7, height: 7)
                        Text(settings.detectionEnabled ? "Listening for calls" : "Call detection is off")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(processingLine ?? "Hold \(settings.dictationHotkey.keyName) anywhere to dictate")
                        .font(Theme.caption).foregroundStyle(processingLine == nil ? Theme.inkSecondary : Theme.working)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    state.startManualRecording()
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Record an in-person meeting now")
            }
        }
    }

    private var processingLine: String? {
        guard let id = processor.activeID, let m = store.meeting(id) else { return nil }
        return "Transcribing \(m.title)"
    }

    private var recent: [Meeting] { Array(store.meetings.prefix(5)) }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct RecordingStatus: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var session: RecordingSession
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PulsingDot()
                Text("Recording \(session.app.name)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.signal)
                Spacer()
                Text(session.elapsed.clockString).font(Theme.timeRow).foregroundStyle(Theme.signal)
            }
            ForEach(session.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(Theme.caption).foregroundStyle(Theme.caution)
            }
            HStack {
                Button("Discard…", role: .destructive) { confirmDiscard = true }
                Spacer()
                Button {
                    state.stopRecording(.manual(from: "the menu bar window"))
                } label: {
                    Label("Stop and transcribe", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.signal)
            }
            .discardConfirmation($confirmDiscard)
        }
    }
}
