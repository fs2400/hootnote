import AVFoundation
import AppKit
import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case word, pdf, markdown, text, srt
    var id: String { rawValue }
    var label: String {
        switch self {
        case .word: return "Word document (.docx)"
        case .pdf: return "PDF"
        case .markdown: return "Markdown (.md)"
        case .text: return "Plain text (.txt)"
        case .srt: return "Subtitles (.srt)"
        }
    }
    var fileExtension: String {
        switch self {
        case .word: return "docx"
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .text: return "txt"
        case .srt: return "srt"
        }
    }
    var isRichDocument: Bool { self == .word || self == .pdf }
}

enum Exporter {
    static func render(_ format: ExportFormat, meeting: Meeting, transcript: Transcript, summary: MeetingSummary?) -> String {
        switch format {
        case .markdown: return markdown(meeting: meeting, transcript: transcript, summary: summary)
        case .text, .word, .pdf: return text(meeting: meeting, transcript: transcript)
        case .srt: return srt(transcript: transcript)
        }
    }

    /// Writes any export format to `url`. Word and PDF carry speaker names and timestamps as styled text.
    @MainActor
    static func write(_ format: ExportFormat, meeting: Meeting, transcript: Transcript, summary: MeetingSummary?,
                      to url: URL) throws {
        switch format {
        case .word:
            let doc = RichDocument.build(meeting: meeting, transcript: transcript, summary: summary, family: "Arial")
            let data = try doc.data(from: NSRange(location: 0, length: doc.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url, options: .atomic)
        case .pdf:
            let doc = RichDocument.build(meeting: meeting, transcript: transcript, summary: summary, family: "Helvetica Neue")
            try RichDocument.writePDF(doc, to: url)
        default:
            try render(format, meeting: meeting, transcript: transcript, summary: summary)
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func fileName(for meeting: Meeting, format: ExportFormat) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "\(f.string(from: meeting.startedAt)) \(meeting.title.sanitizedFileName).\(format.fileExtension)"
    }

    static func markdown(meeting: Meeting, transcript: Transcript, summary: MeetingSummary?) -> String {
        var out = "# \(meeting.title)\n\n"
        out += "- **Date:** \(meeting.startedAt.formatted(date: .complete, time: .shortened))\n"
        out += "- **Length:** \(meeting.duration.durationString)\n"
        out += "- **App:** \(meeting.appName)\n"
        out += "- **Speakers:** \(transcript.speakers.map(\.name).joined(separator: ", "))\n\n"
        if let summary {
            out += summary.markdown + "\n\n"
        }
        out += "## Transcript\n\n"
        for u in transcript.utterances {
            out += "**\(transcript.speakerName(u.speakerID))** · \(u.start.clockString)\n\n\(u.text)\n\n"
        }
        return out
    }

    static func text(meeting: Meeting, transcript: Transcript) -> String {
        var out = "\(meeting.title)\n\(meeting.startedAt.formatted(date: .complete, time: .shortened)) · \(meeting.duration.durationString)\n\n"
        for u in transcript.utterances {
            out += "\(transcript.speakerName(u.speakerID))  \(u.start.clockString)\n\(u.text)\n\n"
        }
        return out
    }

    /// One cue per sentence-sized slice (max ~7 s) so subtitles stay readable.
    static func srt(transcript: Transcript) -> String {
        var cues: [(Double, Double, String)] = []
        for u in transcript.utterances {
            let name = transcript.speakerName(u.speakerID)
            var words: [Word] = []
            for w in u.words {
                words.append(w)
                let span = (words.last?.end ?? 0) - (words.first?.start ?? 0)
                if span > 7 || (w.text.last.map { ".?!".contains($0) } ?? false) {
                    cues.append((words.first!.start, words.last!.end, "\(name): " + words.map(\.text).joined(separator: " ")))
                    words = []
                }
            }
            if let first = words.first, let last = words.last {
                cues.append((first.start, last.end, "\(name): " + words.map(\.text).joined(separator: " ")))
            }
        }
        return cues.enumerated().map { i, c in
            "\(i + 1)\n\(c.0.srtString) --> \(max(c.1, c.0 + 0.5).srtString)\n\(c.2)\n"
        }.joined(separator: "\n")
    }

    /// Writes (or overwrites) the meeting's Markdown into the export folder.
    @discardableResult
    /// The Markdown files auto-export wrote for a meeting (found by the marker at their end).
    static func autoExports(of id: UUID, in folder: URL) -> [URL] {
        let marker = id.uuidString
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { url in
            guard url.pathExtension == "md", let tail = try? String(contentsOf: url, encoding: .utf8).suffix(80) else { return false }
            return tail.contains("hootnote:\(marker)") || tail.contains("meetingscribe:\(marker)")
        }
    }

    static func autoExport(meeting: Meeting, transcript: Transcript, summary: MeetingSummary?, folder: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Remove an earlier export of this meeting (the title may have changed since).
            for url in autoExports(of: meeting.id, in: folder) {
                try? FileManager.default.removeItem(at: url)
            }
            let marker = meeting.id.uuidString
            let url = folder.appendingPathComponent(fileName(for: meeting, format: .markdown))
            let body = markdown(meeting: meeting, transcript: transcript, summary: summary)
                + "\n<!-- hootnote:\(marker) -->\n"
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            log.error("Auto-export failed: \(error.localizedDescription)")
            return nil
        }
    }
}

enum AudioFiles {
    enum WriteError: LocalizedError {
        case buffer
        var errorDescription: String? { "Couldn't allocate an audio buffer." }
    }

    /// Writes 16 kHz float channels as AAC. One channel per array, all the same length.
    /// Used for the stereo master (channel 1 = you, channel 2 = the call) and per-track playback files.
    static func writeAAC(channels: [[Float]], to url: URL, sampleRate: Double = 16_000, bitRatePerChannel: Int = 32_000) throws {
        try? FileManager.default.removeItem(at: url)
        let count = channels.map(\.count).min() ?? 0
        let n = AVAudioChannelCount(channels.count)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: n,
            AVEncoderBitRateKey: bitRatePerChannel * Int(n),
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)),
              let data = buffer.floatChannelData else { throw WriteError.buffer }
        var position = 0
        while position < count {
            let frames = min(block, count - position)
            for c in 0..<Int(n) {
                channels[c].withUnsafeBufferPointer { src in
                    data[c].update(from: src.baseAddress! + position, count: frames)
                }
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            position += frames
        }
    }

    /// Writes to a temporary file first, so a failure never leaves a half-written file in place.
    static func replaceAAC(channels: [[Float]], at url: URL, bitRatePerChannel: Int = 32_000) throws {
        let temp = url.deletingPathExtension().appendingPathExtension("new.m4a")
        try writeAAC(channels: channels, to: temp, bitRatePerChannel: bitRatePerChannel)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }

    /// A run of samples, or of silence, in a mono track written end to end.
    enum Piece {
        case samples([Float])
        case silence(Int)
    }

    /// Writes 16 kHz mono pieces end to end as AAC, through a temporary file like `replaceAAC(channels:)`.
    /// Silence is written block by block, so a long gap costs no memory.
    static func replaceAAC(pieces: [Piece], at url: URL, bitRate: Int) throws {
        let temp = url.deletingPathExtension().appendingPathExtension("new.m4a")
        try? FileManager.default.removeItem(at: temp)
        try writeAAC(pieces: pieces, to: temp, bitRate: bitRate)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }

    private static func writeAAC(pieces: [Piece], to url: URL, bitRate: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)),
              let data = buffer.floatChannelData?[0] else { throw WriteError.buffer }
        for piece in pieces {
            switch piece {
            case .samples(let samples):
                var position = 0
                while position < samples.count {
                    let frames = min(block, samples.count - position)
                    samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress! + position, count: frames) }
                    buffer.frameLength = AVAudioFrameCount(frames)
                    try file.write(from: buffer)
                    position += frames
                }
            case .silence(let count):
                var remaining = max(0, count)
                data.update(repeating: 0, count: block)
                while remaining > 0 {
                    let frames = min(block, remaining)
                    buffer.frameLength = AVAudioFrameCount(frames)
                    try file.write(from: buffer)
                    remaining -= frames
                }
            }
        }
    }

    /// Duration of an audio file in seconds (nil if unreadable).
    static func duration(of url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }
}

/// Styled transcript for Word and PDF: title, details, summary, then each paragraph under its
/// speaker's name and timestamp.
enum RichDocument {
    static func build(meeting: Meeting, transcript: Transcript, summary: MeetingSummary?, family: String) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        let ink = NSColor(hex: 0x141518), gray = NSColor(hex: 0x5B5F68)

        func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
            let base = NSFont(name: family, size: size) ?? .systemFont(ofSize: size)
            return bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        }
        func style(before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0, head: CGFloat? = nil) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.headIndent = head ?? indent
            p.firstLineHeadIndent = indent
            p.lineHeightMultiple = 1.15
            return p
        }
        func add(_ text: String, _ f: NSFont, _ color: NSColor = ink, _ p: NSParagraphStyle) {
            doc.append(NSAttributedString(string: text + "\n", attributes: [.font: f, .foregroundColor: color, .paragraphStyle: p]))
        }

        add(meeting.title, font(20, bold: true), ink, style(after: 4))
        let details = [meeting.startedAt.formatted(date: .complete, time: .shortened), meeting.duration.durationString,
                       MeetingApps.name(for: meeting.appID)].joined(separator: "  ·  ")
        add(details, font(10), gray, style(after: 2))
        add("Speakers: " + transcript.speakers.map(\.name).joined(separator: ", "), font(10), gray, style(after: 14))

        if let summary {
            for raw in summary.markdown.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                if line.isEmpty { continue }
                if line.hasPrefix("#") {
                    let heading = line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                    add(heading, font(13, bold: true), ink, style(before: 10, after: 4))
                } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                    add("☐  " + line.dropFirst(6), font(11), ink, style(after: 3, indent: 0, head: 18))
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    add("•  " + line.dropFirst(2), font(11), ink, style(after: 3, indent: 0, head: 14))
                } else {
                    add(line, font(11), ink, style(after: 6))
                }
            }
        }

        add("Transcript", font(13, bold: true), ink, style(before: 16, after: 8))
        for u in transcript.utterances {
            let head = NSMutableAttributedString(string: transcript.speakerName(u.speakerID),
                                                 attributes: [.font: font(10.5, bold: true), .foregroundColor: ink])
            head.append(NSAttributedString(string: "   " + u.start.clockString,
                                           attributes: [.font: font(10), .foregroundColor: gray]))
            head.append(NSAttributedString(string: "\n"))
            head.addAttribute(.paragraphStyle, value: style(before: 6, after: 1), range: NSRange(location: 0, length: head.length))
            doc.append(head)
            add(u.text, font(11), ink, style(after: 6))
        }
        return doc
    }

    @MainActor
    static func writePDF(_ doc: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792) // US Letter
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 60
        info.rightMargin = 60
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.isEditable = false
        view.isVerticallyResizable = true
        view.textContainerInset = .zero
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(doc)
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.frame.size.height = ceil(layout.usedRect(for: container).height) + 4
        }
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw CoreAudioError.status("Writing the PDF", -1) }
    }
}
