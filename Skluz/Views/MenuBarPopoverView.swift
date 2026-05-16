import SwiftUI

struct MenuBarPopoverView: View {
    private let tunnels: [FakeTunnel] = [
        FakeTunnel(name: "prod-postgres", state: .running),
        FakeTunnel(name: "staging-redis", state: .stopped),
        FakeTunnel(name: "dev-bastion", state: .failed)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tunnelList
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Skluz").font(.headline)
            Spacer()
            Button {
                // TODO Phase 8 — ouvrir PreferencesView
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Préférences")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var tunnelList: some View {
        VStack(spacing: 0) {
            ForEach(Array(tunnels.enumerated()), id: \.element.id) { index, tunnel in
                TunnelRowView(tunnel: tunnel)
                if index < tunnels.count - 1 {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            popoverActionRow(label: "Nouveau tunnel", systemImage: "plus") {
                // TODO Phase 4 — ouvrir TunnelEditorView
            }
            Divider().padding(.leading, 12)
            popoverActionRow(label: "Quitter Skluz", systemImage: "power") {
                NSApp.terminate(nil)
            }
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

#Preview {
    MenuBarPopoverView()
}
