import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var processor: ProcessingQueue
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Set up Hootnote").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Hootnote notices when a call starts, asks to record, stops when it ends, and writes a transcript split by speaker. Name someone once and Hootnote recognizes their voice next time. Everything stays on this Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.top, 6)
                    .padding(.bottom, 26)

                TimetableRule()
                step(1, "Your name", detail: "Used for your microphone track in every transcript.") {
                    TextField("Your name", text: $settings.userName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                step(2, "Permissions", detail: "Microphone and system audio are needed to record calls; Accessibility powers dictation.") {
                    VStack(alignment: .leading, spacing: 14) { PermissionRows() }
                        .frame(maxWidth: 640)
                }
                step(3, "Dictation key", detail: nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hold fn in any app and speak; let go to paste. In System Settings › Keyboard, set “Press \(Image(systemName: "globe")) key to” to Do Nothing so macOS doesn't open the emoji picker too.")
                            .font(Theme.body).foregroundStyle(Theme.inkSecondary)
                            .frame(maxWidth: 620, alignment: .leading)
                        Button("Open Keyboard Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                step(4, "Stay ready for calls", detail: nil) {
                    Toggle("Open Hootnote at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in LoginItem.set(on); launchAtLogin = LoginItem.isEnabled }
                }
                step(5, "Speech models", detail: "OpenAI Whisper Large-v3 Turbo for words, Parakeet for word timing and pyannote for speakers, about 2.2 GB, downloaded once.") {
                    if processor.modelsReady {
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ready)
                    } else if let status = processor.modelStatus {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).foregroundStyle(Theme.working) }
                    } else {
                        Button("Download models") { processor.warmUp() }
                    }
                }

                HStack(spacing: 16) {
                    Button {
                        settings.hasCompletedOnboarding = true
                        processor.warmUp()
                    } label: {
                        Text("Start using Hootnote").frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Text("Recording laws vary: in some places everyone on a call must agree to be recorded.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkTertiary)
                }
                .padding(.top, 26)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 36)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.ground)
    }

    private func step<Content: View>(_ n: Int, _ title: String, detail: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(n)")
                    .font(Theme.timeLarge)
                    .foregroundStyle(Theme.ink)
                    .frame(width: Theme.timeColumn, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(Theme.section).foregroundStyle(Theme.ink)
                    if let detail { Text(detail).font(Theme.body).foregroundStyle(Theme.inkSecondary) }
                    content().padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 18)
            HairlineRule()
        }
    }
}
