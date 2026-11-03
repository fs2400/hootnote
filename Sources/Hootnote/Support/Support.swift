import AppKit
import Foundation
import os

let log = Logger(subsystem: "com.local.Hootnote", category: "app")

enum AppPaths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Hootnote", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var meetings: URL {
        // The --join-test diagnostic works on copies in another folder.
        let url = ProcessInfo.processInfo.environment["HOOTNOTE_MEETINGS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? appSupport.appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var voiceprints: URL { appSupport.appendingPathComponent("voiceprints.json") }

    static var defaultExportFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meeting Transcripts", isDirectory: true)
    }

    static func folder(for meetingID: UUID) -> URL {
        meetings.appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }
}

extension TimeInterval {
    /// 75 -> "1:15", 3725 -> "1:02:05"
    var clockString: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 75 -> "1 min", 3725 -> "1 hr 2 min"
    var durationString: String {
        let minutes = Int((self / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    /// Time left on a countdown: 15 -> "15 s", 161 -> "2:41" (never negative).
    var countdownString: String {
        let seconds = max(0, Int(rounded()))
        return seconds < 60 ? "\(seconds) s" : TimeInterval(seconds).clockString
    }

    /// SRT timestamp "00:01:15,250"
    var srtString: String {
        let ms = Int((self * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}

extension String {
    /// Lowercased, punctuation-stripped form used for fuzzy word comparison.
    var normalizedWord: String {
        lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    var sanitizedFileName: String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }

    var initials: String {
        let parts = split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

enum Cosine {
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == first.count {
            for i in 0..<v.count { sum[i] += v[i] }
        }
        let n = Float(vectors.count)
        return sum.map { $0 / n }
    }
}
