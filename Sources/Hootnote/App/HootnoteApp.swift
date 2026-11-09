import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        Migration.run()
        // Hidden diagnostic: `Hootnote --selftest <folder with mic.caf + system.caf> [model]`
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--selftest" {
            let model = args.count > 3 ? TranscriptionModel(rawValue: args[3]) ?? .whisperTurbo : .whisperTurbo
            Task {
                await SelfTest.run(folder: URL(fileURLWithPath: args[2]), model: model)
                exit(0)
            }
            dispatchMain()
        }
        if args.count >= 3, ["--export", "--import-test", "--ask-test", "--aec-analyze", "--cleanup-test", "--timing-test", "--process", "--clean-up", "--rebuild-playback", "--writer-test", "--paragraph-test", "--join-test", "--pause-test", "--undo-test", "--keys-test", "--summary-test"].contains(args[1]) {
            let arg = args[2]
            Task { @MainActor in
                switch args[1] {
                case "--export": Diagnostics.export(to: URL(fileURLWithPath: arg))
                case "--import-test": await Diagnostics.importTest(URL(fileURLWithPath: arg))
                case "--aec-analyze": await Diagnostics.aecAnalyze(URL(fileURLWithPath: arg))
                case "--cleanup-test": await Diagnostics.cleanupTest(URL(fileURLWithPath: arg))
                case "--timing-test": await Diagnostics.timingTest(URL(fileURLWithPath: arg))
                case "--process": await Diagnostics.runQueue(arg, cleanUp: false)
                case "--clean-up": await Diagnostics.runQueue(arg, cleanUp: true)
                case "--rebuild-playback": await Diagnostics.rebuildPlayback(arg)
                case "--writer-test": Diagnostics.writerTest(URL(fileURLWithPath: arg))
                case "--paragraph-test": Diagnostics.paragraphTest()
                case "--undo-test": Diagnostics.undoTest(arg)
                case "--keys-test": Diagnostics.keysTest()
                case "--join-test": await Diagnostics.joinTest(arg)
                case "--pause-test": Diagnostics.pauseTest(URL(fileURLWithPath: arg))
                case "--summary-test": await Diagnostics.summaryTest(arg)
                default: await Diagnostics.askTest(arg)
                }
                exit(0)
            }
            dispatchMain()
        }
        if args.count >= 2, ["--stop-reasons", "--stop-test"].contains(args[1]) {
            Task { @MainActor in
                if args[1] == "--stop-reasons" {
                    Diagnostics.stopReasons(args.count > 2 ? Int(args[2]) ?? 20 : 20)
                } else {
                    await Diagnostics.stopTest(args.count > 2 ? args[2] : "run")
                }
                exit(0)
            }
            dispatchMain()
        }
        if args.count >= 3, args[1] == "--snapshot" {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            MainActor.assumeIsolated { Snapshot.run(to: URL(fileURLWithPath: args[2])) }
            exit(0)
        }
        HootnoteApp.main()
    }
}

struct HootnoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Hootnote", id: "main") {
            MainView()
                .environmentObject(state)
                .environmentObject(state.store)
                .environmentObject(state.settings)
                .environmentObject(state.voiceprints)
                .environmentObject(state.processor)
                .environmentObject(state.dictations)
                .frame(minWidth: 1080, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(state.isRecording ? "Stop Recording" : "Record In Person") {
                    if state.isRecording { state.stopRecording(.manual(from: "File › Stop Recording or ⇧⌘R")) } else { state.startManualRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Upload Audio…") { state.chooseFilesToImport() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            MeetingCommands()
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(state.store)
                .environmentObject(state.settings)
                .environmentObject(state.processor)
                .environmentObject(state.dictations)
        } label: {
            MenuBarLabel(state: state, processor: state.processor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.store)
                .environmentObject(state.settings)
                .environmentObject(state.voiceprints)
                .environmentObject(state.processor)
                .environmentObject(state.detector)
                .environmentObject(state.dictations)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.bootstrap() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppState.shared.openMainWindow?() } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let state = AppState.shared
            guard state.isRecording else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "A call is being recorded"
            alert.informativeText = "Quitting stops the recording. What's been recorded so far is kept and transcribed next time Hootnote opens."
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            state.stopRecording(.quit)
            return .terminateNow
        }
    }
}
