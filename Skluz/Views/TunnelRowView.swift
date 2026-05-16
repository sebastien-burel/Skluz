import SwiftUI

struct TunnelRowView: View {
    let tunnel: Tunnel
    let state: TunnelState
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onShowLogs: () -> Void

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
            Button(toggleLabel, action: onToggle)
                .controlSize(.small)
                .disabled(!tunnel.enabled || isBusy)
            Button(action: onShowLogs) {
                Image(systemName: "text.alignleft")
            }
            .buttonStyle(.borderless)
            .help("Logs")
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
            .fill(dotColor)
            .frame(width: 9, height: 9)
            .help(stateLabel)
    }

    private var dotColor: Color {
        switch state {
        case .stopped: tunnel.enabled ? .secondary : Color.gray.opacity(0.35)
        case .starting: .yellow
        case .running: .green
        case .failed: .red
        case .reconnecting: .orange
        }
    }

    private var stateLabel: String {
        switch state {
        case .stopped:      tunnel.enabled ? "Arrêté" : "Désactivé"
        case .starting:     "Démarrage…"
        case .running:      "En cours"
        case .failed(let reason, _): "Échec : \(reason)"
        case .reconnecting(let n):   "Reconnexion (tentative \(n))…"
        }
    }

    private var toggleLabel: String {
        switch state {
        case .running, .starting, .reconnecting: "Stop"
        case .stopped, .failed:                  "Start"
        }
    }

    private var isBusy: Bool {
        switch state {
        case .starting, .reconnecting: true
        default: false
        }
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
