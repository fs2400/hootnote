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
            Link("Get a Claude API key", destination: ClaudeAccount.keysURL).font(.caption)
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
