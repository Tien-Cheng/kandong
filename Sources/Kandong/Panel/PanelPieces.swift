import SwiftUI
import KandongKit

/// The Translation: plain text on the sheet, right under the Reading it translates.
struct TranslationText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Translation: \(text)")
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct CopyButton: View {
    let text: String
    var label = "Copy"
    @ViewState private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .help("\(label) (⇧⌘C)")
    }
}

/// Why the AI couldn't answer, how to fix it, and which other Backends could answer instead.
struct FailureCard: View {
    let model: AppModel
    let session: LookupSession
    /// The Backend that failed.
    let config: BackendConfig
    let message: String

    var body: some View {
        let status = model.statuses[config.id]
        let alternatives = model.settings.backends.filter { $0.id != config.id && model.statuses[$0.id]?.isReady == true }
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(status.map { $0.isReady ? message : $0.message } ?? message)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Sheet.corrected)
            }
            HStack(spacing: 6) {
                if let fix = status?.fix {
                    Button(model.title(for: fix)) { model.perform(fix) }
                        .buttonStyle(.borderedProminent)
                }
                Button("AI Settings…") { AppDelegate.shared?.showMainWindow(tab: .ai) }
            }
            .controlSize(.small)
            if !alternatives.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or try with").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(alternatives) { config in
                            Button {
                                model.retry(session, with: config)
                            } label: {
                                Label(config.name, systemImage: config.isOnDevice ? "desktopcomputer" : "cloud")
                            }
                            .help(config.isOnDevice ? "Text stays on this Mac" : "Text is sent to \(config.name)")
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Sheet.corrected.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .task { await model.refreshStatuses() }
    }
}

/// A one-time question in the Result.
struct QuestionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
