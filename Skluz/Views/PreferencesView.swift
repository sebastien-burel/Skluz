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
    @State private var isConfirmingRemoval = false
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
                    if let status = system.status {
                        LabeledContent("Version du service") {
                            let daemon = "\(status.version) (\(status.build ?? "?"))"
                            if system.isDaemonUpToDate {
                                Text(daemon)
                            } else {
                                Text("\(daemon) — différente de l'app (\(appVersion))")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    if let message = system.updateMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }

                    if DaemonManager.isRunningStaleBundle {
                        HStack {
                            Label(DaemonManager.Failure.staleBundle.localizedDescription,
                                  systemImage: "arrow.clockwise.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Relancer Skluz") { DaemonManager.relaunch() }
                                .controlSize(.small)
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
                                .disabled(installationProblem != nil || DaemonManager.isRunningStaleBundle)
                        }
                        if daemonStatus == .requiresApproval {
                            Button("Ouvrir les réglages") { DaemonManager.openSettings() }
                        }
                        Spacer()
                        if daemonStatus == .enabled || daemonStatus == .requiresApproval {
                            Button("Supprimer le service système…", role: .destructive) { isConfirmingRemoval = true }
                        }
                    }
                    .controlSize(.small)
                    .confirmationDialog("Supprimer le service système ?", isPresented: $isConfirmingRemoval) {
                        Button("Supprimer le service, garder la configuration") {
                            runDaemonAction(DaemonManager.unregister)
                        }
                        Button("Supprimer le service et sa configuration", role: .destructive) {
                            removeServiceAndConfiguration()
                        }
                        .disabled(!system.canManage)
                    } message: {
                        Text("Les tunnels Système s'arrêtent. Supprimer la configuration efface aussi "
                             + "/Library/Application Support/Skluz (tunnels, clés dédiées, known_hosts) et "
                             + "/usr/local/bin/skluz : les clés ne pourront pas être récupérées.")
                    }
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

    /// Purge first: once unregistered, the daemon is gone and nobody else can
    /// delete its root files.
    private func removeServiceAndConfiguration() {
        Task {
            do {
                try await system.purgeConfiguration()
                runDaemonAction(DaemonManager.unregister)
            } catch {
                daemonError = "Échec : \(error.localizedDescription)"
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
