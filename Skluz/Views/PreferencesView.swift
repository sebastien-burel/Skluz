import SwiftUI
import ServiceManagement

struct PreferencesView: View {
    @State private var status: SMAppService.Status = LaunchAtLoginManager.status
    @State private var errorMessage: String?
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
        .frame(minWidth: 420, minHeight: 280)
        .onAppear { status = LaunchAtLoginManager.status }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#Preview {
    PreferencesView()
}
