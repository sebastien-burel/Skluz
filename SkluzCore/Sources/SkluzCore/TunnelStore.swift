import Foundation

public enum TunnelStoreError: Error, Equatable {
    case notFound(UUID)
    case unsupportedSchemaVersion(Int)
}

public actor TunnelStore {
    private struct Wrapper: Codable {
        var version: Int
        var tunnels: [TunnelConfig]
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }

    /// v2 renamed `sshHost`/`sshUser`/`sshPort`, turned `identityFile` into
    /// `keyRef` and added `mode`, `localBindAddress`, `exposesOnNetwork`.
    public static let currentVersion = 2

    public let storageURL: URL
    public private(set) var tunnels: [TunnelConfig] = []

    /// File contents for `tunnels`, in the current schema.
    public static func encode(_ tunnels: [TunnelConfig]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Wrapper(version: currentVersion, tunnels: tunnels))
    }

    /// Tunnels of a file in the current schema only (the daemon's file is
    /// never v1: it is created by skluzd itself).
    public static func decodeCurrent(_ data: Data) throws -> [TunnelConfig] {
        let version = try JSONDecoder().decode(VersionProbe.self, from: data).version
        guard version == currentVersion else { throw TunnelStoreError.unsupportedSchemaVersion(version) }
        return try JSONDecoder().decode(Wrapper.self, from: data).tunnels
    }

    public init(storageURL: URL = TunnelStore.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    public static func defaultStorageURL() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Skluz", isDirectory: true)
            .appendingPathComponent("tunnels.json", isDirectory: false)
    }

    /// Copy of the v1 file kept before the first migration rewrites it:
    /// Skluz 1.0 cannot read v2.
    public var legacyBackupURL: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("tunnels.v1.json", isDirectory: false)
    }

    public func load() throws {
        let fm = FileManager.default
        try ensureDirectoryExists(fm: fm)
        guard fm.fileExists(atPath: storageURL.path) else {
            tunnels = []
            return
        }
        let data = try Data(contentsOf: storageURL)
        let version = try JSONDecoder().decode(VersionProbe.self, from: data).version
        guard version <= Self.currentVersion else {
            throw TunnelStoreError.unsupportedSchemaVersion(version)
        }
        if version == 1 {
            let legacy = try JSONDecoder().decode(LegacyWrapper.self, from: data)
            if !fm.fileExists(atPath: legacyBackupURL.path) {
                try fm.copyItem(at: storageURL, to: legacyBackupURL)
            }
            tunnels = legacy.tunnels.map(\.migrated)
            try persist()
        } else {
            tunnels = try JSONDecoder().decode(Wrapper.self, from: data).tunnels
        }
    }

    public func upsert(_ tunnel: TunnelConfig) throws {
        if let idx = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels[idx] = tunnel
        } else {
            tunnels.append(tunnel)
        }
        try persist()
    }

    public func remove(id: UUID) throws {
        let before = tunnels.count
        tunnels.removeAll { $0.id == id }
        guard tunnels.count != before else { throw TunnelStoreError.notFound(id) }
        try persist()
    }

    private func persist() throws {
        let fm = FileManager.default
        try ensureDirectoryExists(fm: fm)
        try Self.encode(tunnels).write(to: storageURL, options: .atomic)
    }

    private func ensureDirectoryExists(fm: FileManager) throws {
        let dir = storageURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Schema v1 (Skluz 1.0)

private struct LegacyWrapper: Decodable {
    var tunnels: [LegacyTunnel]
}

private struct LegacyTunnel: Decodable {
    var id: UUID
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

    var migrated: TunnelConfig {
        TunnelConfig(
            id: id,
            name: name,
            mode: .session,
            type: type,
            host: sshHost,
            user: sshUser,
            port: sshPort,
            keyRef: identityFile.flatMap { $0.isEmpty ? nil : .path($0) },
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            proxyJump: proxyJump,
            extraArgs: extraArgs,
            autoStart: autoStart,
            autoRestart: autoRestart,
            enabled: enabled
        )
    }
}
