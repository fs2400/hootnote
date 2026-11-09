import AppKit
import AVFoundation
import Foundation

/// Hidden test commands (no UI):
///   Hootnote --export <outdir>          write every export format for the first ready meeting
///   Hootnote --import-test <file>       extract and transcribe a file as an uploaded, in-person meeting
///   Hootnote --ask-test "<question>"    stream an answer about the first ready meeting
@MainActor
enum Diagnostics {
    static func export(to folder: URL) {
        let store = MeetingStore()
        guard let m = store.meetings.first(where: { $0.status == .ready }), let t = store.transcript(for: m.id) else {
            print("no ready meeting"); return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for format in ExportFormat.allCases {
            let url = folder.appendingPathComponent("export.\(format.fileExtension)")
            do {
                try Exporter.write(format, meeting: m, transcript: t, summary: store.summary(for: m.id), to: url)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                print("\(format.rawValue): \(url.lastPathComponent) \(size) bytes")
            } catch {
                print("\(format.rawValue): FAILED \(error)")
            }
        }
    }

    static func importTest(_ file: URL) async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hootnote-import-test.caf")
        try? FileManager.default.removeItem(at: tmp)
        do {
            let duration = try await AudioImporter.extract(from: file, to: tmp)
            print(String(format: "extracted %.1f s to 16 kHz mono", duration))
            let engine = TranscriptionEngine.shared
            try await engine.prepare(model: .whisperTurbo) { _ in }
            let samples = try await engine.loadSamples(tmp)
            let words = try await engine.transcribe(samples: samples, options: WhisperOptions(language: "en", vocabulary: "")) { _ in }
            let diar = try await engine.diarize(samples: samples)
            let built = TranscriptBuilder.build(micWords: [], systemWords: [], systemSegments: [], micSegments: diar.segments)
            _ = built
            let inPerson = TranscriptBuilder.build(micWords: words, systemWords: [], systemSegments: [], micSegments: diar.segments)
            print("speakers found: \(Set(inPerson.utterances.map(\.speakerID)).sorted())")
            for u in inPerson.utterances { print(String(format: "[%5.1f] %@: %@", u.start, u.speakerID, u.text)) }
        } catch {
            print("FAILED: \(error)")
        }
    }

    static func askTest(_ question: String) async {
        let store = MeetingStore()
        guard let m = store.meetings.first(where: { $0.status == .ready }), let t = store.transcript(for: m.id) else {
            print("no ready meeting"); return
        }
        let session = AskSession()
        // HOOTNOTE_MODEL=claude/<model id> or chatgpt/<slug> asks a model other than the default.
        if let spec = ProcessInfo.processInfo.environment["HOOTNOTE_MODEL"], let slash = spec.firstIndex(of: "/"),
           let provider = AIProvider(rawValue: String(spec[..<slash])) {
            let id = String(spec[spec.index(after: slash)...])
            session.choice = AIModelChoice(provider: provider, modelID: id, name: id)
        }
        let start = Date()
        await session.ask(question, meeting: m, transcript: t, summary: store.summary(for: m.id), settings: AppSettings.shared)
        guard let turn = session.turns.last else { return }
        print("model: \(session.choice?.modelID ?? "default (\(AIModels.defaultChoice?.name ?? "none"))") · \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        print(turn.error.map { "ERROR: \($0)" } ?? "answer: \(turn.answer)")
    }

    /// `Hootnote --models`: the models each connected service lists right now, as the model menus show them.
    static func listModels() async {
        await AIModels.refresh()
        print("default: \(AIModels.defaultChoice.map { "\($0.provider.label) · \($0.name) (\($0.modelID))" } ?? "none connected")")
        for provider in AIModels.connected {
            let lists = AIModels.menu(provider)
            print("\n\(provider.label)")
            for c in lists.main { print("  \(c.name)  [\(c.modelID)]") }
            if !lists.more.isEmpty { print("  More Models:") }
            for c in lists.more { print("    \(c.name)  [\(c.modelID)]") }
        }
    }

    /// `Hootnote --summary-test <part of a meeting title>`: summarizes that meeting with the service chosen
    /// in Settings › AI (ChatGPT or Claude). Set it up there first.
    static func summaryTest(_ title: String) async {
        let store = MeetingStore()
        guard let m = store.meetings.first(where: { $0.title.localizedCaseInsensitiveContains(title) }),
              let t = store.transcript(for: m.id) else { print("no meeting matches \(title)"); return }
        do {
            let ai = try await AIConnection.current()
            let start = Date()
            let notes = try await Summarizer.summarize(meeting: m, transcript: t, using: ai) { print($0) }
            print("\(ai.app) · \(ai.modelName) · \(String(format: "%.1f", Date().timeIntervalSince(start))) s\n\(notes)")
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
    }
}

extension Diagnostics {
    /// `Hootnote --aec-analyze <meeting folder>`: how much each echo-canceller stage changes the mic,
    /// split by who is talking (you alone, the call alone, both).
    static func aecAnalyze(_ folder: URL) async {
        do {
            let engine = TranscriptionEngine.shared
            let mic = try await engine.loadSamples(folder.appendingPathComponent("mic.caf"))
            let sys = try await engine.loadSamples(folder.appendingPathComponent("system.caf"))
            let n = min(mic.count, sys.count)
            let m = Array(mic.prefix(n)), s = Array(sys.prefix(n))
            let r = await engine.cancelEcho(mic: m, reference: s)
            print("AEC:", r.report.description)
            let hop = 512 // 32 ms
            func rms(_ x: [Float], _ i: Int) -> Float {
                var acc: Float = 0
                for k in i..<min(i + hop, x.count) { acc += x[k] * x[k] }
                return (acc / Float(hop)).squareRoot()
            }
            var buckets: [String: (count: Int, linDb: Double, supDb: Double, gated: Int)] = [:]
            var micLevels: [Float] = [], sysLevels: [Float] = []
            for i in stride(from: 0, to: n - hop, by: hop) {
                let mr = rms(m, i), sr = rms(s, i)
                guard mr > 0.004 || sr > 0.004 else { continue }
                let key = sr < 0.003 ? "you alone" : (mr > 4 * sr * 0.18 ? "both talking" : "call alone")
                let lin = rms(r.linear, i), sup = rms(r.output, i)
                let linDb = 20 * log10(Double(max(lin, 1e-6) / max(mr, 1e-6)))
                let supDb = 20 * log10(Double(max(sup, 1e-6) / max(mr, 1e-6)))
                var b = buckets[key] ?? (0, 0, 0, 0)
                b.count += 1; b.linDb += linDb; b.supDb += supDb
                if supDb < -12 { b.gated += 1 }
                buckets[key] = b
                if mr > 0.004 && sr < 0.003 { micLevels.append(mr) }
                if sr > 0.004 { sysLevels.append(sr) }
            }
            for (k, b) in buckets.sorted(by: { $0.key < $1.key }) {
                print(String(format: "%-13@ %6d frames | linear filter %6.1f dB | after suppressor %6.1f dB | frames cut >12 dB: %4.1f%%",
                             k as NSString, b.count, b.linDb / Double(b.count), b.supDb / Double(b.count), 100 * Double(b.gated) / Double(b.count)))
            }
            func median(_ a: [Float]) -> Double { a.isEmpty ? 0 : Double(a.sorted()[a.count / 2]) }
            print(String(format: "median speech level: you %.1f dBFS, call %.1f dBFS",
                         20 * log10(max(median(micLevels), 1e-6)), 20 * log10(max(median(sysLevels), 1e-6))))
        } catch {
            print("FAILED: \(error)")
        }
    }
}

extension Diagnostics {
    /// `Hootnote --cleanup-test <meeting folder>`: how Clean Up judges each of your fragments.
    static func cleanupTest(_ folder: URL) async {
        do {
            let name = ProcessInfo.processInfo.environment["TRANSCRIPT"] ?? "transcript.json"
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let t = try decoder.decode(Transcript.self, from: data)
            let engine = TranscriptionEngine.shared
            func load(_ name: String) async throws -> [Float] {
                for ext in ["caf", "m4a"] {
                    let url = folder.appendingPathComponent("\(name).\(ext)")
                    if FileManager.default.fileExists(atPath: url.path) { return try await engine.loadSamples(url) }
                }
                return []
            }
            var mic = try await load("mic")
            let sys = try await load("system")
            if ProcessInfo.processInfo.environment["AEC"] != nil {
                let n = min(mic.count, sys.count)
                mic = await engine.cancelEcho(mic: Array(mic.prefix(n)), reference: Array(sys.prefix(n))).output
            }
            let mine = t.utterances.filter { $0.speakerID == TranscriptBuilder.meID }
            let others = t.utterances.filter { $0.speakerID != TranscriptBuilder.meID }
            var voices: TranscriptCleaner.Voices?
            if ProcessInfo.processInfo.environment["NO_VOICES"] == nil {
                try await engine.prepare(model: .whisperTurbo) { _ in }
                let d = try await engine.diarize(samples: mic)
                voices = .init(micSegments: d.segments, micSpeakers: d.speakers, callVoices: t.speakers.compactMap(\.embedding))
            }
            let judged = TranscriptCleaner.judge(TranscriptCleaner.fragments(of: mine.flatMap(\.words)), remote: others,
                                                 audio: .init(mic: mic, system: sys), voices: voices)
            for f in judged {
                let tag = f.echoShare == 1 ? "ECHO" : f.echoShare > 0 ? "part" : "keep"
                print(String(format: "%@ %8.2f  ov %.2f  contour %.2f  text %.2f  level %+5.1f  voice %@%@  %@",
                             tag, f.start, f.overlap, f.contour, f.textMatch, f.relativeLevel, (f.voice ?? "-") as NSString,
                             f.voiceIsEcho == true ? "(echo)" : "", String(f.text.prefix(90)) as NSString))
            }
            let echoWords = judged.reduce(0) { $0 + $1.echo.filter { $0 }.count }
            print("fragments \(judged.count), with echo \(judged.filter { $0.echoShare > 0 }.count), echo words \(echoWords) of \(mine.flatMap(\.words).count)")
        } catch {
            print("FAILED: \(error)")
        }
    }
}

extension Diagnostics {
    /// `Hootnote --timing-test <audio file>`: how far Whisper's word times are from Parakeet's.
    static func timingTest(_ file: URL) async {
        do {
            let engine = TranscriptionEngine.shared
            try await engine.prepare(model: .whisperTurbo) { print($0) }
            let samples = try await engine.loadSamples(file)
            let (whisper, parakeet) = try await engine.timingComparison(
                samples: samples, options: WhisperOptions(language: "en", vocabulary: AppSettings.shared.customVocabulary), chunkLimit: 30)
            let aligned = WordTiming.align(whisper, to: parakeet)
            var deltas: [Double] = []
            for (w, a) in zip(whisper, aligned.words) where a.start != w.start || a.end != w.end { deltas.append(w.start - a.start) }
            let abs = deltas.map { Swift.abs($0) }.sorted()
            func pct(_ p: Double) -> Double { abs.isEmpty ? 0 : abs[min(abs.count - 1, Int(Double(abs.count) * p))] }
            print("whisper words \(whisper.count), parakeet words \(parakeet.count), matched \(aligned.matched)")
            print(String(format: "Whisper start error vs Parakeet: median %.0f ms, p75 %.0f ms, p90 %.0f ms, mean signed %+.0f ms",
                         pct(0.5) * 1000, pct(0.75) * 1000, pct(0.9) * 1000, 1000 * deltas.reduce(0, +) / Double(max(deltas.count, 1))))
            for (w, a) in zip(whisper, aligned.words).prefix(60) {
                print(String(format: "%-16@ whisper %7.2f-%7.2f  aligned %7.2f-%7.2f", w.text as NSString, w.start, w.end, a.start, a.end))
            }
        } catch {
            print("FAILED: \(error)")
        }
    }
}

extension Diagnostics {
    /// `Hootnote --process <meeting id>` / `--clean-up <meeting id>`: run the real queue on one meeting, headless.
    static func runQueue(_ idString: String, cleanUp: Bool) async {
        guard let id = UUID(uuidString: idString) else { print("bad id"); return }
        let store = MeetingStore()
        let queue = ProcessingQueue(store: store, voiceprints: VoiceprintStore())
        let start = Date()
        if cleanUp { queue.enqueueCleanUp(id) } else { queue.enqueue(id) }
        var last = ""
        repeat {
            try? await Task.sleep(for: .milliseconds(500))
            let p = store.meeting(id)?.statusDetail ?? ""
            if p != last, !p.isEmpty { print(String(format: "%6.1f s  %@", Date().timeIntervalSince(start), p)); last = p }
        } while queue.activeID != nil || !queue.pendingIDs.isEmpty
        let m = store.meeting(id)
        print(String(format: "done in %.0f s: status %@, %@", Date().timeIntervalSince(start), m?.status.rawValue ?? "?", m?.echoNote ?? ""))
    }
}

extension Diagnostics {
    /// `Hootnote --rebuild-playback <meeting id>`: write playback.m4a again.
    static func rebuildPlayback(_ idString: String) async {
        guard let id = UUID(uuidString: idString) else { print("bad id"); return }
        let store = MeetingStore()
        guard let m = store.meeting(id) else { print("no meeting"); return }
        let queue = ProcessingQueue(store: store, voiceprints: VoiceprintStore())
        let start = Date()
        do {
            try await queue.rebuildPlayback(m.id)
            print(String(format: "playback written in %.1f s", Date().timeIntervalSince(start)))
        } catch {
            print("FAILED: \(error)")
        }
    }
}

extension Diagnostics {
    /// `Hootnote --writer-test <out.caf>`: 10 minutes of a 48 kHz sine whose device clock runs 60 ppm slow
    /// (and then fast) against the host clock. The track must stay aligned without silence or skips.
    static func writerTest(_ url: URL) {
        for ppm in [-60.0, 60.0] {
            try? FileManager.default.removeItem(at: url)
            let start = mach_absolute_time()
            guard let writer = try? AudioTrackWriter(url: url, startHostTime: start, label: "test") else { print("writer failed"); return }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let frames: AVAudioFrameCount = 512
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
            let total = Int(600 * 48_000 / Double(frames))
            var phase = 0.0
            for i in 0..<total {
                let p = buffer.floatChannelData![0]
                for k in 0..<Int(frames) { p[k] = Float(0.3 * sin(phase)); phase += 2 * .pi * 220 / 48_000 }
                // The device delivers `frames` samples per buffer, but its clock is off by `ppm`.
                let seconds = Double(i) * Double(frames) / 48_000 * (1 + ppm / 1_000_000)
                let host = start + UInt64(seconds * 1e9 * Double(info.denom) / Double(info.numer)) + 1
                writer.append(buffer, hostTime: host)
            }
            writer.finish()
            guard let file = try? AVAudioFile(forReading: url),
                  let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: out)) != nil else { print("read failed"); return }
            let n = Int(out.frameLength), x = out.floatChannelData![0]
            var zeroRun = 0, longestZero = 0, jumps = 0
            for k in 1..<n {
                zeroRun = abs(x[k]) < 1e-6 ? zeroRun + 1 : 0
                longestZero = max(longestZero, zeroRun)
                if abs(x[k] - x[k - 1]) > 0.1 { jumps += 1 } // a 220 Hz sine at 16 kHz moves < 0.03 per sample
            }
            let expected = 600 * (1 + ppm / 1_000_000) * 16_000
            print(String(format: "clock %+.0f ppm: %d samples (host clock says %.0f, off by %.1f ms), longest silence %d samples, discontinuities %d",
                         ppm, n, expected, (Double(n) - expected) / 16, longestZero, jumps))
        }
    }

}

extension Diagnostics {
    /// `Hootnote --paragraph-test x`: copying from a transcript paragraph gives plain text only, and a click
    /// lands on the word under the pointer.
    static func paragraphTest() {
        let words = ["Thank", "you,", "yeah.", "I'll", "follow", "up", "with", "her."].enumerated().map { i, w in
            Word(text: w, start: Double(i) * 0.4, end: Double(i) * 0.4 + 0.3)
        }
        let u = Utterance(speakerID: "me", start: 0, end: 3.2, text: words.map(\.text).joined(separator: " "), words: words)
        let view = WordTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        view.isEditable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.show(u, query: "")
        print("height at 400 pt:", view.height(forWidth: 400))
        view.setSelectedRange(NSRange(location: 0, length: (u.text as NSString).length))
        let board = NSPasteboard(name: NSPasteboard.Name("com.local.Hootnote.test"))
        board.clearContents()
        let wrote = view.writeSelection(to: board, types: view.writablePasteboardTypes)
        print("selection:", view.selectedRange(), "wrote:", wrote)
        print("copied types:", board.types?.map(\.rawValue) ?? [], "text:", board.string(forType: .string) ?? "nil",
              "| rtf present:", board.data(forType: .rtf) != nil)
        board.releaseGlobally()
        // Click points: the middle of each word's glyphs.
        if let layout = view.layoutManager, let container = view.textContainer {
            var location = 0
            for w in words {
                let range = NSRange(location: location, length: (w.text as NSString).length)
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                let hit = view.wordStart(at: NSPoint(x: rect.midX, y: rect.midY))
                print(String(format: "%-8@ expected %.1f got %@", w.text as NSString, w.start, hit.map { String(format: "%.1f", $0) } ?? "nil"))
                location += range.length + 1
            }
            print("past the end of the line:", view.wordStart(at: NSPoint(x: 395, y: 5)).map { "\($0)" } ?? "nil")
        }
    }
}

extension Diagnostics {
    /// `HOOTNOTE_MEETINGS_DIR=<folder of copies> Hootnote --join-test <later meeting id>`: joins a meeting
    /// with the one before it as the Meeting menu does, on copies. Nothing is summarized or exported, and
    /// the later meeting's folder moves to "<folder>/../joined-away" instead of the Trash.
    static func joinTest(_ idString: String) async {
        guard let dir = ProcessInfo.processInfo.environment["HOOTNOTE_MEETINGS_DIR"] else {
            print("set HOOTNOTE_MEETINGS_DIR to a folder of copied meetings"); return
        }
        guard let id = UUID(uuidString: idString) else { print("bad id"); return }
        let store = MeetingStore()
        guard let second = store.meeting(id), let first = store.meeting(before: second) else { print("no meeting before it"); return }
        if let problem = MeetingJoiner.problem(joining: first, with: second, store: store) { print("can't join: \(problem)"); return }
        print("dialog: " + JoinRequest(previous: first, meeting: second, problem: nil).explanation(summaryEnabled: true))
        if ProcessInfo.processInfo.environment["DIALOG_ONLY"] != nil { return }
        let away = URL(fileURLWithPath: dir).deletingLastPathComponent().appendingPathComponent("joined-away", isDirectory: true)
        let queue = ProcessingQueue(store: store, voiceprints: VoiceprintStore())
        let start = Date()
        do {
            let (t, originals) = try await queue.joinMeetings(first.id, second.id) { id in
                try? FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: AppPaths.folder(for: id), to: away.appendingPathComponent(id.uuidString))
                store.load()
            }
            print("earlier meeting's replaced files: \(originals.path)")
            let m = store.meeting(first.id)
            print(String(format: "joined in %.0f s; duration %.1f s; parts %@; micIsRaw %@; %@", Date().timeIntervalSince(start),
                         m?.duration ?? 0, "\(m?.parts ?? [])", "\(m?.micIsRaw.map(String.init) ?? "nil")", m?.echoNote ?? ""))
            print("utterances \(t.utterances.count); speakers: " + t.speakers.map { "\($0.id)=\($0.name)" }.joined(separator: ", "))
            for name in ["mic.m4a", "system.m4a", "playback.m4a", "recording.m4a"] {
                let url = AppPaths.folder(for: first.id).appendingPathComponent(name)
                print("  \(name): " + (AudioFiles.duration(of: url).map { String(format: "%.2f s", $0) } ?? "missing"))
            }
        } catch {
            print("FAILED: \(error.localizedDescription)")
        }
    }
}

extension Diagnostics {
    /// `Hootnote --pause-test <out.caf>`: 3 s of a 220 Hz sine fed in real time, with the writer paused for
    /// the middle second (as while waiting for a dropped call). The file must stay 3 s long, silent only there.
    static func pauseTest(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        let start = mach_absolute_time()
        guard let writer = try? AudioTrackWriter(url: url, startHostTime: start, label: "pause-test") else { print("writer failed"); return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames: AVAudioFrameCount = 480 // 10 ms
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        var phase = 0.0
        let began = Date()
        while Date().timeIntervalSince(began) < 3 {
            let t = Date().timeIntervalSince(began)
            writer.isPaused = t >= 1 && t < 2
            let p = buffer.floatChannelData![0]
            for k in 0..<Int(frames) { p[k] = Float(0.3 * sin(phase)); phase += 2 * .pi * 220 / 48_000 }
            writer.append(buffer, hostTime: mach_absolute_time())
            Thread.sleep(forTimeInterval: 0.01)
        }
        writer.finish()
        guard let file = try? AVAudioFile(forReading: url),
              let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: out)) != nil else { print("read failed"); return }
        let x = out.floatChannelData![0], n = Int(out.frameLength)
        let seconds = (0..<Int(Double(n) / 16_000 * 4)).map { q -> String in
            let range = (q * 4_000)..<min(n, (q + 1) * 4_000)
            let rms = (range.reduce(Float(0)) { $0 + x[$1] * x[$1] } / Float(max(1, range.count))).squareRoot()
            return rms > 0.05 ? "#" : "."
        }
        print(String(format: "length %.2f s (expect ~3.0); per 0.25 s: %@ (expect #### .... ####)", Double(n) / 16_000, seconds.joined()))
    }
}

extension Diagnostics {
    /// `Hootnote --undo-test <meeting id>`: every transcript edit undoes and redoes exactly, voiceprints included,
    /// and an outside change (Clean Up, re-transcribe) stops old undo steps from applying.
    static func undoTest(_ idString: String) {
        guard let id = UUID(uuidString: idString) else { print("bad id"); return }
        let state = AppState.shared
        guard let t0 = state.store.transcript(for: id) else { print("no transcript"); return }
        let v0 = state.voiceprints.voiceprints.map { "\($0.name):\($0.embeddings.count)" }.sorted()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let editor = TranscriptEditor(meetingID: id, state: state, undoManager: undo)
        func step(_ name: String, _ body: () -> Void) {
            undo.beginUndoGrouping(); body(); undo.endUndoGrouping()
            print("did \(name); undo menu says: \(undo.undoMenuItemTitle)")
        }
        let others = t0.speakers.filter { !$0.isMe }
        guard others.count >= 2, let me = t0.speakers.first(where: \.isMe),
              let para = t0.utterances.first(where: { $0.speakerID == others[0].id }) else { print("needs 2 remote speakers"); return }
        step("rename") { editor.rename(speaker: others[0].id, to: "Undo Test Person") }
        step("move") { editor.move(utterance: para.id, to: me.id) }
        step("edit") { editor.editText(utterance: para.id, to: para.text + " (edited)") }
        step("delete") { editor.deleteUtterance(t0.utterances[3].id) }
        step("merge") { editor.rename(speaker: others[1].id, to: "Undo Test Person") }
        let t1 = state.store.transcript(for: id)!
        let v1 = state.voiceprints.voiceprints.map { "\($0.name):\($0.embeddings.count)" }.sorted()
        state.route = .home
        var n = 0
        while undo.canUndo { undo.undo(); n += 1 }
        print("undo opened the meeting it changed: \(state.selectedMeetingID == id)")
        let back = state.store.transcript(for: id)!
        let vBack = state.voiceprints.voiceprints.map { "\($0.name):\($0.embeddings.count)" }.sorted()
        print("undid \(n) steps: transcript restored \(back.utterances == t0.utterances && back.speakers == t0.speakers), voiceprints restored \(vBack == v0)")
        n = 0
        while undo.canRedo { undo.redo(); n += 1 }
        let again = state.store.transcript(for: id)!
        let vAgain = state.voiceprints.voiceprints.map { "\($0.name):\($0.embeddings.count)" }.sorted()
        print("redid \(n) steps: transcript matches \(again.utterances == t1.utterances && again.speakers == t1.speakers), voiceprints match \(vAgain == v1)")
        while undo.canUndo { undo.undo() }
        // An outside change after an edit: the old step must not apply.
        step("rename again") { editor.rename(speaker: others[0].id, to: "Undo Test Person") }
        var changed = state.store.transcript(for: id)!
        changed.utterances.removeLast()
        state.store.saveTranscript(changed, for: id)
        UndoTarget.transcriptReplaced(id) // what Clean Up, Re-transcribe and joins do when they save
        print("after Clean Up or Re-transcribe, the Edit menu no longer offers the old step: \(!undo.canUndo)")
        state.store.saveTranscript(t0, for: id)
        state.voiceprints.unlearn(name: "Undo Test Person", embedding: others[0].embedding ?? [])
        let vEnd = state.voiceprints.voiceprints.map { "\($0.name):\($0.embeddings.count)" }.sorted()
        print("voiceprints back to start: \(vEnd == v0)")
    }
}

extension Diagnostics {
    /// `Hootnote --keys-test x`: ⌘← / ⌘→ go to a text box being typed in, and skip the audio otherwise.
    static func keysTest() {
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        field.string = "Steering committee kickoff"
        field.setSelectedRange(NSRange(location: 8, length: 0))
        let typing = TextKeys.handOver(#selector(NSResponder.moveToLeftEndOfLine(_:)), to: field, fromKeyboard: true)
        print("typing, ⌘←: handed to text box \(typing), cursor at \(field.selectedRange().location) (expected 0)")
        _ = TextKeys.handOver(#selector(NSResponder.moveToRightEndOfLine(_:)), to: field, fromKeyboard: true)
        print("typing, ⌘→: cursor at \(field.selectedRange().location) (expected \((field.string as NSString).length))")
        print("chosen from the menu with the mouse: skips audio \(!TextKeys.handOver(#selector(NSResponder.moveToLeftEndOfLine(_:)), to: field, fromKeyboard: false))")
        let paragraph = WordTextView(frame: .zero)
        paragraph.isEditable = false
        print("in a transcript paragraph (not editable): skips audio \(!TextKeys.handOver(#selector(NSResponder.moveToLeftEndOfLine(_:)), to: paragraph, fromKeyboard: true))")
        print("nothing focused: skips audio \(!TextKeys.handOver(#selector(NSResponder.moveToLeftEndOfLine(_:)), to: nil, fromKeyboard: true))")
        field.string = "Steering committee kickoff"
        field.setSelectedRange(NSRange(location: 9, length: 0))
        _ = TextKeys.handOver(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: field, fromKeyboard: true)
        print("typing, ⌘⌫: text is now \"\(field.string)\" (expected \"committee kickoff\")")
        var keys: [TranscriptKey] = []
        paragraph.onKey = { keys.append($0) }
        for code: UInt16 in [49, 126, 125] {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code) {
                paragraph.keyDown(with: e)
            }
        }
        print("keys from a clicked paragraph reach the player: \(keys) (expected playPause, previous, next)")
    }
}
