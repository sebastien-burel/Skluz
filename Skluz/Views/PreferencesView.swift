import SwiftUI
import ServiceManagement
import SkluzCore

struct PreferencesView: View {
    let system: SystemTunnelsModel
    var onOpenMigration: () -> Void = {}
    @State private var status: SMAppService.Status = LaunchAtLoginManager.status
    @State private var errorMessage: String?
    @State private var daemonStatus: SMAppService.Status = DaemonManager.status
    @State private var daemonError: String?
    @State private var installationProblem: InstallationCheck.Problem? = DaemonManager.installationProblem
    @State private var cliInstalled = false
    @Environment(\.dismiss) private var dismiss

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: { newValue in
                do {
                    try LaunchAtLoginManager.setEnabled(newValue)
                    errorMessage = nil
                } catch {
                    errorMessage = "Échec : \(error.localizedDescription)"
                }
                status = LaunchAtLoginManager.status
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Démarrage") {
                    Toggle("Lancer Skluz à l'ouverture de session", isOn: launchAtLogin)

                    if status == .requiresApproval {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                "Approbation requise dans Réglages Système → Général → Ouverture.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            Button("Ouvrir les Réglages Système") {
                                LaunchAtLoginManager.openLoginItemsSettings()
                            }
                            .controlSize(.small)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Service système (sans ouverture de session)") {
                    Text("Ouvre les tunnels Système dès le démarrage du Mac, même sans session ouverte.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("État", value: DaemonManager.describe(daemonStatus))
                    if let daemonVersion = system.status?.version {
                        LabeledContent("Version du service") {
                            if daemonVersion == shortVersion {
                                Text(daemonVersion)
                            } else {
                                Text("\(daemonVersion) — différente de l'app (\(shortVersion)) : désactivez puis réactivez le service.")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    if !DaemonManager.isInstalledInApplications {
                        Label(DaemonManager.Failure.notInApplications.localizedDescription,
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if DaemonManager.isInstalledInApplications, let problem = installationProblem {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(problem.message, systemImage: "lock.trianglebadge.exclamationmark")
                                .foregroundStyle(.orange)
                            Text("Dans le Terminal :")
                                .foregroundStyle(.secondary)
                            Text(problem.fixCommand)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    }

                    if daemonStatus == .requiresApproval {
                        Label(
                            "Autorisez « Skluz » dans Réglages Système → Général → Ouverture et extensions → "
                                + "Autoriser en arrière-plan.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    HStack {
                        switch daemonStatus {
                        case .enabled, .requiresApproval:
                            Button("Désactiver") { runDaemonAction(DaemonManager.unregister) }
                        default:
                            Button("Activer") { runDaemonAction(DaemonManager.register) }
                                .disabled(installationProblem != nil)
                        }
                        if daemonStatus == .requiresApproval {
                            Button("Ouvrir les réglages") { DaemonManager.openSettings() }
                        }
                    }
                    .controlSize(.small)
                    // The service is tied to the bundle ID, not the location:
                    // only the installed copy may manage it.
                    .disabled(!DaemonManager.isInstalledInApplications)

                    if let daemonError {
                        Text(daemonError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if daemonStatus == .enabled {
                        LabeledContent("Commande skluz") {
                            if system.isCommandLineToolInstalled || cliInstalled {
                                Text("/usr/local/bin/skluz").font(.caption.monospaced())
                            } else {
                                Button("Installer dans /usr/local/bin") { installCommandLineTool() }
                                    .controlSize(.small)
                                    .disabled(!system.canManage)
                            }
                        }
                        Button("Passer des tunnels en mode Système…") {
                            dismiss()
                            onOpenMigration()
                        }
                        .controlSize(.small)
                        .disabled(!system.canManage)
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Éditeur", value: "Haruni SAS")
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("SSH tunnels, by Haruni")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 420, minHeight: 440)
        .onAppear { status = LaunchAtLoginManager.status }
        .task {
            // The approval happens in System Settings: keep the status fresh.
            while !Task.isCancelled {
                daemonStatus = DaemonManager.status
                installationProblem = DaemonManager.installationProblem
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func installCommandLineTool() {
        Task {
            do {
                try await system.installCommandLineTool()
                cliInstalled = true
                daemonError = nil
            } catch {
                daemonError = "Échec : \(error.localizedDescription)"
            }
        }
    }

    private func runDaemonAction(_ action: () throws -> Void) {
        do {
            try action()
            daemonError = nil
        } catch {
            daemonError = "Échec : \(error.localizedDescription)"
        }
        daemonStatus = DaemonManager.status
    }

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#Preview {
    PreferencesView(system: SystemTunnelsModel())
}
