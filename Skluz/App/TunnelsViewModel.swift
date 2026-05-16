import Foundation
import Observation

@Observable
final class TunnelsViewModel {
    private(set) var tunnels: [Tunnel] = []
    private(set) var states: [UUID: TunnelState] = [:]
    private(set) var configHosts: [SSHConfigHost] = []
    private(set) var lastError: String?

    private let store: TunnelStore
    private let runner: TunnelRunner
    private let configParser: SSHConfigParser
    nonisolated(unsafe) private var observationTask: Task<Void, Never>?

    init(store: TunnelStore, runner: TunnelRunner, configParser: SSHConfigParser) {
        self.store = store
        self.runner = runner
        self.configParser = configParser
        startObserving()
    }

    deinit {
        observationTask?.cancel()
    }

    private func startObserving() {
        let stream = runner.stateChanges
        observationTask = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                self.states[change.id] = change.state
            }
        }
    }

    func load() async {
        do {
            try await store.load()
            tunnels = await store.tunnels
            lastError = nil
        } catch {
            lastError = "Chargement impossible : \(error)"
        }
        configHosts = await configParser.loadHosts()
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
        await runner.stop(id: id)
        do {
            try await store.remove(id: id)
            tunnels = await store.tunnels
            states.removeValue(forKey: id)
            lastError = nil
        } catch {
            lastError = "Suppression impossible : \(error)"
        }
    }

    func startTunnel(_ tunnel: Tunnel) {
        Task { [runner] in await runner.start(tunnel) }
    }

    func stopTunnel(id: UUID) {
        Task { [runner] in await runner.stop(id: id) }
    }
}
