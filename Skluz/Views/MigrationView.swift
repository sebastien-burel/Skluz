import SwiftUI
import SkluzCore

/// Lists the Session tunnels and offers to move to System mode those that
/// must survive a reboot without any session (`PLAN_SKLUZD.md` phase 6).
struct MigrationView: View {
    let sessionTunnels: [TunnelConfig]
    let system: SystemTunnelsModel
    let onConvert: (TunnelConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Passer des tunnels en mode Système").font(.headline)
                Text("Un tunnel Système est ouvert par le service dès le démarrage du Mac, sans session. "
                     + "Il lui faut une clé dédiée et une clé d'hôte approuvée : l'éditeur vous guide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let reason = system.unavailableReason {
                    Label(reason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)

            Divider()
            if eligible.isEmpty {
                Text("Aucun tunnel Session ne peut passer en Système : seuls les tunnels locaux (-L) sont pris en charge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                List(eligible) { tunnel in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tunnel.name)
                            Text("-L \(tunnel.localPort):\(tunnel.remoteHost ?? "?"):\(tunnel.remotePort ?? 0)  •  \(tunnel.host)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Passer en Système…") { onConvert(tunnel) }
                            .controlSize(.small)
                            .disabled(!system.canManage)
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 400)
    }

    /// System mode only runs local forwards.
    private var eligible: [TunnelConfig] {
        sessionTunnels.filter { $0.type == .localForward }
    }
}
