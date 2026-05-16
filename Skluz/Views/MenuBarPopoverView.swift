import SwiftUI

struct MenuBarPopoverView: View {
    let viewModel: TunnelsViewModel
    var onEditorPresentationChange: (Bool) -> Void = { _ in }
    @State private var editorState: EditorState?

    enum EditorState: Identifiable {
        case create
        case edit(Tunnel)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let tunnel): tunnel.id.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 360)
        .sheet(item: $editorState) { state in
            editor(for: state)
        }
        .onChange(of: editorState != nil) { _, isPresented in
            onEditorPresentationChange(isPresented)
        }
    }

    @ViewBuilder
    private func editor(for state: EditorState) -> some View {
        switch state {
        case .create:
            TunnelEditorView(initial: nil) { tunnel in
                Task { await viewModel.upsert(tunnel) }
            }
        case .edit(let tunnel):
            TunnelEditorView(
                initial: tunnel,
                onSave: { saved in
                    Task { await viewModel.upsert(saved) }
                },
                onDelete: { id in
                    Task { await viewModel.remove(id: id) }
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Skluz").font(.headline)
            Spacer()
            Button {
                // TODO Phase 8 — PreferencesView
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Préférences")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.tunnels.isEmpty {
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

    private var tunnelList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.tunnels.enumerated()), id: \.element.id) { index, tunnel in
                    let state = viewModel.states[tunnel.id] ?? .stopped
                    TunnelRowView(
                        tunnel: tunnel,
                        state: state,
                        onEdit: { editorState = .edit(tunnel) },
                        onToggle: { toggle(tunnel: tunnel, state: state) }
                    )
                    if index < viewModel.tunnels.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxHeight: 400)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            popoverActionRow(label: "Nouveau tunnel", systemImage: "plus") {
                editorState = .create
            }
            Divider().padding(.leading, 12)
            popoverActionRow(label: "Quitter Skluz", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    private func toggle(tunnel: Tunnel, state: TunnelState) {
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
