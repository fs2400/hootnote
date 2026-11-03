import Foundation

/// One live recording: your mic and the call audio, written to separate tracks.
@MainActor
final class RecordingSession: ObservableObject, Identifiable {
    let id: UUID
    let app: MeetingApp
    let startedAt = Date()

    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var warnings: [String] = []
    /// Set while the calling app has released the mic and we're waiting to see if the call ended.
    @Published var endingAt: Date?
    /// "Keep recording" from the indicator: ignore the call ending for this recording.
    @Published var keepRecording = false
    /// Set while waiting, past the usual grace period, for a dropped call to come back. Nothing is
    /// written meanwhile; if the call returns, the wait is kept as silence so the timeline stays true.
    @Published private(set) var isPaused = false {
        didSet {
            micWriter?.isPaused = isPaused
            systemWriter?.isPaused = isPaused
        }
    }
    /// Pauses or resumes capture; publishes only on a change (auto-stop calls this every second).
    func setPaused(_ paused: Bool) {
        if isPaused != paused { isPaused = paused }
    }

    /// The calendar event this call belongs to (see CalendarHelper.currentEvent).
    var calendarEvent: (id: String, end: Date)?

    private var micWriter: AudioTrackWriter?
    private var systemWriter: AudioTrackWriter?
    private var mic: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var meterTimer: Timer?

    init(meetingID: UUID, app: MeetingApp) {
        self.id = meetingID
        self.app = app
    }

    /// When the other side last made a sound (used to tell "muted" from "call ended").
    var lastRemoteAudio: Date { systemWriter?.lastActivity ?? .distantPast }

    func start(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let startHost = mach_absolute_time()
        let micWriter = try AudioTrackWriter(url: folder.appendingPathComponent("mic.caf"), startHostTime: startHost, label: "mic")
        let systemWriter = try AudioTrackWriter(url: folder.appendingPathComponent("system.caf"), startHostTime: startHost, label: "system")
        self.micWriter = micWriter
        self.systemWriter = systemWriter

        var failures: [String] = []
        let mic = MicrophoneCapture(writer: micWriter)
        do {
            try mic.start()
            self.mic = mic
        } catch {
            failures.append("Microphone: \(error.localizedDescription)")
        }
        let system = SystemAudioCapture(writer: systemWriter)
        do {
            try system.start()
            self.system = system
        } catch {
            failures.append("Call audio: \(error.localizedDescription)")
        }
        warnings = failures
        if self.mic == nil && self.system == nil {
            throw NSError(domain: "Hootnote", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
        }

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        mic?.stop()
        system?.stop()
        micWriter?.finish()
        systemWriter?.finish()
        mic = nil
        system = nil
        micLevel = 0
        systemLevel = 0
    }

    private func tick() {
        let now = Date().timeIntervalSince(startedAt)
        if Int(now) != Int(elapsed) { elapsed = now }
        // Smooth the meters a little so they don't flicker.
        micLevel = max(micWriter?.level ?? 0, micLevel * 0.7)
        systemLevel = max(systemWriter?.level ?? 0, systemLevel * 0.7)
        // If the call has been silent for 45 s, the system-audio permission is probably off:
        // macOS delivers silence instead of an error in that case.
        if elapsed > 45, elapsed < 45.2, let systemWriter, systemWriter.lastActivity == .distantPast, system != nil {
            warnings.append("No sound from the call yet. If others are talking, check System Settings › Privacy & Security › Screen & System Audio Recording.")
        }
    }
}
