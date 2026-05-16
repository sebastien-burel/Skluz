import SwiftUI

struct TunnelRowView: View {
    let tunnel: Tunnel
    let onEdit: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            stateDot
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.name).font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Start", action: onToggle)
                .controlSize(.small)
                .disabled(true)
                .help("Démarrage : disponible à partir de la Phase 5")
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Éditer")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var stateDot: some View {
        Circle()
            .fill(tunnel.enabled ? Color.secondary : Color.gray.opacity(0.35))
            .frame(width: 9, height: 9)
            .help(tunnel.enabled ? "Activé (arrêté)" : "Désactivé")
    }

    private var subtitle: String {
        let host = tunnel.sshUser.map { "\($0)@\(tunnel.sshHost)" } ?? tunnel.sshHost
        switch tunnel.type {
        case .localForward:
            return "-L \(tunnel.localPort):\(tunnel.remoteHost ?? "?"):\(tunnel.remotePort ?? 0)  •  \(host)"
        case .remoteForward:
            return "-R \(tunnel.localPort):\(tunnel.remoteHost ?? "?"):\(tunnel.remotePort ?? 0)  •  \(host)"
        case .dynamic:
            return "-D \(tunnel.localPort)  •  \(host)"
        }
    }
}
