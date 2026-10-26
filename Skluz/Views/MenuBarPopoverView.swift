import SwiftUI
import SkluzCore

struct MenuBarPopoverView: View {
    let viewModel: TunnelsViewModel
    let system: SystemTunnelsModel
    var onSheetPresentationChange: (Bool) -> Void = { _ in }
    @State private var activeSheet: ActiveSheet?

    enum ActiveSheet: Identifiable {
        case create
        case edit(TunnelConfig)
        /// A Session tunnel opened in System mode, from the migration assistant.
        case convert(TunnelConfig)
        case logs(TunnelConfig)
        case preferences
        case migration

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let tunnel): "edit-\(tunnel.id.uuidString)"
            case .convert(let tunnel): "convert-\(tunnel.id.uuidString)"
            case .logs(let tunnel): "logs-\(tunnel.id.uuidString)"
            case .preferences: "preferences"
            case .migration: "migration"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let problem = system.status?.configProblem {
                configProblemBanner(problem)
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(width: 360)
        .sheet(item: $activeSheet) { sheet in
            view(for: sheet)
        }
        .onChange(of: activeSheet != nil) { _, isPresented in
            onSheetPresentationChange(isPresented)
        }
    }

    @ViewBuilder
    private func view(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .create:
            editor(for: nil)
        case .edit(let tunnel):
            editor(for: tunnel)
        case .convert(let tunnel):
            editor(for: tunnel, mode: .system)
        case .logs(let tunnel):
            LogViewerView(tunnel: tunnel, viewModel: viewModel)
        case .preferences:
            PreferencesView(system: system) { activeSheet = .migration }
        case .migration:
            MigrationView(sessionTunnels: viewModel.tunnels, system: system) { tunnel in
                activeSheet = .convert(tunnel)
            }
        }
    }

    private func editor(for tunnel: TunnelConfig?, mode: TunnelMode? = nil) -> some View {
        TunnelEditorView(
            initial: tunnel,
            initialMode: mode,
            configHosts: viewModel.configHosts,
            system: system,
            onSave: { saved in try await save(saved, replacing: tunnel) },
            onTest: { await viewModel.test($0) },
            onDelete: tunnel.map { original in
                { _ in Task { await delete(original) } }
            }
        )
    }

    /// A mode change moves the tunnel between the user file and the daemon.
    private func save(_ tunnel: TunnelConfig, replacing previous: TunnelConfig?) async throws {
        switch (previous?.mode, tunnel.mode) {
        case (.session?, .system):
            try await viewModel.handOverToSystem(tunnel) { try await system.upsert(tunnel) }
        case (_, .system):
            try await system.upsert(tunnel)
        case (.system?, .session):
            try await system.delete(id: tunnel.id)
            await viewModel.upsert(tunnel)
        case (_, .session):
            await viewModel.upsert(tunnel)
        }
    }

    private func delete(_ tunnel: TunnelConfig) async {
        switch tunnel.mode {
        case .system:  try? await system.delete(id: tunnel.id)
        case .session: await viewModel.remove(id: tunnel.id)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Skluz").font(.headline)
            Spacer()
            Button {
                activeSheet = .preferences
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Préférences")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func configProblemBanner(_ problem: String) -> some View {
        Label("Service système : configuration refusée, aucun tunnel Système lancé. \(problem)",
              systemImage: "exclamationmark.octagon.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.tunnels.isEmpty && system.tunnels.isEmpty {
            emptyState
        } else {
            tunnelList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Aucun tunnel").font(.headline)
            Text("Cliquez sur « Nouveau tunnel » pour commencer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
    }

    /// Without System tunnels the list is exactly the Session list of v1.
    private var tunnelList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !system.tunnels.isEmpty {
                    sectionHeader("Système — sans ouverture de session")
                    ForEach(Array(system.tunnels.enumerated()), id: \.element.id) { index, tunnel in
                        SystemTunnelRowView(
                            tunnel: tunnel,
                            status: system.status(for: tunnel.id),
                            canManage: system.canManage,
                            onToggleEnabled: {
                                Task { try? await system.setEnabled(id: tunnel.id, !tunnel.enabled) }
                            },
                            onEdit: { activeSheet = .edit(tunnel) }
                        )
                        if index < system.tunnels.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                    if !viewModel.tunnels.isEmpty {
                        sectionHeader("Session")
                    }
                }
                ForEach(Array(viewModel.tunnels.enumerated()), id: \.element.id) { index, tunnel in
                    let state = viewModel.states[tunnel.id] ?? .stopped
                    TunnelRowView(
                        tunnel: tunnel,
                        state: state,
                        onEdit: { activeSheet = .edit(tunnel) },
                        onToggle: { toggle(tunnel: tunnel, state: state) },
                        onShowLogs: { activeSheet = .logs(tunnel) }
                    )
                    if index < viewModel.tunnels.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxHeight: 400)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            popoverActionRow(label: "Nouveau tunnel", systemImage: "plus",
                             shortcut: KeyEquivalent("n")) {
                activeSheet = .create
            }
            Divider().padding(.leading, 12)
            popoverActionRow(label: "Quitter Skluz", systemImage: "power",
                             shortcut: KeyEquivalent("q")) {
                NSApp.terminate(nil)
            }
        }
    }

    private func toggle(tunnel: TunnelConfig, state: TunnelState) {
        switch state {
        case .running, .starting, .reconnecting:
            viewModel.stopTunnel(id: tunnel.id)
        case .stopped, .failed:
            viewModel.startTunnel(tunnel)
        }
    }

    private func popoverActionRow(
        label: String,
        systemImage: String,
        shortcut: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(shortcut, modifiers: .command)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
