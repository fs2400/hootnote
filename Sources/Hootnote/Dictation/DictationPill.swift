import AppKit
import SwiftUI

/// The small pill just above the Dock while dictating. It never takes focus or clicks,
/// so typing and pasting go to the app you were in.
@MainActor
final class DictationPillWindow {
    private var panel: FloatingPanel?
    private let size = NSSize(width: 340, height: 44)

    func show(controller: DictationController) {
        if panel == nil {
            let hosting = NSHostingView(rootView: DictationPillView(controller: controller))
            let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.ignoresMouseEvents = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.sharingType = .none // dictating while presenting never shows Hootnote to the audience
            p.contentView = hosting
            panel = p
        }
        position()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Centered just above the Dock on the screen you're working on.
    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel?.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 12))
    }
}

struct DictationPillView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .listening:
                Circle().fill(Theme.pillSignal).frame(width: 8, height: 8)
                Waveform(levels: controller.levels)
                if controller.handsFree {
                    Text("Tap \(settings.dictationHotkey.keyName) to finish")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize()
                }
            case .transcribing:
                ProgressView().controlSize(.small).tint(.white)
                Text("Transcribing").font(.system(size: 12, weight: .medium))
            case .done(let message):
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                Text(message).font(.system(size: 12, weight: .medium))
            case .failed(let message):
                Image(systemName: "exclamationmark.circle").font(.system(size: 12, weight: .bold))
                Text(message).font(.system(size: 12, weight: .medium))
            case .idle:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Capsule().fill(Theme.pill))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .fixedSize()
        .frame(width: 340, height: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch controller.phase {
        case .listening: return "Hootnote is listening"
        case .transcribing: return "Transcribing"
        case .done(let m), .failed(let m): return m
        case .idle: return ""
        }
    }
}

/// Live input level as a row of bars, newest on the right.
struct Waveform: View {
    let levels: [Float]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: 3, height: height(levels[i]))
            }
        }
        .frame(height: 24)
        .animation(reduceMotion ? nil : .linear(duration: 0.06), value: levels)
    }

    private func height(_ level: Float) -> CGFloat {
        let db = 20 * log10(max(Double(level), 1e-5))
        let fraction = min(1, max(0, (db + 55) / 42))
        return 3 + 21 * fraction
    }
}
