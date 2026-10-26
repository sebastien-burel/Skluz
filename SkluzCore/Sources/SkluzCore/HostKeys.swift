import Foundation

/// A server host key, as offered by `ssh-keyscan` and shown to the user
/// before being trusted.
public struct HostKey: Codable, Hashable, Sendable {
    public var type: String
    /// Base64 key blob.
    public var key: String
    public var fingerprint: String

    public init(type: String, key: String, fingerprint: String) {
        self.type = type
        self.key = key
        self.fingerprint = fingerprint
    }
}

public enum HostKeyError: Error, Equatable, LocalizedError {
    case noKeys(String)
    case invalidKey

    public var errorDescription: String? {
        switch self {
        case .noKeys(let detail):
            "Aucune clé d'hôte reçue\(detail.isEmpty ? "" : " : \(detail)")."
        case .invalidKey:
            "Clé d'hôte invalide."
        }
    }
}

/// First contact with a server (`PLAN_SKLUZD.md` phase 5): keys are scanned,
/// shown with their SHA256 fingerprint, and only added to the daemon's
/// `known_hosts` once the user confirms. Never `accept-new`.
public enum HostKeys {
    static let sshKeyscan = "/usr/bin/ssh-keyscan"
    public static let allowedTypes: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"
    ]

    /// `known_hosts` host field: plain for port 22, `[host]:port` otherwise.
    public static func pattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    public static func scan(host: String, port: Int) throws -> [HostKey] {
        try SSHCommandBuilder.validateEndpoint(host: host, port: port)
        let output = try ToolRunner.run(sshKeyscan, [
            "-T", "5", "-p", String(port), "-t", "ed25519,ecdsa,rsa", "--", host
        ])
        let keys = parse(String(decoding: output.stdout, as: UTF8.self))
        guard !keys.isEmpty else {
            throw HostKeyError.noKeys(output.stderrText.split(whereSeparator: \.isNewline).last.map(String.init) ?? "")
        }
        return keys
    }

    /// Lines of `ssh-keyscan`: `host type base64`, comments starting with `#`.
    public static func parse(_ output: String) -> [HostKey] {
        var keys: [HostKey] = []
        for line in output.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: " ")
            guard fields.count >= 3,
                  let key = makeKey(type: String(fields[1]), key: String(fields[2])),
                  !keys.contains(key) else { continue }
            keys.append(key)
        }
        return keys
    }

    public static func makeKey(type: String, key: String) -> HostKey? {
        guard allowedTypes.contains(type), let fingerprint = ManagedKeys.fingerprint(ofBlob: key) else { return nil }
        return HostKey(type: type, key: key, fingerprint: fingerprint)
    }

    /// Appends the confirmed key to the daemon's `known_hosts`, atomically,
    /// unless it is already there.
    public static func trust(type: String, key: String, host: String, port: Int, _ paths: SystemPaths,
                             ownership: FileOwnership) throws {
        try SSHCommandBuilder.validateEndpoint(host: host, port: port)
        guard makeKey(type: type, key: key) != nil else { throw HostKeyError.invalidKey }

        let line = "\(pattern(host: host, port: port)) \(type) \(key)"
        let current = (try? String(contentsOf: paths.knownHostsFile, encoding: .utf8)) ?? ""
        let lines = current.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.contains(line) else { return }
        let updated = (lines + [line]).joined(separator: "\n") + "\n"
        try SystemLayout.writeFile(Data(updated.utf8), to: paths.knownHostsFile, mode: 0o644, ownership: ownership)
    }

    /// Host key failure in the recent stderr lines of a tunnel, if any.
    public static func failure(inLog lines: [String]) -> TunnelStatus.Phase? {
        if lines.contains(where: { $0.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") }) {
            return .hostKeyChanged
        }
        if lines.contains(where: { $0.contains("Host key verification failed") || $0.contains("host key is known") }) {
            return .hostKeyUnknown
        }
        return nil
    }
}
