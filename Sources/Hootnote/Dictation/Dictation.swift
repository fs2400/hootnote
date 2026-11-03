import AVFoundation
import AppKit
import ApplicationServices
import Foundation

struct Dictation: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var text: String
    var appName: String
    var bundleID: String?
    var duration: TimeInterval
}

/// Dictation history. Text only: the audio is never written to disk.
@MainActor
final class DictationStore: ObservableObject {
    @Published private(set) var items: [Dictation] = []
    private var url: URL { AppPaths.appSupport.appendingPathComponent("dictations.json") }

    init() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? d.decode([Dictation].self, from: data) { items = saved }
    }

    func add(_ item: Dictation) {
        items.insert(item, at: 0)
        save()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        items.removeAll()
        save()
    }

    func search(_ query: String) -> [Dictation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.appName.localizedCaseInsensitiveContains(q) }
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(items) { try? data.write(to: url, options: .atomic) }
    }
}

/// Global push-to-talk key: fn (Globe) or Right Option. Needs Accessibility permission.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Another key was pressed while the hotkey is held (fn+arrow, fn+F5…): not a dictation.
    var onChord: (() -> Void)?
    var hotkey: DictationHotkey = .fn

    private var monitors: [Any] = []
    private var isDown = false

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        stop()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if isDown { onChord?() }
            return
        }
        let code: UInt16 = hotkey == .fn ? 63 : 61 // kVK_Function, kVK_RightOption
        guard event.keyCode == code else { return }
        let pressed = hotkey == .fn ? event.modifierFlags.contains(.function) : event.modifierFlags.contains(.option)
        if pressed, !isDown {
            isDown = true
            onPress?()
        } else if !pressed, isDown {
            isDown = false
            onRelease?()
        }
    }
}

/// Records the mic into memory at 16 kHz and reports live levels for the waveform.
final class DictationRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    var onLevel: (@Sendable (Float) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneCapture.CaptureError.noInput }
        converter = AVAudioConverter(from: format, to: outFormat)
        converter?.downmix = true
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in self?.process(buffer) }
        engine.prepare()
        try engine.start()
    }

    /// Stops and returns everything captured.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { samples }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        if let ch = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            onLevel?((sum / Float(max(buffer.frameLength, 1))).squareRoot())
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        lock.withLock { samples.append(contentsOf: chunk) }
    }
}

/// Hold the hotkey to talk; release to paste. A quick tap starts hands-free dictation; tap again to finish.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var handsFree = false
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 30)
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    let store: DictationStore
    private let settings = AppSettings.shared
    private let monitor = HotkeyMonitor()
    private var recorder: DictationRecorder?
    private var targetApp: NSRunningApplication?
    private var pressedAt = Date.distantPast
    private var endOnRelease = false
    private var trustTimer: Timer?
    private var maxTimer: Timer?
    private let pill = DictationPillWindow()
    var transcribe: (([Float]) async throws -> String)?

    init(store: DictationStore) {
        self.store = store
        monitor.onPress = { [weak self] in self?.pressed() }
        monitor.onRelease = { [weak self] in self?.released() }
        monitor.onChord = { [weak self] in self?.chord() }
    }

    /// Starts listening for the hotkey once Accessibility access is granted.
    func activate() {
        trustTimer?.invalidate()
        guard settings.dictationEnabled else { monitor.stop(); return }
        monitor.hotkey = settings.dictationHotkey
        if AXIsProcessTrusted() {
            accessibilityGranted = true
            monitor.start()
        } else {
            accessibilityGranted = false
            // Global key monitors only work once the app is trusted, so check back until it is.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.trustTimer?.invalidate()
                    self.accessibilityGranted = true
                    self.monitor.start()
                }
            }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        activate()
    }

    /// Snapshot tool only: show the listening state with a given waveform.
    func previewListening(levels: [Float], handsFree: Bool) {
        self.levels = levels
        self.handsFree = handsFree
        phase = .listening
    }

    // MARK: Hotkey

    private func pressed() {
        switch phase {
        case .listening where handsFree:
            endOnRelease = true
        case .listening, .transcribing:
            break
        default:
            begin()
        }
    }

    private func released() {
        guard phase == .listening else { return }
        if handsFree {
            if endOnRelease { finish() }
        } else if Date().timeIntervalSince(pressedAt) < 0.35 {
            handsFree = true
        } else {
            finish()
        }
    }

    private func chord() {
        guard phase == .listening, !handsFree, Date().timeIntervalSince(pressedAt) < 1.5 else { return }
        cancel()
    }

    // MARK: Flow

    private func begin() {
        targetApp = NSWorkspace.shared.frontmostApplication
        pressedAt = Date()
        handsFree = false
        endOnRelease = false
        levels = Array(repeating: 0, count: levels.count)
        let recorder = DictationRecorder()
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.push(level) }
        }
        do {
            try recorder.start()
        } catch {
            show(.failed("Microphone unavailable"))
            return
        }
        self.recorder = recorder
        phase = .listening
        pill.show(controller: self)
        announce("Hootnote is listening")
        maxTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func push(_ level: Float) {
        guard phase == .listening else { return }
        levels.removeFirst()
        levels.append(level)
    }

    private func cancel() {
        maxTimer?.invalidate()
        _ = recorder?.stop()
        recorder = nil
        phase = .idle
        pill.hide()
    }

    private func finish() {
        maxTimer?.invalidate()
        guard let recorder else { return }
        let samples = recorder.stop()
        self.recorder = nil
        let duration = Double(samples.count) / 16_000
        guard duration >= 0.4 else { cancel(); return }
        phase = .transcribing
        let target = targetApp
        Task {
            do {
                guard let transcribe else { throw TranscriptionEngine.EngineError.notReady }
                let text = try await transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { show(.failed("Didn't catch that")); return }
                paste(text, into: target)
                store.add(Dictation(date: Date(), text: text, appName: target?.localizedName ?? "Unknown app",
                                    bundleID: target?.bundleIdentifier, duration: duration))
                show(.done("Pasted"))
            } catch {
                show(.failed("Couldn't transcribe"))
            }
        }
    }

    private func show(_ final: Phase) {
        phase = final
        pill.show(controller: self)
        switch final {
        case .done(let m), .failed(let m): announce(m)
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.phase == final else { return }
            self.phase = .idle
            self.pill.hide()
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Paste

    /// Puts the text on the clipboard, presses ⌘V in the app you were using, then restores the clipboard.
    private func paste(_ text: String, into app: NSRunningApplication?) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { copy[type] = data } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ours = pb.changeCount
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isActive {
            app.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down) // "v"
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard pb.changeCount == ours, !saved.isEmpty else { return }
                pb.clearContents()
                pb.writeObjects(saved.map { types -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in types { item.setData(data, forType: type) }
                    return item
                })
            }
        }
    }
}
