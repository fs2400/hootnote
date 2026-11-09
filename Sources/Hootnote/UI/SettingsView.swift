import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }
            TranscriptionSettings().tabItem { Label("Transcription", systemImage: "text.bubble") }
            DictationSettings().tabItem { Label("Dictation", systemImage: "mic") }
            SpeakerSettings().tabItem { Label("Speakers", systemImage: "person.2.wave.2") }
            AISettings().tabItem { Label("AI", systemImage: "sparkle") }
            PermissionsSettings().tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 640, height: 500)
        .tint(Theme.ink)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: MeetingStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var storage = "…"

    var body: some View {
        Form {
            TextField("Your name", text: $settings.userName)
            Text("Used for your microphone track in every transcript.").font(.caption).foregroundStyle(.secondary)
            Toggle("Open at login (needed to catch calls)", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in LoginItem.set(on); launchAtLogin = LoginItem.isEnabled }
            Toggle("Hide Dock icon (keep only the menu bar icon)", isOn: $settings.hideDockIcon)
                .onChange(of: settings.hideDockIcon) { _, _ in state.applyDockIconSetting() }
            Section("Export") {
                Toggle("Save each transcript as Markdown automatically", isOn: $settings.autoExportMarkdown)
                HStack {
                    Text(settings.exportFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                    Button("Open") { NSWorkspace.shared.open(settings.exportFolder) }
                }
            }
            Section("Storage") {
                HStack {
                    Text("Recordings use \(storage)")
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.meetings) }
                }
            }
        }
        .formStyle(.grouped)
        .task { storage = ByteCountFormatter.string(fromByteCount: store.totalStorageBytes, countStyle: .file) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.exportFolder
        if panel.runModal() == .OK, let url = panel.url { settings.exportFolderPath = url.path }
    }
}

private struct RecordingSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: AppState
    @EnvironmentObject var detector: CallDetector
    @EnvironmentObject var store: MeetingStore

    var body: some View {
        Form {
            Toggle("Detect calls automatically", isOn: Binding(get: { settings.detectionEnabled },
                                                               set: { state.setDetection($0) }))
            Picker("When a call starts", selection: $settings.recordMode) {
                ForEach(RecordMode.allCases) { Text($0.label).tag($0) }
            }
            Stepper(value: $settings.endGraceSeconds, in: 5...120, step: 5) {
                Text("Stop recording \(settings.endGraceSeconds) s after the call app releases the microphone")
            }
            if settings.useCalendar {
                Text("While the call's calendar event is still on, Hootnote waits up to 3 minutes in case the call reconnects, without recording the room meanwhile.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Show the floating recording indicator", isOn: $settings.showFloatingIndicator)
            Toggle("Use the calendar for meeting titles and attendee names", isOn: $settings.useCalendar)
                .disabled(!CalendarHelper.shared.isAuthorized)
            Section("Apps to watch") {
                ForEach(MeetingApps.all) { app in
                    HStack {
                        AppIcon(app: app, size: 18)
                        Toggle(app.name + (app.isBrowser ? " (Meet, Teams or Zoom in the browser)" : ""), isOn: Binding(
                            get: { !settings.disabledApps.contains(app.id) },
                            set: { on in if on { settings.disabledApps.remove(app.id) } else { settings.disabledApps.insert(app.id) } }))
                        if settings.autoRecordApps.contains(app.id) {
                            Button("Always records") { settings.autoRecordApps.remove(app.id) }
                                .controlSize(.small)
                                .help("Click to ask first again")
                        }
                    }
                }
            }
            Section("Using the microphone right now") {
                if detector.micUsers.isEmpty {
                    Text("No other app").foregroundStyle(.secondary)
                } else {
                    ForEach(detector.micUsers, id: \.self) { id in
                        Text(appName(for: id)).font(.caption)
                    }
                }
            }
            Section("Why recent recordings stopped") {
                let stopped = Array(store.meetings.filter { $0.stopReason != nil }.prefix(5))
                if stopped.isEmpty {
                    Text("No recordings since Hootnote started keeping this").foregroundStyle(.secondary)
                } else {
                    ForEach(stopped) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(m.title) · ended \((m.endedAt ?? m.startedAt).formatted(date: .abbreviated, time: .standard))")
                                .font(.caption)
                            Text(m.stopReason ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// "com.microsoft.teams2" → "Microsoft Teams", falling back to the bundle ID.
private func appName(for bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

private struct TranscriptionSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var processor: ProcessingQueue

    var body: some View {
        Form {
            Picker("Speech model", selection: $settings.transcriptionModel) {
                ForEach(TranscriptionModel.allCases) { Text($0.label).tag($0) }
            }
            Text(settings.transcriptionModel.detail).font(.caption).foregroundStyle(.secondary)
            Picker("Language", selection: $settings.language) {
                ForEach(TranscriptionLanguage.options, id: \.code) { Text($0.name).tag($0.code) }
            }
            .disabled(settings.transcriptionModel == .parakeet)
            Section {
                TextField("Custom vocabulary", text: $settings.customVocabulary, axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(settings.transcriptionModel == .parakeet)
            } header: {
                Text("Names and jargon")
            } footer: {
                Text("Comma-separated, e.g. “Agency, EBITDA, Kubernetes, Priya Raman”. Whisper uses these to spell names and terms correctly.")
            }
            Section("Models") {
                if let status = processor.modelStatus {
                    HStack { ProgressView().controlSize(.small); Text(status) }
                } else if processor.modelsReady {
                    Label("Loaded and ready", systemImage: "checkmark.circle").foregroundStyle(Theme.ready)
                } else {
                    Button("Download and load models now") { processor.warmUp() }
                }
                Text("Speaker separation: pyannote Community-1. Voice activity: Silero. Echo cancellation: SpeexDSP. All run on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.transcriptionModel) { _, _ in processor.reloadModels() }
    }
}

private struct SpeakerSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var voiceprints: VoiceprintStore

    var body: some View {
        Form {
            Section {
                if voiceprints.voiceprints.isEmpty {
                    Text("No voices yet. Name a speaker in any transcript and Hootnote will recognize them next time.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(voiceprints.voiceprints) { vp in
                        HStack {
                            Text(vp.name)
                            Spacer()
                            Text("\(vp.embeddings.count) sample\(vp.embeddings.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) { voiceprints.delete(vp.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Forget this voice")
                                .accessibilityLabel("Forget \(vp.name)'s voice")
                        }
                    }
                }
            } header: {
                Text("Known voices")
            }
            Section {
                Slider(value: $settings.voiceMatchThreshold, in: 0.35...0.8, step: 0.05) {
                    Text("Match strictness")
                } minimumValueLabel: {
                    Text("Loose")
                } maximumValueLabel: {
                    Text("Strict")
                }
            } footer: {
                Text("Stricter means fewer wrong names but more “Speaker 2”s. Default 0.55.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DictationSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: AppState
    @EnvironmentObject var dictations: DictationStore
    @ObservedObject private var access = AccessibilityWatcher.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Toggle("Dictate anywhere with a key", isOn: $settings.dictationEnabled)
                .onChange(of: settings.dictationEnabled) { _, _ in state.dictation.activate() }
            Picker("Key", selection: $settings.dictationHotkey) {
                ForEach(DictationHotkey.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: settings.dictationHotkey) { _, _ in state.dictation.activate() }
            Text("Hold the key and speak; let go to paste where your cursor is. Tap it once for hands-free, then tap again to finish. Pressing it with another key (fn+arrow, fn+F5) is ignored.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Access") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                        Text("Lets Hootnote notice the key in other apps and paste the text for you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if access.trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ready)
                    } else {
                        Button("Allow…") { state.dictation.requestAccessibility() }
                    }
                }
                if settings.dictationHotkey == .fn {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set “Press \(Image(systemName: "globe")) key to” to Do Nothing")
                            Text("Otherwise macOS also opens the emoji picker or its own dictation when you press fn.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Keyboard Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            Section("History") {
                HStack {
                    Text("\(dictations.items.count) dictation\(dictations.items.count == 1 ? "" : "s") saved as text. Audio is never kept.")
                    Spacer()
                    Button("Clear…") { confirmClear = true }.disabled(dictations.items.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all dictations?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { dictations.deleteAll() }
        }
    }
}

private struct AISettings: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    @ObservedObject private var claude = ClaudeAccount.shared

    var body: some View {
        Form {
            Section("Summaries and Ask") {
                Picker("Use", selection: $settings.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Write a summary after each meeting", isOn: $settings.summaryEnabled)
                if settings.aiProvider == .chatgpt {
                    Picker("Model", selection: $settings.chatGPTModel) {
                        Text("Default").tag("")
                        ForEach(chatGPT.models) { Text($0.displayName).tag($0.slug) }
                        if !settings.chatGPTModel.isEmpty, !chatGPT.models.contains(where: { $0.slug == settings.chatGPTModel }) {
                            Text(settings.chatGPTModel).tag(settings.chatGPTModel)
                        }
                    }
                    .disabled(!chatGPT.isSignedIn)
                } else {
                    Picker("Model", selection: $settings.claudeModel) {
                        Text("Claude Opus 5.5").tag("")
                        ForEach(claude.models.filter { $0.id != ClaudeAccount.defaultModel }) { Text($0.displayName).tag($0.id) }
                        if !settings.claudeModel.isEmpty, !claude.models.contains(where: { $0.id == settings.claudeModel }) {
                            Text(settings.claudeModel).tag(settings.claudeModel)
                        }
                    }
                    .disabled(!claude.hasKey)
                }
            }
            Section("ChatGPT") {
                HStack {
                    Text(chatGPT.email.map { "Signed in as \($0)" } ?? "Not signed in")
                    Spacer()
                    if chatGPT.isSignedIn {
                        Button("Sign Out") { Task { await chatGPT.signOut() } }
                    }
                }
                if chatGPT.isSignedIn {
                    Link("Manage ChatGPT usage", destination: ChatGPTAccount.usageURL)
                } else {
                    ChatGPTSignInButton()
                    Text("Requires ChatGPT Plus or Pro.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Claude") {
                if claude.hasKey {
                    HStack {
                        Text("API key saved")
                        Spacer()
                        Button("Remove Key") { claude.disconnect() }
                    }
                    Link("Check Claude API credits", destination: ClaudeAccount.billingURL)
                } else {
                    ClaudeKeyField()
                    Text("Claude Max, Ultra, and Team plans include monthly API credits that cover this.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if chatGPT.isSignedIn && chatGPT.models.isEmpty { try? await chatGPT.loadModels() }
            if claude.hasKey && claude.models.isEmpty { try? await claude.loadModels() }
        }
    }
}

private struct PermissionsSettings: View {
    var body: some View {
        Form {
            PermissionRows()
        }
        .formStyle(.grouped)
    }
}

/// Microphone, system audio, notifications and calendar, with request buttons. Shared with onboarding.
struct PermissionRows: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: AppState
    @ObservedObject private var access = AccessibilityWatcher.shared
    @State private var mic = Permissions.microphone
    @State private var systemAudio = Permissions.systemAudio
    @State private var notificationsAsked = false
    @State private var calendar = CalendarHelper.shared.isAuthorized

    var body: some View {
        Group {
            row("Microphone", "Records your side of the call.", status: mic, settingsPane: "Privacy_Microphone") {
                Task { _ = await Permissions.requestMicrophone(); mic = Permissions.microphone }
            }
            row("System audio", "Records the other participants, straight from the Mac's audio. No drivers or routing changes.",
                status: systemAudio, settingsPane: "Privacy_ScreenCapture") {
                Task { _ = await Permissions.requestSystemAudio(); systemAudio = Permissions.systemAudio }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility")
                    Text("For dictation: hears the \(settings.dictationHotkey.keyName) key in other apps and pastes what you said.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if access.trusted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ready)
                } else {
                    Button("Allow") { state.dictation.requestAccessibility() }
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                    Text("Tells you when a transcript is ready.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(notificationsAsked ? "Requested" : "Allow") {
                    Task { _ = await Notifier.shared.requestPermission(); notificationsAsked = true }
                }
                .disabled(notificationsAsked)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar (optional)")
                    Text("Names meetings after the calendar event and suggests attendee names for speakers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if calendar {
                    Toggle("", isOn: $settings.useCalendar).labelsHidden()
                } else {
                    Button("Connect") {
                        Task {
                            calendar = await CalendarHelper.shared.requestAccess()
                            if calendar { settings.useCalendar = true }
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            mic = Permissions.microphone
            systemAudio = Permissions.systemAudio
            calendar = CalendarHelper.shared.isAuthorized
        }
    }

    private func row(_ title: String, _ detail: String, status: Permissions.Status, settingsPane: String,
                     request: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ready)
            case .denied:
                Button("Open Settings") { Permissions.openSettings(settingsPane) }
            case .notAsked:
                Button("Allow", action: request)
            }
        }
    }
}
