import Foundation

/// XPC contract between skluzd and its clients (`PLAN_SKLUZD.md` phase 4).
/// Payloads travel as JSON `Data` to keep the interface simple; mutations
/// reply with an error message, `nil` on success.
@objc public protocol SkluzDaemonProtocol {
    func version(reply: @escaping @Sendable (String) -> Void)
    /// JSON `[TunnelConfig]`: the System tunnels of the daemon config.
    func listTunnels(reply: @escaping @Sendable (Data?, String?) -> Void)
    /// JSON `DaemonStatus`.
    func status(reply: @escaping @Sendable (Data?, String?) -> Void)
    /// JSON `TunnelConfig`, validated before being persisted. Admins only.
    func upsertTunnel(_ tunnel: Data, reply: @escaping @Sendable (String?) -> Void)
    /// Admins only.
    func deleteTunnel(id: String, reply: @escaping @Sendable (String?) -> Void)
    /// Admins only.
    func setEnabled(id: String, enabled: Bool, reply: @escaping @Sendable (String?) -> Void)

    // MARK: Keys and host keys (phase 5)

    /// JSON `[ManagedKey]`.
    func listKeys(reply: @escaping @Sendable (Data?, String?) -> Void)
    /// New ed25519 key without passphrase; replies its JSON `ManagedKey`. Admins only.
    func generateKey(name: String, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Existing private key, refused if it has a passphrase; replies its JSON
    /// `ManagedKey`. Admins only.
    func importKey(name: String, privateKey: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// `ssh-keyscan` of the server; replies JSON `[HostKey]` to show the user.
    func fetchHostKey(host: String, port: Int, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Adds a key the user confirmed to the daemon's known_hosts. Admins only.
    func trustHostKey(host: String, port: Int, type: String, key: String,
                      reply: @escaping @Sendable (String?) -> Void)
}

public enum DaemonAPI {
    public static let machServiceName = "net.haruni.skluzd.xpc"

    /// What the daemon demands from its clients. The parentheses matter:
    /// `and` binds tighter than `or`, and without them any binary, even
    /// ad hoc signed, declaring the CLI identifier would be accepted.
    public static let clientRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"82FW35VV68\""
        + " and (identifier \"net.haruni.skluz\" or identifier \"net.haruni.skluz.cli\")"

    /// What clients demand from the daemon.
    public static let daemonRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"82FW35VV68\""
        + " and identifier \"net.haruni.skluzd\""

    public static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: SkluzDaemonProtocol.self)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Snapshot returned by `status()`.
public struct DaemonStatus: Codable, Equatable, Sendable {
    public var version: String
    /// Why no tunnel runs, when the daemon refused its config.
    public var configProblem: String?
    public var tunnels: [TunnelStatus]

    public init(version: String, configProblem: String?, tunnels: [TunnelStatus]) {
        self.version = version
        self.configProblem = configProblem
        self.tunnels = tunnels
    }
}

public struct TunnelStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case up, starting, reconnecting, failed, stopped
        /// The server is not in the daemon's known_hosts yet: trust it first.
        case hostKeyUnknown
        /// The server key differs from the trusted one: possible attack.
        case hostKeyChanged
    }

    public var id: UUID
    public var name: String
    public var localPort: Int
    public var phase: Phase
    public var pid: Int32?
    /// Start of the current run, when `up`.
    public var since: Date?
    public var lastError: String?
    /// Reconnections since the daemon started.
    public var reconnections: Int

    public init(id: UUID, name: String, localPort: Int, phase: Phase, pid: Int32?, since: Date?,
                lastError: String?, reconnections: Int) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.phase = phase
        self.pid = pid
        self.since = since
        self.lastError = lastError
        self.reconnections = reconnections
    }

    public init(tunnel: TunnelConfig, state: TunnelState?, lastError: String?, reconnections: Int) {
        let phase: Phase
        var pid: Int32?
        var since: Date?
        switch state {
        case .running(let runningPID, let start):
            phase = .up
            pid = runningPID
            since = start
        case .starting:      phase = .starting
        case .reconnecting:  phase = .reconnecting
        case .failed:        phase = .failed
        case .stopped, nil:  phase = .stopped
        }
        self.init(id: tunnel.id, name: tunnel.name, localPort: tunnel.localPort, phase: phase,
                  pid: pid, since: since, lastError: lastError, reconnections: reconnections)
    }
}
