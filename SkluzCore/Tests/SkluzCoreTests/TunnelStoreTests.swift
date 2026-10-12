import Foundation
import Testing
@testable import SkluzCore

struct TunnelStoreTests {

    @Test func tunnelPersistsAcrossStoreInstances() async throws {
        let url = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let original = TunnelConfig(
            name: "prod-postgres",
            type: .localForward,
            host: "bastion.example.com",
            user: "sebastien",
            keyRef: .path("~/.ssh/id_ed25519"),
            localPort: 5432,
            remoteHost: "db.internal",
            remotePort: 5432
        )

        let writer = TunnelStore(storageURL: url)
        try await writer.load()
        try await writer.upsert(original)

        let reader = TunnelStore(storageURL: url)
        try await reader.load()
        let reloaded = await reader.tunnels

        #expect(reloaded == [original])
    }

    @Test func upsertReplacesExistingTunnelById() async throws {
        let url = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let id = UUID()
        let initial = TunnelConfig(id: id, name: "old", type: .dynamic, host: "gateway", localPort: 1080)
        let updated = TunnelConfig(id: id, name: "new", type: .dynamic, host: "gateway", localPort: 1080)

        let store = TunnelStore(storageURL: url)
        try await store.load()
        try await store.upsert(initial)
        try await store.upsert(updated)

        let result = await store.tunnels
        #expect(result == [updated])
    }

    @Test func removeDropsTunnelAndPersists() async throws {
        let url = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let tunnel = TunnelConfig(name: "temp", type: .remoteForward, host: "public", localPort: 8080,
                                  remoteHost: "localhost", remotePort: 8080)

        let store = TunnelStore(storageURL: url)
        try await store.load()
        try await store.upsert(tunnel)
        try await store.remove(id: tunnel.id)

        let reloaded = TunnelStore(storageURL: url)
        try await reloaded.load()
        #expect(await reloaded.tunnels.isEmpty)
    }

    // MARK: - Migration v1 → v2

    /// Same shape as a real Skluz 1.0 file.
    private let legacyJSON = """
    {
      "tunnels" : [
        {
          "autoRestart" : true, "autoStart" : true, "enabled" : true, "extraArgs" : [ "-v" ],
          "id" : "BEB4BDC3-7A35-4C66-AEBD-1CC0830B0863",
          "identityFile" : "/Users/sb/Library/Application Support/NVIDIA/Sync/config/nvsync.key",
          "localPort" : 8000, "name" : "vLLM", "remoteHost" : "localhost", "remotePort" : 8000,
          "sshHost" : "dgx.haruni.net", "sshPort" : 2022, "sshUser" : "sb", "type" : "localForward"
        },
        {
          "autoRestart" : false, "autoStart" : false, "enabled" : false, "extraArgs" : [ ],
          "id" : "0E0D2E4C-6E4D-4C1B-9B57-7A5B6B1F0C11",
          "localPort" : 1080, "name" : "socks", "proxyJump" : "bastion",
          "sshHost" : "gateway", "type" : "dynamic"
        }
      ],
      "version" : 1
    }
    """

    @Test func legacyFileIsMigratedToSessionTunnels() async throws {
        let url = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacyJSON.utf8).write(to: url)

        let store = TunnelStore(storageURL: url)
        try await store.load()
        let tunnels = await store.tunnels

        #expect(tunnels == [
            TunnelConfig(
                id: UUID(uuidString: "BEB4BDC3-7A35-4C66-AEBD-1CC0830B0863")!,
                name: "vLLM", mode: .session, type: .localForward,
                host: "dgx.haruni.net", user: "sb", port: 2022,
                keyRef: .path("/Users/sb/Library/Application Support/NVIDIA/Sync/config/nvsync.key"),
                localPort: 8000, remoteHost: "localhost", remotePort: 8000,
                extraArgs: ["-v"], autoStart: true, autoRestart: true, enabled: true
            ),
            TunnelConfig(
                id: UUID(uuidString: "0E0D2E4C-6E4D-4C1B-9B57-7A5B6B1F0C11")!,
                name: "socks", mode: .session, type: .dynamic, host: "gateway",
                localPort: 1080, proxyJump: "bastion", enabled: false
            )
        ])
    }

    @Test func migrationKeepsV1BackupAndRewritesAsV2() async throws {
        let url = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacyJSON.utf8).write(to: url)

        let store = TunnelStore(storageURL: url)
        try await store.load()
        let migrated = await store.tunnels

        let backup = await store.legacyBackupURL
        #expect(try String(contentsOf: backup, encoding: .utf8) == legacyJSON)

        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(rewritten?["version"] as? Int == 2)

        let reloaded = TunnelStore(storageURL: url)
        try await reloaded.load()
        #expect(await reloaded.tunnels == migrated)
    }

    @Test func newerSchemaIsRefused() async throws {
        let url = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 3, "tunnels": []}"#.utf8).write(to: url)

        await #expect(throws: TunnelStoreError.unsupportedSchemaVersion(3)) {
            try await TunnelStore(storageURL: url).load()
        }
    }

    private func makeTempStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tunnels.json", isDirectory: false)
    }
}
