import SwiftUI
import KandongKit

/// Where the text came from, which way it's read, and which Backend answered, on the glass.
struct PanelHeader: View {
    let model: AppModel
    let controller: ResultPanelController
    @Bindable var session: LookupSession

    var body: some View {
        HStack(spacing: 10) {
            Label(session.source.displayName, systemImage: session.source.symbolName)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            directionToken
            Spacer(minLength: 4)
            if session.analysis?.containsTraditional == true {
                Toggle("繁", isOn: $session.showTraditional)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Show the original Traditional characters")
                    .accessibilityLabel("Traditional characters")
            }
            if let analysis = session.analysis, analysis.hasChinese {
                Button { Speech.speak(analysis.source) } label: { Image(systemName: "speaker.wave.2") }
                    .buttonStyle(.borderless)
                    .help("Read the text aloud (Space)")
                    .accessibilityLabel("Read aloud")
            }
            BackendBadge(model: model, session: session)
            Button { controller.togglePin() } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(controller.isPinned ? "Unpin (P)" : "Pin: keep open when clicking elsewhere (P)")
            .accessibilityLabel("Pin")
            .accessibilityValue(controller.isPinned ? "On" : "Off")
        }
    }

    /// "中 → EN" or "EN → 中": a button when the text mixes both, so it can be read the other way.
    @ViewBuilder private var directionToken: some View {
        let label = session.direction == .learn ? "中 → EN" : "EN → 中"
        if session.canFlip {
            Button { model.flip(session) } label: {
                HStack(spacing: 4) {
                    Text(label)
                    Image(systemName: "arrow.left.arrow.right").imageScale(.small)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(session.direction == .learn ? "Say it all in Chinese instead (R, or look it up again)" : "Translate it into English instead (R, or look it up again)")
            .accessibilityLabel(session.direction == .learn ? "Reading Chinese into English. Switch to saying it in Chinese" : "Saying it in Chinese. Switch to translating into English")
        } else if session.direction == .reverse {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Saying English in Chinese")
                .accessibilityLabel("Saying it in Chinese")
        }
    }
}

/// Which Backend answered; click to ask another one or make this one the default.
private struct BackendBadge: View {
    let model: AppModel
    let session: LookupSession

    var body: some View {
        let isLocal = session.backendIsLocal
        let where_ = isLocal ? "Text stays on this Mac" : "Text is sent to \(session.backendLabel)"
        Menu {
            Section("Try with") {
                ForEach(model.settings.backends.filter { $0.id != session.backendID }) { config in
                    Button {
                        model.retry(session, with: config)
                    } label: {
                        let status = model.statuses[config.id]
                        Label(config.name + (status.map { $0.isReady ? "" : " — \($0.message)" } ?? ""),
                              systemImage: config.isOnDevice ? "desktopcomputer" : "cloud")
                    }
                    .disabled(model.statuses[config.id].map { !$0.isReady } ?? false)
                }
            }
            if model.settings.defaultBackendID != session.backendID, let config = model.settings.backend(id: session.backendID) {
                Button("Make \(config.name) the Default") { model.settings.defaultBackendID = config.id }
            }
            Button("AI Settings…") { AppDelegate.shared?.showMainWindow(tab: .ai) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isLocal ? "desktopcomputer" : "cloud")
                    .foregroundStyle(isLocal ? Color.green : Color.blue)
                Text(session.backend.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .frame(maxWidth: 160)
        .fixedSize(horizontal: false, vertical: true)
        .help("\(session.backendLabel) · \(where_). Click to try another Backend.")
        .accessibilityLabel("Answered by \(session.backend.name). \(where_)")
        .task { if model.statuses.isEmpty { await model.refreshStatuses() } }
    }
}
