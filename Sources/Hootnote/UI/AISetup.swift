import SwiftUI

/// "Continue with ChatGPT": opens ChatGPT's sign-in page in the browser and waits for it to come back.
struct ChatGPTSignInButton: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var account = ChatGPTAccount.shared
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if account.signingIn {
                HStack(spacing: 10) {
                    Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                    Button("Cancel") { account.cancelSignIn() }
                }
            } else {
                Button("Continue with ChatGPT") {
                    error = nil
                    Task {
                        do {
                            try await account.signIn()
                            settings.aiProvider = .chatgpt
                        } catch ChatGPTError.cancelled {
                            // You stopped it, or ChatGPT's page ended without sending you back.
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.caution)
            }
        }
    }
}

/// Paste a Claude API key. Checks it with Claude before saving it.
struct ClaudeKeyField: View {
    var showsKeyLink = true
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var account = ClaudeAccount.shared
    @State private var key = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SecureField("Claude API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit(connect)
                Button(checking ? "Checking…" : "Connect", action: connect)
                    .disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if showsKeyLink {
                Link("Get a Claude API key", destination: ClaudeAccount.keysURL).font(.caption)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.caution)
            }
        }
    }

    private func connect() {
        guard !checking else { return }
        checking = true
        error = nil
        Task {
            do {
                try await account.connect(key: key)
                key = ""
                settings.aiProvider = .claude
            } catch {
                self.error = error.localizedDescription
            }
            checking = false
        }
    }
}

/// Shown on the Summary and Ask tabs until ChatGPT or Claude is set up.
struct AIConnectPrompt: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(Theme.body).foregroundStyle(Theme.inkSecondary)
            ChatGPTSignInButton()
            Text("Or use Claude:").font(Theme.body).foregroundStyle(Theme.inkSecondary).padding(.top, 4)
            ClaudeKeyField()
        }
    }
}

/// The first-launch window: connect ChatGPT or Claude, each as one row of the timetable.
struct AISetupSheet: View {
    /// Snapshots draw the window as someone who hasn't connected anything sees it.
    var previewDisconnected = false
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    @ObservedObject private var claude = ClaudeAccount.shared
    @Environment(\.dismiss) private var dismiss

    private var chatGPTConnected: Bool { !previewDisconnected && chatGPT.isSignedIn }
    private var claudeConnected: Bool { !previewDisconnected && claude.hasKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connect ChatGPT or Claude").font(Theme.title).foregroundStyle(Theme.ink)
            Text("Hootnote uses it to write meeting summaries and answer questions about your meetings.")
                .font(Theme.body)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 22)
            TimetableRule()
            row("ChatGPT", connected: chatGPTConnected) {
                if chatGPTConnected {
                    Text(chatGPT.email.map { "Signed in as \($0)." } ?? "Signed in.")
                        .font(Theme.body).foregroundStyle(Theme.inkSecondary)
                } else {
                    Text("Use your ChatGPT Plus or Pro plan.").font(Theme.body).foregroundStyle(Theme.inkSecondary)
                    ChatGPTSignInButton().padding(.top, 6)
                }
            }
            row("Claude", connected: claudeConnected) {
                if claudeConnected {
                    Text("API key saved.").font(Theme.body).foregroundStyle(Theme.inkSecondary)
                } else {
                    Text("Use a Claude API key. Max, Ultra, and Team plans include monthly API credits for it.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 10) {
                        step(1) {
                            Text("On claude.ai, open \(Text("Billing").fontWeight(.semibold)) and click \(Text("Link organization").fontWeight(.semibold)).")
                        }
                        step(2) {
                            Link(destination: ClaudeAccount.keysURL) {
                                Text("Create a key in the Claude Console \(Image(systemName: "arrow.up.right"))").underline()
                            }
                        }
                        step(3) {
                            ClaudeKeyField(showsKeyLink: false)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            HStack {
                Button("Set Up Later") { dismiss() }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(chatGPTConnected || claudeConnected))
            }
            .controlSize(.large)
            .padding(.top, 22)
        }
        .padding(32)
        .frame(width: 640)
        .background(Theme.ground)
        .tint(Theme.ink)
    }

    private func row<Content: View>(_ name: String, connected: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(name)
                    .font(Theme.section)
                    .foregroundStyle(Theme.ink)
                    .frame(width: Theme.timeColumn, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) { content() }
                Spacer(minLength: 16)
                if connected {
                    Text("Connected").font(Theme.state).foregroundStyle(Theme.ready)
                }
            }
            .padding(.vertical, 18)
            HairlineRule()
        }
    }

    private func step<Content: View>(_ n: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(Theme.timeRow)
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 14, alignment: .leading)
            content().font(Theme.body).foregroundStyle(Theme.ink)
        }
    }
}
