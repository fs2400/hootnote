import AppKit
import SwiftUI

/// Hidden diagnostic: `Hootnote --snapshot <folder>` renders the main screens to PNGs offscreen,
/// to check layout without screen-recording permission.
@MainActor
enum Snapshot {
    static func run(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = AppState.shared
        let sample = state.store.meetings.first { $0.status == .ready }

        func env<V: View>(_ v: V) -> some View {
            v.environmentObject(state)
                .environmentObject(state.store)
                .environmentObject(state.settings)
                .environmentObject(state.voiceprints)
                .environmentObject(state.processor)
                .environmentObject(state.detector)
                .environmentObject(state.dictations)
        }

        // An in-memory meeting mid-transcription (never saved), so Home shows live state.
        let previewStart = max(Calendar.current.startOfDay(for: Date()), Date().addingTimeInterval(-40 * 60))
        var working = Meeting(id: UUID(), title: "Weekly team sync (preview)", appName: "Zoom", appID: "zoom",
                              startedAt: previewStart, endedAt: previewStart.addingTimeInterval(1690),
                              status: .processing)
        working.statusDetail = "Transcribing the other participants… 62%"
        working.speakerNames = ["Me", "Speaker 1", "Speaker 2"]
        state.store.previewInsert(working)

        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        for (suffix, appearance) in appearances {
            state.route = .home
            shot(env(MainView()), size: CGSize(width: 1280, height: 820), name: "home-\(suffix)", folder: folder, settle: 2.0, appearance: appearance)
            if let sample {
                state.route = .meeting(sample.id)
                shot(env(MainView()), size: CGSize(width: 1280, height: 820), name: "meeting-\(suffix)", folder: folder, settle: 3.0, appearance: appearance)
            }
            state.route = .dictations
            shot(env(MainView()), size: CGSize(width: 1280, height: 820), name: "dictations-\(suffix)", folder: folder, settle: 1.5, appearance: appearance)
        }
        state.route = .meetings
        shot(env(MainView()), size: CGSize(width: 1280, height: 820), name: "meetings-light", folder: folder, settle: 1.5)
        if let sample {
            let size = CGSize(width: 1040, height: 760)
            shot(env(MeetingDetailView(meetingID: sample.id, previewTime: 21.4).background(Theme.ground)), size: size,
                 name: "playback-light", folder: folder, settle: 3.0)
            shot(env(MeetingDetailView(meetingID: sample.id, previewTime: 21.4).background(Theme.ground)), size: size,
                 name: "playback-dark", folder: folder, settle: 3.0, appearance: .darkAqua)
            shot(env(MeetingDetailView(meetingID: sample.id, initialTab: .summary).background(Theme.ground)), size: size,
                 name: "summary-light", folder: folder, settle: 2.0)
            shot(env(MeetingDetailView(meetingID: sample.id, initialTab: .ask).background(Theme.ground)), size: size,
                 name: "ask-light", folder: folder, settle: 2.0)
            // The header, which offers a join when this meeting looks like the rest of the one before.
            for (suffix, appearance) in appearances {
                shot(env(MeetingDetailView(meetingID: sample.id).background(Theme.ground)), size: CGSize(width: 1040, height: 300),
                     name: "meeting-header-\(suffix)", folder: folder, settle: 2.0, appearance: appearance)
            }
            shot(env(MeetingDetailView(meetingID: sample.id).background(Theme.ground)), size: CGSize(width: 620, height: 300),
                 name: "meeting-header-narrow", folder: folder, settle: 2.0)
        }
        shot(env(OnboardingView()), size: CGSize(width: 1000, height: 1100), name: "onboarding", folder: folder)
        shot(env(CallPromptView(app: MeetingApps.app(id: "teams")!, isSwitch: false)), size: nil, name: "prompt", folder: folder)
        let session = RecordingSession(meetingID: UUID(), app: MeetingApps.app(id: "zoom")!)
        shot(env(RecordingHUDView(session: session)), size: nil, name: "hud", folder: folder)
        // The call app let go of the mic: the usual countdown, then the wait for a reconnect.
        session.endingAt = Date().addingTimeInterval(12)
        shot(env(RecordingHUDView(session: session)), size: nil, name: "hud-ending", folder: folder)
        session.endingAt = Date().addingTimeInterval(178)
        shot(env(RecordingHUDView(session: session)), size: nil, name: "hud-ending-long", folder: folder)
        session.endingAt = Date().addingTimeInterval(161)
        session.setPaused(true)
        shot(env(RecordingHUDView(session: session)), size: nil, name: "hud-paused", folder: folder)
        for (suffix, appearance) in appearances {
            shot(env(LiveRecordingView(session: session).background(Theme.ground)), size: CGSize(width: 1040, height: 520),
                 name: "recording-paused-\(suffix)", folder: folder, appearance: appearance)
        }
        if let sample {
            // Joining, and a join that didn't finish.
            let size = CGSize(width: 1040, height: 420)
            state.processor.previewJoining([sample.id])
            state.store.setTransientDetail(sample.id, "Joining: reading both recordings…")
            shot(env(MeetingDetailView(meetingID: sample.id).background(Theme.ground)), size: size,
                 name: "joining-light", folder: folder, settle: 2.0)
            state.processor.previewJoining([])
            state.store.setTransientDetail(sample.id, "Join didn't finish: \(MeetingJoiner.JoinError.changed.localizedDescription)")
            for (suffix, appearance) in appearances {
                shot(env(MeetingDetailView(meetingID: sample.id).background(Theme.ground)), size: size,
                     name: "join-failed-\(suffix)", folder: folder, settle: 2.0, appearance: appearance)
            }
            state.store.setTransientDetail(sample.id, nil)
            state.processor.previewJoined(sample.id)
            shot(env(MeetingDetailView(meetingID: sample.id).background(Theme.ground)), size: CGSize(width: 1040, height: 760),
                 name: "joined-notice-light", folder: folder, settle: 2.5)
        }
        shot(env(MenuBarView().background(Theme.ground)), size: nil, name: "menubar", folder: folder)
        let dictation = state.dictation
        let wave: [Float] = (0..<30).map { i in 0.01 + 0.09 * Float(abs(sin(Double(i) * 0.55))) * Float(i) / 30 }
        dictation.previewListening(levels: wave, handsFree: false)
        shot(DictationPillView(controller: dictation), size: CGSize(width: 340, height: 44), name: "pill-listening", folder: folder)
        dictation.previewListening(levels: wave, handsFree: true)
        shot(DictationPillView(controller: dictation), size: CGSize(width: 340, height: 44), name: "pill-handsfree", folder: folder)
        shot(env(SettingsView()), size: CGSize(width: 600, height: 470), name: "settings", folder: folder)
        for (suffix, appearance) in appearances {
            shot(env(AISetupSheet(previewDisconnected: true)), size: nil, name: "ai-setup-\(suffix)", folder: folder, appearance: appearance)
            shot(env(SummaryPromptView(meetingID: UUID(), title: "Weekly team sync", service: "Claude")), size: nil,
                 name: "summary-prompt-\(suffix)", folder: folder, appearance: appearance)
        }
    }

    private static func shot<V: View>(_ view: V, size: CGSize?, name: String, folder: URL, settle: TimeInterval = 0.8,
                                      appearance: NSAppearance.Name = .aqua) {
        let hosting = NSHostingView(rootView: view)
        let frame = NSRect(origin: .zero, size: size ?? hosting.fittingSize)
        let window = NSWindow(contentRect: frame.offsetBy(dx: -10_000, dy: -10_000),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: appearance)
        window.orderFrontRegardless()
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
        }
        window.orderOut(nil)
    }
}
