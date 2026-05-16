import Foundation
import Testing
@testable import Skluz

struct TunnelStoreTests {

    @Test func tunnelPersistsAcrossStoreInstances() async throws {
        let url = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let original = Tunnel(
            name: "prod-postgres",
            type: .localForward,
            sshHost: "bastion.example.com",
            sshUser: "sebastien",
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
        let initial = Tunnel(id: id, name: "old", type: .dynamic, sshHost: "gateway", localPort: 1080)
        let updated = Tunnel(id: id, name: "new", type: .dynamic, sshHost: "gateway", localPort: 1080)

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

        let tunnel = Tunnel(name: "temp", type: .remoteForward, sshHost: "public", localPort: 8080,
                            remoteHost: "localhost", remotePort: 8080)

        let store = TunnelStore(storageURL: url)
        try await store.load()
        try await store.upsert(tunnel)
        try await store.remove(id: tunnel.id)

        let reloaded = TunnelStore(storageURL: url)
        try await reloaded.load()
        #expect(await reloaded.tunnels.isEmpty)
    }

    private func makeTempStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tunnels.json", isDirectory: false)
    }
}
