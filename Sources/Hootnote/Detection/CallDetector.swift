import Foundation

/// Watches Core Audio for calling apps that are using the microphone.
///
/// No permission is needed: macOS 14+ exposes, per process, whether it is running
/// audio input/output. A calling app holding the mic is the signal that you're on a call
/// (the same signal behind the orange mic dot in the menu bar).
@MainActor
final class CallDetector: ObservableObject {
    struct State: Equatable {
        /// Calling apps currently using the mic (held for at least `startDebounce` polls).
        var micApps: Set<String> = []
        /// Calling apps currently playing audio.
        var outputApps: Set<String> = []
    }

    @Published private(set) var state = State()
    /// Every non-Hootnote process using the mic right now, for the diagnostics list in Settings.
    @Published private(set) var micUsers: [String] = []

    var onTick: ((State) -> Void)?

    private var timer: Timer?
    private var consecutiveMicPolls: [String: Int] = [:]
    private let startDebounce = 2
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.2
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let processes = AudioClientProcess.snapshot().filter { $0.pid != ownPID }
        var rawMic = Set<String>()
        var output = Set<String>()
        var users: [String] = []
        for p in processes {
            if p.isRunningInput { users.append(p.bundleID.isEmpty ? "pid \(p.pid)" : p.bundleID) }
            guard let app = MeetingApps.match(bundleID: p.bundleID) else { continue }
            if p.isRunningInput { rawMic.insert(app.id) }
            if p.isRunningOutput { output.insert(app.id) }
        }

        for id in rawMic { consecutiveMicPolls[id, default: 0] += 1 }
        for id in consecutiveMicPolls.keys where !rawMic.contains(id) { consecutiveMicPolls[id] = nil }
        let debounced = Set(consecutiveMicPolls.filter { $0.value >= startDebounce }.keys)

        let newState = State(micApps: debounced, outputApps: output)
        if newState != state { state = newState }
        let sortedUsers = users.sorted()
        if sortedUsers != micUsers { micUsers = sortedUsers }
        onTick?(newState)
    }
}
