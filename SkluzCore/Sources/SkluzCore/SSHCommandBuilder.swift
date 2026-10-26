import Foundation

/// Builds the `/usr/bin/ssh` argument array of a tunnel. Every field is
/// validated first; the arguments then follow one of two policies:
/// - Session: the v1 behavior (`PLAN_SKLUZ.md` §5), unchanged;
/// - System: the strict allow-list of `PLAN_SKLUZD.md` — the daemon runs as
///   root, so no free-form option may ever reach ssh.
public enum SSHCommandBuilder {
    public static let sshPath = "/usr/bin/ssh"

    public static let sessionBaseOptions: [String] = [
        "-N",
        "-T",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "StrictHostKeyChecking=accept-new"
    ]

    public static let loopbackAddresses: Set<String> = ["127.0.0.1", "::1", "localhost"]
    public static let systemDefaultBindAddress = "127.0.0.1"
    public static let systemDefaultSSHPort = 22

    public static func arguments(for tunnel: TunnelConfig, paths: SystemPaths = .standard) throws -> [String] {
        try validate(tunnel)
        switch tunnel.mode {
        case .session: return sessionArguments(for: tunnel)
        case .system:  return try systemArguments(for: tunnel, paths: paths)
        }
    }

    // MARK: - Validation

    public static func validate(_ tunnel: TunnelConfig) throws {
        try checkNoControlCharacters(tunnel.name, field: "nom")
        try checkHost(tunnel.host, field: "host SSH")
        if let user = tunnel.user { try checkUser(user) }
        if let port = tunnel.port { try checkPort(port, field: "port SSH") }
        try checkPort(tunnel.localPort, field: "port local")
        if tunnel.type != .dynamic {
            if let remoteHost = tunnel.remoteHost { try checkHost(remoteHost, field: "host distant") }
            if let remotePort = tunnel.remotePort { try checkPort(remotePort, field: "port distant") }
        }
        if let bind = tunnel.localBindAddress {
            try checkBindAddress(bind, exposesOnNetwork: tunnel.exposesOnNetwork)
        }
        switch tunnel.keyRef {
        case .path(let path):    try checkNoControlCharacters(path, field: "clé")
        case .managed(let name): try checkKeyName(name)
        case nil:                break
        }
        if let jump = tunnel.proxyJump { try checkProxyJump(jump) }
        for arg in tunnel.extraArgs {
            try checkNoControlCharacters(arg, field: "args additionnels")
        }

        switch tunnel.mode {
        case .session:
            if case .managed = tunnel.keyRef { throw TunnelValidationError.managedKeyRequiresSystemMode }
        case .system:
            guard tunnel.type == .localForward else { throw TunnelValidationError.systemRequiresLocalForward }
            guard tunnel.user != nil else { throw TunnelValidationError.systemRequiresUser }
            guard case .managed = tunnel.keyRef else { throw TunnelValidationError.systemRequiresManagedKey }
            guard tunnel.proxyJump?.isEmpty ?? true else { throw TunnelValidationError.systemForbidsProxyJump }
            guard tunnel.extraArgs.isEmpty else { throw TunnelValidationError.systemForbidsExtraArgs }
        }
    }

    /// Host and port of an XPC request that targets a server directly
    /// (`fetchHostKey`, `trustHostKey`), with the same rules as a tunnel.
    public static func validateEndpoint(host: String, port: Int) throws {
        try checkHost(host, field: "host SSH")
        try checkPort(port, field: "port SSH")
    }

    /// Name of a dedicated daemon key, used as a file name under `keys/`.
    public static func validateKeyName(_ name: String) throws {
        try checkKeyName(name)
    }

    private static let hostCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
    private static let userCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    private static let keyNameCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    private static let proxyJumpCharacters = hostCharacters.union(CharacterSet(charactersIn: "@,[]"))

    private static func checkNoControlCharacters(_ value: String, field: String) throws {
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw TunnelValidationError.controlCharacters(field: field)
        }
    }

    /// Non-empty, restricted charset, never starting with `-` (ssh would read
    /// it as an option).
    private static func isSafeToken(_ value: String, allowed: CharacterSet, maxLength: Int) -> Bool {
        !value.isEmpty
            && value.count <= maxLength
            && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func checkHost(_ host: String, field: String) throws {
        try checkNoControlCharacters(host, field: field)
        guard isSafeToken(host, allowed: hostCharacters, maxLength: 253) else {
            throw TunnelValidationError.invalidHost(field: field, value: host)
        }
    }

    private static func checkUser(_ user: String) throws {
        try checkNoControlCharacters(user, field: "utilisateur")
        guard isSafeToken(user, allowed: userCharacters, maxLength: 64) else {
            throw TunnelValidationError.invalidUser(user)
        }
    }

    private static func checkPort(_ port: Int, field: String) throws {
        guard (1...65535).contains(port) else {
            throw TunnelValidationError.invalidPort(field: field, value: port)
        }
    }

    private static func checkBindAddress(_ address: String, exposesOnNetwork: Bool) throws {
        try checkNoControlCharacters(address, field: "adresse d'écoute")
        guard address == "*" || isSafeToken(address, allowed: hostCharacters, maxLength: 253) else {
            throw TunnelValidationError.invalidBindAddress(address)
        }
        if !loopbackAddresses.contains(address) && !exposesOnNetwork {
            throw TunnelValidationError.bindRequiresOptIn(address)
        }
    }

    private static func checkKeyName(_ name: String) throws {
        guard isSafeToken(name, allowed: keyNameCharacters, maxLength: 64) else {
            throw TunnelValidationError.invalidKeyName(name)
        }
    }

    private static func checkProxyJump(_ jump: String) throws {
        try checkNoControlCharacters(jump, field: "ProxyJump")
        guard jump.isEmpty || jump.split(separator: ",").allSatisfy({
            isSafeToken(String($0), allowed: proxyJumpCharacters, maxLength: 512)
        }) else {
            throw TunnelValidationError.invalidProxyJump(jump)
        }
    }

    // MARK: - Session policy

    private static func sessionArguments(for tunnel: TunnelConfig) -> [String] {
        var args = sessionBaseOptions

        if let port = tunnel.port {
            args.append("-p")
            args.append(String(port))
        }

        if case .path(let identity) = tunnel.keyRef, !identity.isEmpty {
            args.append("-i")
            args.append(expandTilde(identity))
            args.append("-o")
            args.append("IdentitiesOnly=yes")
        }

        if let jump = tunnel.proxyJump, !jump.isEmpty {
            args.append("-J")
            args.append(jump)
        }

        switch tunnel.type {
        case .localForward:
            args.append("-L")
            args.append(forwardSpec(tunnel: tunnel, bindAddress: tunnel.localBindAddress))
        case .remoteForward:
            args.append("-R")
            args.append(forwardSpec(tunnel: tunnel, bindAddress: tunnel.localBindAddress))
        case .dynamic:
            args.append("-D")
            args.append(listenSpec(port: tunnel.localPort, bindAddress: tunnel.localBindAddress))
        }

        let userPart = tunnel.user.map { "\($0)@" } ?? ""
        args.append("\(userPart)\(tunnel.host)")

        args.append(contentsOf: tunnel.extraArgs)

        return args
    }

    // MARK: - System policy

    private static func systemArguments(for tunnel: TunnelConfig, paths: SystemPaths) throws -> [String] {
        // `validate` guarantees a managed key and a user in System mode.
        guard case .managed(let keyName) = tunnel.keyRef, let user = tunnel.user else {
            throw TunnelValidationError.systemRequiresManagedKey
        }
        let knownHosts = paths.knownHostsFile.path(percentEncoded: false)
        let keyFile = paths.keyFile(named: keyName).path(percentEncoded: false)
        // ssh splits UserKnownHostsFile on whitespace: the paths must be quoted
        // ("/Library/Application Support/…"), so they must not contain quotes.
        // The key goes through `IdentityFile`, not `-i`: ssh silently drops a
        // missing `-i` file and falls back to the default keys — root's.
        try checkSystemPath(knownHosts)
        try checkSystemPath(keyFile)

        return [
            "-N", "-T",
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"\(knownHosts)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityFile=\"\(keyFile)\"",
            "-p", String(tunnel.port ?? systemDefaultSSHPort),
            "-L", forwardSpec(tunnel: tunnel, bindAddress: tunnel.localBindAddress ?? systemDefaultBindAddress),
            "\(user)@\(tunnel.host)"
        ]
    }

    private static func checkSystemPath(_ path: String) throws {
        if path.contains("\"") || path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw TunnelValidationError.unsafeSystemPath(path)
        }
    }

    // MARK: - Helpers

    private static func forwardSpec(tunnel: TunnelConfig, bindAddress: String?) -> String {
        let host = bracketed(tunnel.remoteHost ?? "localhost")
        let port = tunnel.remotePort ?? tunnel.localPort
        return "\(listenSpec(port: tunnel.localPort, bindAddress: bindAddress)):\(host):\(port)"
    }

    private static func listenSpec(port: Int, bindAddress: String?) -> String {
        guard let bindAddress else { return String(port) }
        return "\(bracketed(bindAddress)):\(port)"
    }

    /// IPv6 literals must be bracketed inside forward specs.
    private static func bracketed(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    private static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
