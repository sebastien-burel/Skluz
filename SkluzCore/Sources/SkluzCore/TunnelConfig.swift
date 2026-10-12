import Foundation

/// Who runs the tunnel: the menu bar app inside the user session, or the
/// root daemon `skluzd`, which works without any session.
public enum TunnelMode: String, Codable, CaseIterable, Sendable {
    case session
    case system
}

public enum TunnelType: String, Codable, CaseIterable, Sendable {
    case localForward       // -L localPort:remoteHost:remotePort
    case remoteForward      // -R localPort:remoteHost:remotePort
    case dynamic            // -D localPort (SOCKS)
}

/// Where the private key lives.
public enum KeyRef: Hashable, Sendable {
    /// Free path chosen by the user (Session mode), `~` allowed.
    case path(String)
    /// Dedicated daemon key, stored as `keys/<name>` (System mode).
    case managed(String)
}

extension KeyRef: Codable {
    private enum CodingKeys: String, CodingKey {
        case path, managed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try container.decodeIfPresent(String.self, forKey: .path) {
            self = .path(path)
        } else if let name = try container.decodeIfPresent(String.self, forKey: .managed) {
            self = .managed(name)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "keyRef needs either `path` or `managed`"
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .path(let path):    try container.encode(path, forKey: .path)
        case .managed(let name): try container.encode(name, forKey: .managed)
        }
    }
}

/// One tunnel, shared by the app, the daemon and the CLI. Session-only fields
/// (`proxyJump`, `extraArgs`, `autoStart`, `autoRestart`) are rejected or
/// ignored in System mode, see `SSHCommandBuilder.validate`.
public struct TunnelConfig: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var mode: TunnelMode
    public var type: TunnelType
    public var host: String
    public var user: String?
    public var port: Int?
    public var keyRef: KeyRef?
    /// Local listen address. `nil` keeps ssh's default in Session mode and
    /// means `127.0.0.1` in System mode.
    public var localBindAddress: String?
    /// Explicit opt-in required to listen on a non-loopback address.
    public var exposesOnNetwork: Bool
    public var localPort: Int
    public var remoteHost: String?
    public var remotePort: Int?
    public var proxyJump: String?
    public var extraArgs: [String]
    public var autoStart: Bool
    public var autoRestart: Bool
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        mode: TunnelMode = .session,
        type: TunnelType,
        host: String,
        user: String? = nil,
        port: Int? = nil,
        keyRef: KeyRef? = nil,
        localBindAddress: String? = nil,
        exposesOnNetwork: Bool = false,
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
        self.mode = mode
        self.type = type
        self.host = host
        self.user = user
        self.port = port
        self.keyRef = keyRef
        self.localBindAddress = localBindAddress
        self.exposesOnNetwork = exposesOnNetwork
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
