import SwiftUI
import UniformTypeIdentifiers
import SkluzCore

struct TunnelDraft {
    var id: UUID = UUID()
    var name: String = ""
    var type: TunnelType = .localForward
    var sshHost: String = ""
    var sshUser: String = ""
    var sshPortText: String = ""
    var identityFile: String = ""
    var localPortText: String = ""
    var remoteHost: String = ""
    var remotePortText: String = ""
    var proxyJump: String = ""
    var extraArgsText: String = ""
    var autoStart: Bool = false
    var autoRestart: Bool = false
    var enabled: Bool = true
    // Not editable yet (System mode UI comes with PLAN_SKLUZD phase 6), but
    // kept so that editing a tunnel never drops them.
    var mode: TunnelMode = .session
    var managedKey: String?
    var localBindAddress: String?
    var exposesOnNetwork: Bool = false

    init() {}

    init(from tunnel: TunnelConfig) {
        self.id = tunnel.id
        self.name = tunnel.name
        self.type = tunnel.type
        self.sshHost = tunnel.host
        self.sshUser = tunnel.user ?? ""
        self.sshPortText = tunnel.port.map(String.init) ?? ""
        switch tunnel.keyRef {
        case .path(let path):    self.identityFile = path
        case .managed(let name): self.managedKey = name
        case nil:                break
        }
        self.localPortText = String(tunnel.localPort)
        self.remoteHost = tunnel.remoteHost ?? ""
        self.remotePortText = tunnel.remotePort.map(String.init) ?? ""
        self.proxyJump = tunnel.proxyJump ?? ""
        self.extraArgsText = tunnel.extraArgs.joined(separator: " ")
        self.autoStart = tunnel.autoStart
        self.autoRestart = tunnel.autoRestart
        self.enabled = tunnel.enabled
        self.mode = tunnel.mode
        self.localBindAddress = tunnel.localBindAddress
        self.exposesOnNetwork = tunnel.exposesOnNetwork
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
        if let tunnel = assemble() {
            do {
                try SSHCommandBuilder.validate(tunnel)
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    func build() -> TunnelConfig? {
        validationError == nil ? assemble() : nil
    }

    private func assemble() -> TunnelConfig? {
        guard let localPort = Int(localPortText) else { return nil }
        let sshPort = Int(sshPortText)
        let remotePort = type != .dynamic ? Int(remotePortText) : nil
        let extras = extraArgsText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return TunnelConfig(
            id: id,
            name: trimmed(name),
            mode: mode,
            type: type,
            host: trimmed(sshHost),
            user: optional(sshUser),
            port: sshPort,
            keyRef: managedKey.map(KeyRef.managed) ?? optional(identityFile).map(KeyRef.path),
            localBindAddress: localBindAddress,
            exposesOnNetwork: exposesOnNetwork,
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
    @State private var isPickingIdentityFile = false
    @State private var pickedConfigAlias: String?
    @State private var isTesting = false
    @State private var testResult: TunnelTester.Result?
    private let isEditing: Bool
    private let configHosts: [SSHConfigHost]
    private let onSave: (TunnelConfig) -> Void
    private let onTest: (TunnelConfig) async -> TunnelTester.Result
    private let onDelete: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(
        initial: TunnelConfig?,
        configHosts: [SSHConfigHost],
        onSave: @escaping (TunnelConfig) -> Void,
        onTest: @escaping (TunnelConfig) async -> TunnelTester.Result,
        onDelete: ((UUID) -> Void)? = nil
    ) {
        if let initial {
            self._draft = State(initialValue: TunnelDraft(from: initial))
            self.isEditing = true
        } else {
            self._draft = State(initialValue: TunnelDraft())
            self.isEditing = false
        }
        self.configHosts = configHosts
        self.onSave = onSave
        self.onTest = onTest
        self.onDelete = onDelete
    }

    private var selectableAliases: [SSHConfigHost] {
        configHosts.filter(\.isSelectableAlias)
    }

    private func applyAlias(_ host: SSHConfigHost) {
        draft.sshHost = host.aliasOrPattern
        if let user = host.user { draft.sshUser = user }
        if let port = host.port { draft.sshPortText = String(port) }
        if let identity = host.identityFile { draft.identityFile = identity }
        pickedConfigAlias = host.aliasOrPattern
    }

    private func feedbackLine(icon: String, text: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
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
                    HStack {
                        TextField("Host", text: $draft.sshHost, prompt: Text("bastion.example.com"))
                            .onChange(of: draft.sshHost) { _, _ in pickedConfigAlias = nil }
                        if !selectableAliases.isEmpty {
                            Menu {
                                ForEach(selectableAliases) { host in
                                    Button(host.aliasOrPattern) { applyAlias(host) }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Choisir un hôte depuis ~/.ssh/config")
                        }
                    }
                    if let alias = pickedConfigAlias {
                        Label("Pré-rempli depuis ~/.ssh/config (« \(alias) »)",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("User", text: $draft.sshUser, prompt: Text("(optionnel)"))
                    TextField("Port SSH", text: $draft.sshPortText, prompt: Text("22"))
                    HStack {
                        TextField("Clé (-i)", text: $draft.identityFile,
                                  prompt: Text("(optionnel — sinon agent SSH)"))
                        Button("Parcourir…") { isPickingIdentityFile = true }
                            .controlSize(.small)
                    }
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
                feedbackLine(icon: "exclamationmark.triangle", text: error, color: .orange)
            } else if isTesting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Test en cours…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            } else if let testResult {
                switch testResult {
                case .success:
                    feedbackLine(icon: "checkmark.circle", text: "Connexion réussie.", color: .green)
                case .failure(let message):
                    feedbackLine(icon: "xmark.circle", text: message, color: .red)
                }
            }

            HStack(spacing: 8) {
                if isEditing, let onDelete {
                    Button("Supprimer", role: .destructive) {
                        onDelete(draft.id)
                        dismiss()
                    }
                }
                Button("Tester") {
                    guard let tunnel = draft.build() else { return }
                    isTesting = true
                    testResult = nil
                    Task {
                        let result = await onTest(tunnel)
                        isTesting = false
                        testResult = result
                    }
                }
                .disabled(draft.build() == nil || isTesting)
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
        .frame(minWidth: 440, idealWidth: 460, minHeight: 520)
        .fileImporter(
            isPresented: $isPickingIdentityFile,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                draft.identityFile = url.path
            }
        }
    }
}

#Preview("Création") {
    TunnelEditorView(
        initial: nil,
        configHosts: [
            SSHConfigHost(aliasOrPattern: "dgx", hostname: "dgx.haruni.net",
                          user: "sb", port: 2022, identityFile: "~/.ssh/id_ed25519")
        ],
        onSave: { _ in },
        onTest: { _ in .success }
    )
}

#Preview("Édition") {
    TunnelEditorView(
        initial: TunnelConfig(name: "prod-postgres", type: .localForward, host: "bastion.example.com",
                              user: "sebastien", localPort: 5432, remoteHost: "db.internal", remotePort: 5432),
        configHosts: [],
        onSave: { _ in },
        onTest: { _ in .failure("Permission denied (publickey).") },
        onDelete: { _ in }
    )
}
