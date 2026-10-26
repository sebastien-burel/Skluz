import SwiftUI
import SkluzCore

/// A tunnel run by skluzd: its state comes from the daemon's `status()`.
struct SystemTunnelRowView: View {
    let tunnel: TunnelConfig
    let status: TunnelStatus?
    let canManage: Bool
    let onToggleEnabled: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .help(stateLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.name).font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(status?.phase == .hostKeyChanged ? .red : .orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(tunnel.enabled ? "Désactiver" : "Activer", action: onToggleEnabled)
                .controlSize(.small)
                .disabled(!canManage)
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Éditer")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var dotColor: Color {
        guard tunnel.enabled else { return Color.gray.opacity(0.35) }
        if status?.forwardError != nil { return .orange }
        switch status?.phase {
        case .up:                              return .green
        case .starting:                        return .yellow
        case .reconnecting:                    return .orange
        case .failed, .hostKeyUnknown, .hostKeyChanged: return .red
        case .stopped, nil:                    return .secondary
        }
    }

    private var stateLabel: String {
        guard tunnel.enabled else { return "Désactivé" }
        switch status?.phase {
        case .up:              return "En cours"
        case .starting:        return "Démarrage…"
        case .reconnecting:    return "Reconnexion (\(status?.reconnections ?? 0) depuis le démarrage)…"
        case .failed:          return "Échec"
        case .hostKeyUnknown:  return "Clé d'hôte à approuver"
        case .hostKeyChanged:  return "Clé d'hôte modifiée"
        case .stopped, nil:    return "Arrêté"
        }
    }

    /// The error a user can act on, shown under the subtitle.
    private var warning: String? {
        guard tunnel.enabled else { return nil }
        switch status?.phase {
        case .hostKeyUnknown:
            return "Clé d'hôte à approuver : éditez le tunnel (étape 2)."
        case .hostKeyChanged:
            return "La clé du serveur a changé : vérifiez-la avant toute chose (attaque possible)."
        case .reconnecting, .failed:
            return status?.lastError
        case .up:
            return status?.forwardError
        default:
            return nil
        }
    }

    private var subtitle: String {
        let host = tunnel.user.map { "\($0)@\(tunnel.host)" } ?? tunnel.host
        return "-L \(tunnel.localPort):\(tunnel.remoteHost ?? "localhost"):\(tunnel.remotePort ?? tunnel.localPort)  •  \(host)"
    }
}
