import Foundation
import SkluzCore

/// Supervises the enabled System-mode tunnels of the root config.
actor Daemon {
    private let paths: SystemPaths
    private let ownership: FileOwnership
    private let supervisor: TunnelSupervisor
    private var active: [UUID: TunnelConfig] = [:]
    /// Why no tunnel runs, when the config was refused (exposed over XPC in
    /// phase 4).
    private(set) var configProblem: String?

    init(paths: SystemPaths, ownership: FileOwnership) {
        self.paths = paths
        self.ownership = ownership
        var environment = TunnelSupervisor.Environment.live
        environment.systemPaths = paths
        // No PID registry: launchd kills the job's process group, so ssh
        // children never outlive the daemon.
        self.supervisor = TunnelSupervisor(environment: environment, logStore: LogStore(), pidStore: nil)
    }

    func start() async {
        let changes = supervisor.stateChanges
        Task { [weak self] in
            for await change in changes {
                await self?.log(change)
            }
        }
        await supervisor.watchNetwork(NetworkMonitor.events())
        await reload(reason: "démarrage")
    }

    /// Initial load and `SIGHUP`: applies the config, or stops everything if
    /// it can no longer be trusted.
    func reload(reason: String) async {
        let configured: [TunnelConfig]
        do {
            configured = try await SystemLayout.loadTunnels(paths, ownership: ownership)
        } catch {
            configProblem = error.localizedDescription
            Log.config.error("Configuration refusée (\(reason)), aucun tunnel lancé : \(error.localizedDescription)")
            await stopAll()
            return
        }
        configProblem = nil

        for tunnel in configured where tunnel.mode == .session {
            Log.config.error("« \(tunnel.name) » est en mode Session dans la config système : ignoré.")
        }

        let plan = TunnelReconciler.plan(active: active, configured: configured)
        for id in plan.toStop {
            await supervisor.stop(id: id)
            active.removeValue(forKey: id)
        }
        for tunnel in plan.toStart {
            active[tunnel.id] = tunnel
            await supervisor.start(tunnel)
        }
        Log.config.info("Configuration chargée (\(reason)) : \(active.count) tunnel(s) système, "
                        + "\(plan.toStart.count) démarré(s), \(plan.toStop.count) arrêté(s).")
    }

    /// `SIGTERM`: stops every ssh child before exiting.
    func shutdown() async {
        Log.supervisor.info("Arrêt demandé : fermeture de \(active.count) tunnel(s).")
        await stopAll()
    }

    private func stopAll() async {
        await supervisor.stopAll()
        active.removeAll()
    }

    private func log(_ change: TunnelSupervisor.StateChange) async {
        let name = active[change.id]?.name ?? change.id.uuidString
        switch change.state {
        case .stopped:
            Log.supervisor.info("« \(name) » arrêté.")
        case .starting:
            Log.supervisor.info("« \(name) » démarre.")
        case .running(let pid, _):
            Log.supervisor.info("« \(name) » actif (pid \(pid)).")
        case .reconnecting(let attempt):
            let reason = await supervisor.lastFailure(for: change.id) ?? "raison inconnue"
            Log.supervisor.error("« \(name) » : reconnexion, tentative \(attempt) — \(reason)")
        case .failed(let reason, _):
            Log.supervisor.error("« \(name) » en échec : \(reason)")
        }
    }
}
