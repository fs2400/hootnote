import AppKit
import SwiftUI

/// Everything you've dictated with the hotkey, newest first. Text only.
struct DictationsView: View {
    let query: String
    @EnvironmentObject var state: AppState
    @EnvironmentObject var dictations: DictationStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var access = AccessibilityWatcher.shared
    @State private var confirmClear = false

    var body: some View {
        let items = dictations.search(query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Dictations",
                               detail: items.isEmpty ? nil : "\(items.count) \(items.count == 1 ? "entry" : "entries")")
                if settings.dictationEnabled && !access.trusted {
                    HStack(spacing: 12) {
                        Text("Dictation needs Accessibility access to hear \(settings.dictationHotkey.keyName) and paste into other apps.")
                            .font(Theme.body).foregroundStyle(Theme.ink)
                        Spacer()
                        Button("Allow access…") { state.dictation.requestAccessibility() }
                    }
                    .padding(.vertical, 12)
                    HairlineRule()
                }
                if items.isEmpty {
                    Text(query.isEmpty
                         ? "Hold \(settings.dictationHotkey.keyName) in any app and speak. When you let go, the text is typed where your cursor is, and it's kept here so you can copy it again. Audio is never saved."
                         : "No dictations match “\(query)”.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: 620, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    TimetableRule()
                    ForEach(items) { DictationRow(dictation: $0, compact: false) }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 40)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Dictations")
        .toolbar {
            ToolbarItem {
                Button("Clear history…") { confirmClear = true }
                    .disabled(dictations.items.isEmpty)
            }
        }
        .confirmationDialog("Delete all dictations?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { dictations.deleteAll() }
        } message: {
            Text("This removes the text of every dictation. It can't be undone.")
        }
    }
}

struct DictationRow: View {
    let dictation: Dictation
    let compact: Bool
    @EnvironmentObject var dictations: DictationStore
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    TimetableTime(date: dictation.date)
                    if !Calendar.current.isDateInToday(dictation.date) {
                        Text(dictation.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(Theme.caption).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .frame(width: Theme.timeColumn, alignment: .leading)
                Text(dictation.text)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(compact ? 2 : nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 16)
                Text(dictation.appName)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? Theme.ready : Theme.inkSecondary)
                .help("Copy this dictation")
                .opacity(hovering || copied ? 1 : 0.8)
            }
            .padding(.vertical, 12)
            HairlineRule()
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { copy() }
            Divider()
            Button("Delete", role: .destructive) { dictations.delete(dictation.id) }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dictation.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
