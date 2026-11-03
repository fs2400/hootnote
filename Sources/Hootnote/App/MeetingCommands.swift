import AppKit
import SwiftUI

/// Playback, Meeting and View menus for the meeting on screen, so every action has a menu item
/// and a keyboard shortcut, not just a button or a right-click.
/// ⌘← and ⌘→ skip the audio and ⌘⌫ deletes the meeting, but in a text box (a title, the Ask question, a
/// speaker's name, search, an edited paragraph) they move the cursor to the start or end of the line, or
/// delete back to it, as everywhere on the Mac.
/// Menu shortcuts are matched before the text box sees the key, so the skip hands the key back.
@MainActor
enum TextKeys {
    /// - Returns: true when you're typing and the text box handled the key instead.
    static func handOver(_ selector: Selector) -> Bool {
        handOver(selector, to: NSApp.keyWindow?.firstResponder, fromKeyboard: NSApp.currentEvent?.type == .keyDown)
    }

    /// Chosen from the menu with the mouse, or with nothing being typed: the audio skips.
    static func handOver(_ selector: Selector, to responder: NSResponder?, fromKeyboard: Bool) -> Bool {
        guard fromKeyboard, let text = responder as? NSTextView, text.isEditable else { return false }
        text.doCommand(by: selector)
        return true
    }
}

struct MeetingCommands: Commands {
    @FocusedValue(\.meetingActions) private var meeting

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") { meeting?.playPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(meeting?.canPlay != true)
            Button("Back 15 Seconds") {
                if !TextKeys.handOver(#selector(NSResponder.moveToLeftEndOfLine(_:))) { meeting?.back() }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(meeting?.canPlay != true)
            Button("Forward 15 Seconds") {
                if !TextKeys.handOver(#selector(NSResponder.moveToRightEndOfLine(_:))) { meeting?.forward() }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(meeting?.canPlay != true)
            Divider()
            Button("Previous Paragraph") { meeting?.previousParagraph() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(meeting?.canPlay != true)
            Button("Next Paragraph") { meeting?.nextParagraph() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(meeting?.canPlay != true)
        }

        CommandMenu("Meeting") {
            Menu("Export") {
                ForEach(ExportFormat.allCases) { format in
                    Button("\(format.label)…") { meeting?.export(format) }
                }
            }
            .disabled(meeting?.canPlay != true)
            Button("Export as Word…") { meeting?.export(.word) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(meeting?.canPlay != true)
            Divider()
            Button("Clean Up Transcript") { meeting?.cleanUp() }
                .disabled(meeting?.canPlay != true || meeting?.isJoining == true)
            Button("Restore Original Transcript…") { meeting?.restoreOriginal?() }
                .disabled(meeting?.restoreOriginal == nil)
            Button("Re-transcribe…") { meeting?.retranscribe() }
                .disabled(meeting == nil || meeting?.isJoining == true)
            Button("Join with Previous Meeting…") { meeting?.joinWithPrevious?() }
                .disabled(meeting?.joinWithPrevious == nil)
            Button("Delete Meeting…") {
                // While typing, ⌘⌫ deletes back to the start of the line instead.
                if !TextKeys.handOver(#selector(NSResponder.deleteToBeginningOfLine(_:))) { meeting?.delete() }
            }
            .keyboardShortcut(.delete, modifiers: .command)
                .disabled(meeting == nil || meeting?.isJoining == true)
        }

        CommandGroup(after: .toolbar) {
            Button("Transcript") { meeting?.showTab("Transcript") }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(meeting?.canPlay != true)
            Button("Summary") { meeting?.showTab("Summary") }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(meeting?.canPlay != true)
            Button("Ask") { meeting?.showTab("Ask") }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(meeting?.canPlay != true)
        }
    }
}
