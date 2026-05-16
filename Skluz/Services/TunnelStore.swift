import Foundation

nonisolated enum TunnelStoreError: Error, Equatable {
    case notFound(UUID)
    case unsupportedSchemaVersion(Int)
}

actor TunnelStore {
    private struct Wrapper: Codable {
        var version: Int
        var tunnels: [Tunnel]
    }

    private static let currentVersion = 1

    let storageURL: URL
    private(set) var tunnels: [Tunnel] = []

    init(storageURL: URL = TunnelStore.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    static func defaultStorageURL() -> URL {
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

    func load() throws {
        let fm = FileManager.default
        try ensureDirectoryExists(fm: fm)
        guard fm.fileExists(atPath: storageURL.path) else {
            tunnels = []
            return
        }
        let data = try Data(contentsOf: storageURL)
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        guard wrapper.version <= Self.currentVersion else {
            throw TunnelStoreError.unsupportedSchemaVersion(wrapper.version)
        }
        tunnels = wrapper.tunnels
    }

    func upsert(_ tunnel: Tunnel) throws {
        if let idx = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels[idx] = tunnel
        } else {
            tunnels.append(tunnel)
        }
        try persist()
    }

    func remove(id: UUID) throws {
        let before = tunnels.count
        tunnels.removeAll { $0.id == id }
        guard tunnels.count != before else { throw TunnelStoreError.notFound(id) }
        try persist()
    }

    private func persist() throws {
        let fm = FileManager.default
        try ensureDirectoryExists(fm: fm)
        let wrapper = Wrapper(version: Self.currentVersion, tunnels: tunnels)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(wrapper)
        try data.write(to: storageURL, options: .atomic)
    }

    private func ensureDirectoryExists(fm: FileManager) throws {
        let dir = storageURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
