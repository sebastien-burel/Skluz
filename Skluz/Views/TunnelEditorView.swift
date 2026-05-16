import SwiftUI

struct TunnelDraft {
    var id: UUID = UUID()
    var name: String = ""
    var type: TunnelType = .localForward
    var sshHost: String = ""
    var sshUser: String = ""
    var sshPortText: String = ""
    var localPortText: String = ""
    var remoteHost: String = ""
    var remotePortText: String = ""
    var proxyJump: String = ""
    var extraArgsText: String = ""
    var autoStart: Bool = false
    var autoRestart: Bool = false
    var enabled: Bool = true

    init() {}

    init(from tunnel: Tunnel) {
        self.id = tunnel.id
        self.name = tunnel.name
        self.type = tunnel.type
        self.sshHost = tunnel.sshHost
        self.sshUser = tunnel.sshUser ?? ""
        self.sshPortText = tunnel.sshPort.map(String.init) ?? ""
        self.localPortText = String(tunnel.localPort)
        self.remoteHost = tunnel.remoteHost ?? ""
        self.remotePortText = tunnel.remotePort.map(String.init) ?? ""
        self.proxyJump = tunnel.proxyJump ?? ""
        self.extraArgsText = tunnel.extraArgs.joined(separator: " ")
        self.autoStart = tunnel.autoStart
        self.autoRestart = tunnel.autoRestart
        self.enabled = tunnel.enabled
    }

    var validationError: String? {
        if trimmed(name).isEmpty { return "Le nom est requis." }
        if trimmed(sshHost).isEmpty { return "Le host SSH est requis." }
        guard let local = Int(localPortText), (1...65535).contains(local) else {
            return "Port local invalide (1 à 65535)."
        }
        if !sshPortText.isEmpty {
            guard let port = Int(sshPortText), (1...65535).contains(port) else {
                return "Port SSH invalide (1 à 65535)."
            }
        }
        if type != .dynamic {
            if trimmed(remoteHost).isEmpty { return "Le host distant est requis." }
            guard let port = Int(remotePortText), (1...65535).contains(port) else {
                return "Port distant invalide (1 à 65535)."
            }
        }
        return nil
    }

    func build() -> Tunnel? {
        guard validationError == nil, let localPort = Int(localPortText) else { return nil }
        let sshPort = Int(sshPortText)
        let remotePort = type != .dynamic ? Int(remotePortText) : nil
        let extras = extraArgsText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return Tunnel(
            id: id,
            name: trimmed(name),
            type: type,
            sshHost: trimmed(sshHost),
            sshUser: optional(sshUser),
            sshPort: sshPort,
            localPort: localPort,
            remoteHost: type != .dynamic ? optional(remoteHost) : nil,
            remotePort: remotePort,
            proxyJump: optional(proxyJump),
            extraArgs: extras,
            autoStart: autoStart,
            autoRestart: autoRestart,
            enabled: enabled
        )
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    private func optional(_ s: String) -> String? {
        let t = trimmed(s)
        return t.isEmpty ? nil : t
    }
}

struct TunnelEditorView: View {
    @State private var draft: TunnelDraft
    private let isEditing: Bool
    private let onSave: (Tunnel) -> Void
    private let onDelete: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(
        initial: Tunnel?,
        onSave: @escaping (Tunnel) -> Void,
        onDelete: ((UUID) -> Void)? = nil
    ) {
        if let initial {
            self._draft = State(initialValue: TunnelDraft(from: initial))
            self.isEditing = true
        } else {
            self._draft = State(initialValue: TunnelDraft())
            self.isEditing = false
        }
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nom", text: $draft.name, prompt: Text("prod-postgres"))
                    Picker("Type", selection: $draft.type) {
                        Text("Local (-L)").tag(TunnelType.localForward)
                        Text("Remote (-R)").tag(TunnelType.remoteForward)
                        Text("SOCKS (-D)").tag(TunnelType.dynamic)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Connexion SSH") {
                    TextField("Host", text: $draft.sshHost, prompt: Text("bastion.example.com"))
                    TextField("User", text: $draft.sshUser, prompt: Text("(optionnel)"))
                    TextField("Port SSH", text: $draft.sshPortText, prompt: Text("22"))
                }

                Section("Forwarding") {
                    TextField("Port local", text: $draft.localPortText, prompt: Text("5432"))
                    if draft.type != .dynamic {
                        TextField("Host distant", text: $draft.remoteHost, prompt: Text("db.internal"))
                        TextField("Port distant", text: $draft.remotePortText, prompt: Text("5432"))
                    }
                }

                Section("Avancé") {
                    TextField("ProxyJump (-J)", text: $draft.proxyJump, prompt: Text("bastion"))
                    TextField("Args additionnels", text: $draft.extraArgsText, prompt: Text("-v ..."))
                    Toggle("Démarrer au lancement", isOn: $draft.autoStart)
                    Toggle("Reconnexion automatique", isOn: $draft.autoRestart)
                    Toggle("Activé", isOn: $draft.enabled)
                }
            }
            .formStyle(.grouped)

            if let error = draft.validationError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }

            HStack(spacing: 8) {
                if isEditing, let onDelete {
                    Button("Supprimer", role: .destructive) {
                        onDelete(draft.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    if let tunnel = draft.build() {
                        onSave(tunnel)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.build() == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 440, idealWidth: 460, minHeight: 500)
    }
}

#Preview("Création") {
    TunnelEditorView(initial: nil, onSave: { _ in })
}

#Preview("Édition") {
    TunnelEditorView(
        initial: Tunnel(name: "prod-postgres", type: .localForward, sshHost: "bastion.example.com",
                        sshUser: "sebastien", localPort: 5432, remoteHost: "db.internal", remotePort: 5432),
        onSave: { _ in },
        onDelete: { _ in }
    )
}
