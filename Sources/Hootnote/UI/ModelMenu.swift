import SwiftUI

/// Chooses the ChatGPT or Claude model. Beside the Ask box and Write summary it picks the model for that
/// conversation or summary; in Settings › AI it sets the default. It lists what each connected service
/// offers right now, and fetches the lists again when it appears.
struct ModelMenu: View {
    /// The chosen model; nil means the default from Settings › AI.
    @Binding var selection: AIModelChoice?
    /// A caption-sized label beside a button; Settings uses the standard pop-up look.
    var compact = true

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    @ObservedObject private var claude = ClaudeAccount.shared
    @State private var hovering = false

    private var current: AIModelChoice? { selection ?? AIModels.defaultChoice }

    var body: some View {
        menu
            .task { await AIModels.refresh() }
    }

    @ViewBuilder private var menu: some View {
        if compact {
            Menu { items } label: {
                HStack(spacing: 4) {
                    Text(current?.name ?? "Model")
                        .foregroundStyle(hovering ? Theme.ink : Theme.inkSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .font(Theme.caption)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .help("Choose the model")
            .accessibilityLabel("Model, \(current?.name ?? "none")")
        } else {
            Menu(current?.name ?? "Model") { items }
                .fixedSize()
        }
    }

    @ViewBuilder private var items: some View {
        ForEach(AIModels.connected) { provider in
            let lists = AIModels.menu(provider)
            Section(provider.label) {
                if lists.main.isEmpty {
                    Text("Loading Models…")
                }
                ForEach(lists.main) { item($0) }
                if !lists.more.isEmpty {
                    Menu("More Models") {
                        ForEach(lists.more) { item($0) }
                    }
                }
            }
        }
    }

    private func item(_ choice: AIModelChoice) -> some View {
        Toggle(choice.name, isOn: Binding(get: { current == choice }, set: { if $0 { selection = choice } }))
    }
}
