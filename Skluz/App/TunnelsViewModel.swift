import Foundation
import Observation

@Observable
final class TunnelsViewModel {
    private(set) var tunnels: [Tunnel] = []
    private(set) var lastError: String?

    private let store: TunnelStore

    init(store: TunnelStore) {
        self.store = store
    }

    func load() async {
        do {
            try await store.load()
            tunnels = await store.tunnels
            lastError = nil
        } catch {
            lastError = "Chargement impossible : \(error)"
        }
    }

    func upsert(_ tunnel: Tunnel) async {
        do {
            try await store.upsert(tunnel)
            tunnels = await store.tunnels
            lastError = nil
        } catch {
            lastError = "Sauvegarde impossible : \(error)"
        }
    }

    func remove(id: UUID) async {
        do {
            try await store.remove(id: id)
            tunnels = await store.tunnels
            lastError = nil
        } catch {
            lastError = "Suppression impossible : \(error)"
        }
    }
}
