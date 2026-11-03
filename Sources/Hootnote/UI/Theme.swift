import AppKit
import SwiftUI

/// Railway Timetable design tokens (see .impeccable/surfaces/sources-hootnote-ui.md).
/// White timetable stock and ink tabular figures; signal red only for what is live now;
/// route-line colours for apps and speakers. Every colour has a Dark Mode value.
enum Theme {
    // MARK: Colour

    static let ground = dynamic(light: 0xFFFFFF, dark: 0x141518)
    static let groundRaised = dynamic(light: 0xF6F7F9, dark: 0x1C1D21)
    static let ink = dynamic(light: 0x141518, dark: 0xF1F2F4)
    static let inkSecondary = dynamic(light: 0x50545C, dark: 0xA9ADB5, highContrast: (0x2E3036, 0xD3D6DC))
    static let inkTertiary = dynamic(light: 0x6B6F76, dark: 0x8A8E97, highContrast: (0x45484E, 0xB8BBC2)) // 5.0:1 / 5.3:1
    static let rule = dynamic(light: 0xE5E7EB, dark: 0x2C2E33, highContrast: (0x8A8E96, 0x6E727A))
    static let ruleStrong = dynamic(light: 0x141518, dark: 0xD9DBDF)

    /// Recording, live, and the now-line. Never decoration.
    static let signal = dynamic(light: 0xD91F17, dark: 0xFF5A50)
    /// The word being spoken: a deeper red than Signal so it holds 5.3:1 on its wash (Signal on the wash is 4.3:1).
    static let signalText = Color(nsColor: NS.signalText)
    /// Behind the word being spoken. Nowhere else.
    static let signalWash = Color(nsColor: NS.signalWash)
    /// Text on a signal-red tab: white on light, ground on dark (5.9:1; white on #FF5A50 is only 3.1:1).
    static let onSignal = dynamic(light: 0xFFFFFF, dark: 0x141518)
    /// Text on an amber fill (the HUD's Keep button).
    static let onCaution = dynamic(light: 0xFFFFFF, dark: 0x141518)
    static let ready = dynamic(light: 0x0B7A48, dark: 0x3CCB86)
    static let working = dynamic(light: 0x1C66C4, dark: 0x5AA2FF)
    static let caution = dynamic(light: 0x9A5C00, dark: 0xF2A93B)
    /// Search matches: an amber wash, distinct from signal red's "now".
    static let searchWash = Color(nsColor: NS.searchWash)
    /// The dictation pill is always a dark tab over whatever app you're in.
    static let pill = Color(nsColor: NSColor(hex: 0x141518))
    static let pillSignal = Color(nsColor: NSColor(hex: 0xFF5A50))

    /// Route-line colours for speakers (you are always ink).
    static let lines: [Color] = [
        dynamic(light: 0x1C66C4, dark: 0x5AA2FF),  // blue
        dynamic(light: 0x0F8A52, dark: 0x3CCB86),  // green
        dynamic(light: 0x7A3FB0, dark: 0xB78BE8),  // purple
        dynamic(light: 0xD06A00, dark: 0xF2A040),  // orange
        dynamic(light: 0x00828C, dark: 0x3CC4CC),  // teal
        dynamic(light: 0xB8336A, dark: 0xF07AA8),  // magenta
        dynamic(light: 0x6D5444, dark: 0xC2A48E),  // brown
        dynamic(light: 0x3B4BB5, dark: 0x8C98F0),  // indigo
    ]

    /// Route-line colours for call apps, close to each app's own identity.
    static func line(forApp appID: String?) -> Color {
        switch appID {
        case "zoom": return dynamic(light: 0x2D72E8, dark: 0x5C97FF)
        case "teams": return dynamic(light: 0x5059C9, dark: 0x8C93F0)
        case "chrome", "edge", "arc", "brave", "firefox", "safari": return dynamic(light: 0x00897B, dark: 0x3CC4B4)
        case "webex": return dynamic(light: 0x00A0D1, dark: 0x4CC8EE)
        case "slack": return dynamic(light: 0x611F69, dark: 0xC17FCB)
        case "facetime", "whatsapp": return dynamic(light: 0x1F9D3F, dark: 0x4CCB6A)
        case "manual": return ink
        case "import": return inkTertiary
        default: return inkSecondary
        }
    }

    // MARK: Type (SF Pro, tabular figures for every time and duration)

    static let timeLarge = Font.system(size: 20, weight: .semibold).monospacedDigit()
    static let timeRow = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let title = Font.system(size: 22, weight: .bold)
    static let section = Font.system(size: 17, weight: .bold)
    /// Column heads and state words set condensed, as timetables do.
    static let columnHead = Font.system(size: 11, weight: .semibold).width(.condensed)
    static let state = Font.system(size: 14, weight: .semibold).width(.condensed)
    static let body = Font.system(size: 14)
    static let bodyEmphasis = Font.system(size: 14, weight: .medium)
    static let caption = Font.system(size: 12)

    // MARK: Layout

    /// The one armature: the time column is this wide on Home, Meetings and in every transcript.
    static let timeColumn: CGFloat = 104
    static let gutter: CGFloat = 40

    // MARK: Motion

    /// State changes and appearances: a short ease-out, kept under Reduce Motion (it's a crossfade, not movement).
    static func quick(_ reduceMotion: Bool) -> Animation {
        .easeOut(duration: 0.18)
    }

    /// Movement (the travelling now-line, follow-along scrolling). Under Reduce Motion things update in place.
    static func travel(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    // MARK: Helpers

    /// A colour for light and dark, with optional stronger values for Increase Contrast.
    static func dynamic(light: UInt32, dark: UInt32, alpha: Double = 1,
                        highContrast: (light: UInt32, dark: UInt32)? = nil) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark, alpha: alpha, highContrast: highContrast))
    }

    /// The same tokens for AppKit text (the transcript paragraphs).
    enum NS {
        static let ink = dynamicNS(light: 0x141518, dark: 0xF1F2F4)
        static let signalText = dynamicNS(light: 0xBF1A12, dark: 0xFF5A50, highContrast: (0x9E140E, 0xFF8078))
        static let signal = dynamicNS(light: 0xD91F17, dark: 0xFF5A50)
        static let signalWash = dynamicNS(light: 0xD91F17, dark: 0xFF5A50, alpha: 0.16)
        static let searchWash = dynamicNS(light: 0xF2A93B, dark: 0xF2A93B, alpha: 0.32)
        static let body = NSFont.systemFont(ofSize: 14)
    }

    static func dynamicNS(light: UInt32, dark: UInt32, alpha: Double = 1,
                          highContrast: (light: UInt32, dark: UInt32)? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua,
                                                    .accessibilityHighContrastAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let isHigh = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            let hex = (isHigh ? highContrast.map { isDark ? $0.dark : $0.light } : nil) ?? (isDark ? dark : light)
            return NSColor(hex: hex, alpha: alpha)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// The timetable's heavy rule: 2 pt of ink heading every table.
struct TimetableRule: View {
    var body: some View { Rectangle().fill(Theme.ruleStrong).frame(height: 2) }
}

struct HairlineRule: View {
    var body: some View { Rectangle().fill(Theme.rule).frame(height: 1) }
}

/// A route dot: the "line" an app or speaker belongs to.
struct LineDot: View {
    let color: Color
    var size: CGFloat = 9
    var body: some View { Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true) }
}

/// The signature now-line: a red rule with the current time on a tab at its left end.
struct NowLine: View {
    let label: String
    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.onSignal)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Theme.signal, in: RoundedRectangle(cornerRadius: 3))
            Rectangle().fill(Theme.signal).frame(height: 2)
        }
        .accessibilityElement()
        .accessibilityLabel("Now, \(label)")
    }
}

/// Fixed state vocabulary: always these words, always this colour, always in the State column.
struct MeetingStateLabel: View {
    let meeting: Meeting
    var body: some View {
        switch meeting.status {
        case .recording:
            Label("Recording", systemImage: "record.circle.fill").foregroundStyle(Theme.signal)
        case .queued:
            Text("Waiting").foregroundStyle(Theme.inkTertiary)
        case .processing:
            Text("Transcribing").foregroundStyle(Theme.working)
        case .failed:
            Text("Failed").foregroundStyle(Theme.caution)
        case .ready:
            Text("Ready").foregroundStyle(Theme.ready)
        }
    }
}

extension Date {
    /// ("2:30", "PM") for the time column: large tabular hour and minute, small period.
    /// The period is empty in 24-hour locales.
    private static let timetableFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("h:mm a")
        return f
    }()

    var timetableParts: (time: String, period: String) {
        let f = Date.timetableFormatter
        let full = f.string(from: self)
        let period = [f.amSymbol, f.pmSymbol].compactMap { $0 }.first { full.contains($0) } ?? ""
        let time = period.isEmpty ? full : full.replacingOccurrences(of: period, with: "").trimmingCharacters(in: .whitespaces)
        return (time, period)
    }

    var timetableTime: String {
        let p = timetableParts
        return p.period.isEmpty ? p.time : "\(p.time) \(p.period)"
    }
}

/// Large tabular time with a small period, as set in the time column.
struct TimetableTime: View {
    let date: Date
    var font: Font = Theme.timeLarge
    var color: Color = Theme.ink

    var body: some View {
        let p = date.timetableParts
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(p.time).font(font)
            if !p.period.isEmpty {
                Text(p.period).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .foregroundStyle(color)
    }
}
