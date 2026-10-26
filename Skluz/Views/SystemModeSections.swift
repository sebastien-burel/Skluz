import SwiftUI
import AppKit
import SkluzCore

/// Step 1 of a System tunnel: a dedicated key of the daemon, and the
/// restricted `authorized_keys` line to install on the server.
struct SystemKeySection: View {
    @Binding var draft: TunnelDraft
    let system: SystemTunnelsModel
    @State private var newKeyName = ""
    @State private var isGenerating = false
    @State private var error: String?
    @State private var copied = false

    private var selectedKey: ManagedKey? {
        system.keys.first { $0.name == draft.managedKey }
    }

    var body: some View {
        Section {
            Picker("Clé", selection: $draft.managedKey) {
                Text("Aucune").tag(String?.none)
                ForEach(system.keys, id: \.name) { key in
                    Text(key.name).tag(Optional(key.name))
                }
            }
            HStack {
                TextField("Nouvelle clé", text: $newKeyName, prompt: Text(suggestedName))
                Button("Générer") { generate() }
                    .controlSize(.small)
                    .disabled(isGenerating || !system.canManage)
            }
            if let key = selectedKey {
                LabeledContent("Empreinte", value: key.fingerprint)
                    .font(.caption.monospaced())
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ajoutez cette ligne à ~/.ssh/authorized_keys de « \(userLabel) » sur \(hostLabel) :")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(authorizedKeysLine(for: key))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(4)
                    Button(copied ? "Copié" : "Copier la ligne") { copy(authorizedKeysLine(for: key)) }
                        .controlSize(.small)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("1. Clé dédiée")
        } footer: {
            Text("Sans passphrase, puisqu'elle sert avant toute ouverture de session : la ligne ci-dessus la restreint "
                 + "à ce seul tunnel, sans shell ni commande.")
        }
        .task { await system.refreshKeys() }
    }

    private var suggestedName: String {
        // Key names allow only ASCII letters, digits, _ and -.
        let base = draft.name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        return base.isEmpty ? "dgx" : String(base)
    }

    private var userLabel: String { draft.sshUser.isEmpty ? "utilisateur" : draft.sshUser }
    private var hostLabel: String { draft.sshHost.isEmpty ? "le serveur" : draft.sshHost }

    private func authorizedKeysLine(for key: ManagedKey) -> String {
        ManagedKeys.restrictedAuthorizedKeysLine(
            publicKey: key.publicKey,
            remoteHost: draft.remoteHost.isEmpty ? "localhost" : draft.remoteHost,
            remotePort: Int(draft.remotePortText) ?? 0
        )
    }

    private func generate() {
        let name = newKeyName.isEmpty ? suggestedName : newKeyName
        isGenerating = true
        error = nil
        Task {
            do {
                let key = try await system.generateKey(name: name)
                draft.managedKey = key.name
                newKeyName = ""
            } catch {
                self.error = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

/// Step 2 of a System tunnel: the server key is shown with its fingerprint
/// and only trusted once the user confirms it (never `accept-new`).
struct HostKeySection: View {
    let host: String
    let port: Int
    let system: SystemTunnelsModel
    @State private var keys: [HostKey] = []
    @State private var trusted: Set<String> = []
    @State private var isFetching = false
    @State private var error: String?

    var body: some View {
        Section {
            Button(isFetching ? "Récupération…" : "Récupérer les empreintes de \(host.isEmpty ? "l'hôte" : host)") {
                fetch()
            }
            .disabled(host.isEmpty || isFetching || !system.canManage)
            ForEach(keys, id: \.key) { key in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.type).font(.caption)
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Spacer()
                    if trusted.contains(key.key) {
                        Label("Approuvée", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Button("Approuver") { trust(key) }
                            .controlSize(.small)
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("2. Clé d'hôte")
        } footer: {
            Text("Comparez l'empreinte avec celle du serveur (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub) "
                 + "ou de votre ~/.ssh/known_hosts. Inutile si l'hôte est déjà approuvé.")
        }
        .onChange(of: host) { _, _ in reset() }
        .onChange(of: port) { _, _ in reset() }
    }

    private func reset() {
        keys = []
        trusted = []
        error = nil
    }

    private func fetch() {
        isFetching = true
        error = nil
        Task {
            do {
                keys = try await system.fetchHostKeys(host: host, port: port)
            } catch {
                self.error = error.localizedDescription
            }
            isFetching = false
        }
    }

    private func trust(_ key: HostKey) {
        Task {
            do {
                try await system.trust(key, host: host, port: port)
                trusted.insert(key.key)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
