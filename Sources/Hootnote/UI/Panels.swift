import AppKit
import SwiftUI

/// Borderless always-on-top panel that doesn't steal focus from the call app.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The "call detected" prompt and the recording indicator, stacked in the top-right corner.
@MainActor
final class FloatingPanels {
    private var promptPanel: FloatingPanel?
    private var hudPanel: FloatingPanel?

    func showPrompt<V: View>(_ view: V) {
        promptPanel?.close()
        promptPanel = make(view)
        layout()
    }

    func hidePrompt() {
        promptPanel?.close()
        promptPanel = nil
        layout()
    }

    func showHUD<V: View>(_ view: V) {
        hudPanel?.close()
        hudPanel = make(view)
        layout()
    }

    func hideHUD() {
        hudPanel?.close()
        hudPanel = nil
        layout()
    }

    private func make<V: View>(_ view: V) -> FloatingPanel {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Keep Hootnote's own UI out of screen shares and recordings.
        panel.sharingType = .none
        panel.contentView = hosting
        panel.orderFrontRegardless()
        return panel
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var top = visible.maxY - 10
        for panel in [hudPanel, promptPanel].compactMap({ $0 }) {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 10, y: top - size.height))
            top -= size.height + 8
        }
    }
}

// MARK: - Call detected prompt

struct CallPromptView: View {
    @EnvironmentObject var state: AppState
    let app: MeetingApp
    let isSwitch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Theme.ruleStrong).frame(height: 2)
            HStack(alignment: .top, spacing: 12) {
                AppIcon(app: app, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.isBrowser ? "Call detected in \(app.name)" : "\(app.name) call detected")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(isSwitch ? "Stop the current recording and record this call instead?"
                                  : "Record and transcribe this call? It stays on this Mac. Let others know you're recording.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button {
                            state.acceptPrompt(always: false)
                        } label: {
                            Label("Record", systemImage: "record.circle.fill")
                        }
                        .buttonStyle(PillButtonStyle(fill: Theme.signal, foreground: Theme.onSignal))
                        .keyboardShortcut(.defaultAction)
                        Button("Not now") { state.declinePrompt() }
                            .buttonStyle(PillButtonStyle(fill: Theme.rule, foreground: Theme.ink))
                            .keyboardShortcut(.cancelAction)
                        Spacer(minLength: 0)
                        Menu {
                            Button("Always record \(app.name) calls") { state.acceptPrompt(always: true) }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityLabel("More options")
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(14)
        .frame(width: 350)
        .background(Theme.ground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.rule))
    }
}

// MARK: - Recording indicator

struct RecordingHUDView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var session: RecordingSession

    var body: some View {
        HStack(spacing: 10) {
            // Red means live: while paused for a dropped call nothing is captured, so the dot and clock go quiet.
            if session.isPaused {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.caution)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel("Paused")
            } else {
                PulsingDot()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(session.elapsed.clockString)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(session.isPaused ? Theme.ink : Theme.signal)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let ending = session.endingAt {
                        let left = ending.timeIntervalSinceNow.countdownString
                        Text(session.isPaused ? "Paused · stops in \(left)" : "Call ended? Stops in \(left)")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.caution)
                    } else {
                        Text(session.app.name)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            .frame(width: 150, alignment: .leading)
            LevelBar(level: session.isPaused ? 0 : session.micLevel, help: "Your microphone")
            if session.app.id != MeetingApps.manual.id {
                LevelBar(level: session.isPaused ? 0 : session.systemLevel, help: "Call audio")
            }
            if session.endingAt != nil {
                Button("Keep") { session.keepRecording = true }
                    .buttonStyle(PillButtonStyle(fill: Theme.caution, foreground: Theme.onCaution))
                    .help("Keep recording")
            }
            Button {
                state.stopRecording(.manual(from: "the floating indicator"))
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.ink)
            .help("Stop and transcribe")
            .accessibilityLabel("Stop and transcribe")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.rule))
        .fixedSize()
    }
}

// MARK: - Small shared views

/// Explicitly colored button: floating panels never become the key window, and the system's
/// prominent style turns gray in non-key windows.
struct PillButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

struct AppIcon: View {
    let app: MeetingApp
    var size: CGFloat = 20

    var body: some View {
        if let icon = app.icon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: app.id == MeetingApps.manual.id ? "person.2.circle.fill" : "phone.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Theme.signal)
            .frame(width: 10, height: 10)
            .opacity(reduceMotion || on ? 1 : 0.35)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// A small vertical level meter.
struct LevelBar: View {
    let level: Float
    let help: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // RMS 0.003 (-50 dB) … 0.3 (-10 dB) mapped onto the bar.
        let db = 20 * log10(max(Double(level), 1e-5))
        let fraction = min(1, max(0, (db + 50) / 40))
        ZStack(alignment: .bottom) {
            Capsule().fill(.quaternary)
            Capsule().fill(fraction > 0.85 ? Theme.caution : Theme.ready)
                .frame(height: max(2, 22 * fraction))
        }
        .frame(width: 5, height: 22)
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: fraction)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
        .accessibilityValue(fraction < 0.05 ? "silent" : "\(Int(fraction * 100)) percent")
    }
}
