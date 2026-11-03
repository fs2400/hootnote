import AVFoundation
import Foundation

/// Records your microphone (the system default input) with AVAudioEngine.
/// Survives device switches (e.g. AirPods connecting mid-call) by reinstalling the tap.
final class MicrophoneCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone is available, or microphone access is off." }
    }

    private let writer: AudioTrackWriter
    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var stopped = false

    init(writer: AudioTrackWriter) {
        self.writer = writer
    }

    func start() throws {
        try startEngine()
        observeConfigurationChanges()
    }

    func stop() {
        stopped = true
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        input.removeTap(onBus: 0)
        let writer = self.writer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            writer.append(buffer, hostTime: time.isHostTimeValid ? time.hostTime : nil)
        }
        engine.prepare()
        try engine.start()
        log.info("Microphone capture started: \(format)")
    }

    private func observeConfigurationChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, !self.stopped, (note.object as AnyObject?) === self.engine else { return }
            log.info("Input device changed; restarting microphone capture")
            self.restart(attempt: 0)
        }
    }

    private func restart(attempt: Int) {
        guard !stopped else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // A fresh engine picks up the new default input device cleanly.
        engine = AVAudioEngine()
        do {
            try startEngine()
        } catch {
            log.error("Mic restart failed (attempt \(attempt)): \(error.localizedDescription)")
            guard attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restart(attempt: attempt + 1) }
        }
    }
}
