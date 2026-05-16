import Foundation

nonisolated struct Tunnel: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var type: TunnelType
    var sshHost: String
    var sshUser: String?
    var sshPort: Int?
    var identityFile: String?
    var localPort: Int
    var remoteHost: String?
    var remotePort: Int?
    var proxyJump: String?
    var extraArgs: [String]
    var autoStart: Bool
    var autoRestart: Bool
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        type: TunnelType,
        sshHost: String,
        sshUser: String? = nil,
        sshPort: Int? = nil,
        identityFile: String? = nil,
        localPort: Int,
        remoteHost: String? = nil,
        remotePort: Int? = nil,
        proxyJump: String? = nil,
        extraArgs: [String] = [],
        autoStart: Bool = false,
        autoRestart: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.identityFile = identityFile
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.proxyJump = proxyJump
        self.extraArgs = extraArgs
        self.autoStart = autoStart
        self.autoRestart = autoRestart
        self.enabled = enabled
    }
}
