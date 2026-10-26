import Foundation
import SkluzCore

let daemonVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let daemonBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

enum DaemonError: Error, LocalizedError {
    case invalidRequest(String)
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        case .notFound(let id):            "Aucun tunnel système avec l'identifiant \(id.uuidString)."
        }
    }
}

/// Supervises the enabled System-mode tunnels of the root config.
actor Daemon {
    nonisolated let paths: SystemPaths
    nonisolated let ownership: FileOwnership
    private let supervisor: TunnelSupervisor
    private let logStore = LogStore()
    private var active: [UUID: TunnelConfig] = [:]
    private var configured: [TunnelConfig] = []
    private var reconnections: [UUID: Int] = [:]
    private var hasAdoptedOrphans = false
    /// Why no tunnel runs, when the config was refused.
    private var configProblem: String?

    init(paths: SystemPaths, ownership: FileOwnership) {
        self.paths = paths
        self.ownership = ownership
        var environment = TunnelSupervisor.Environment.live
        environment.systemPaths = paths
        // ssh children run in their own process group: launchd does not kill
        // them with a crashed daemon. The registry lets the next run adopt
        // them instead of failing on their still-bound ports.
        let pidStore = RuntimePIDStore(url: paths.baseDirectory.appending(path: "runtime.json"))
        self.supervisor = TunnelSupervisor(environment: environment, logStore: logStore, pidStore: pidStore)
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

    /// Initial load, `SIGHUP` and every XPC mutation: applies the config, or
    /// stops everything if it can no longer be trusted.
    func reload(reason: String) async {
        let loaded: [TunnelConfig]
        do {
            loaded = try SystemLayout.loadTunnels(paths, ownership: ownership)
        } catch {
            configProblem = error.localizedDescription
            configured = []
            Log.config.error("Configuration refusée (\(reason)), aucun tunnel lancé : \(error.localizedDescription)")
            await stopAll()
            return
        }
        configProblem = nil
        configured = loaded

        for tunnel in loaded where tunnel.mode == .session {
            Log.config.error("« \(tunnel.name) » est en mode Session dans la config système : ignoré.")
        }

        if !hasAdoptedOrphans {
            hasAdoptedOrphans = true
            let candidates = loaded.filter { $0.mode == .system && $0.enabled }
            for id in await supervisor.adoptOrphans(among: candidates) {
                active[id] = candidates.first { $0.id == id }
                Log.supervisor.info("« \(active[id]?.name ?? id.uuidString) » : ssh orphelin réadopté.")
            }
        }

        let plan = TunnelReconciler.plan(active: active, configured: loaded)
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

    // MARK: - XPC

    func listTunnels() -> [TunnelConfig] {
        configured.filter { $0.mode == .system }
    }

    func status() async -> DaemonStatus {
        let states = await supervisor.states
        var tunnels: [TunnelStatus] = []
        for tunnel in listTunnels() {
            var status = TunnelStatus(
                tunnel: tunnel,
                state: active[tunnel.id] == nil ? nil : states[tunnel.id],
                lastError: await supervisor.lastFailure(for: tunnel.id),
                reconnections: reconnections[tunnel.id] ?? 0
            )
            // A host key refusal looks like any reconnection: surface it,
            // the user has to trust (or investigate) the server key.
            if status.phase == .reconnecting || status.phase == .failed,
               status.lastError?.contains("Host key verification failed") == true,
               let issue = HostKeys.failure(inLog: Array(await logStore.lines(for: tunnel.id).suffix(30))) {
                status.phase = issue
            }
            // Past errors of a tunnel that is up again would only mislead;
            // `reconnections` still tells it flapped. Refused forwards are
            // what matters then.
            if status.phase == .up {
                status.lastError = nil
                if let refusal = await supervisor.forwardFailure(for: tunnel.id),
                   Date().timeIntervalSince(refusal.at) < ForwardFailure.window {
                    status.forwardError = ForwardFailure.message(
                        for: refusal.line,
                        remoteHost: tunnel.remoteHost ?? "localhost",
                        remotePort: tunnel.remotePort ?? tunnel.localPort)
                }
            }
            tunnels.append(status)
        }
        return DaemonStatus(version: daemonVersion, build: daemonBuild, configProblem: configProblem, tunnels: tunnels)
    }

    func upsert(_ tunnel: TunnelConfig) async throws {
        guard tunnel.mode == .system else {
            throw DaemonError.invalidRequest("Le service système n'accepte que des tunnels en mode Système.")
        }
        // Same validation as at launch, before anything is written.
        _ = try SSHCommandBuilder.arguments(for: tunnel, paths: paths)
        try await mutate("ajout/modification de « \(tunnel.name) »") { tunnels in
            if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
                tunnels[index] = tunnel
            } else {
                tunnels.append(tunnel)
            }
        }
    }

    func delete(id: UUID) async throws {
        try await mutate("suppression de \(id.uuidString)") { tunnels in
            guard tunnels.contains(where: { $0.id == id }) else { throw DaemonError.notFound(id) }
            tunnels.removeAll { $0.id == id }
        }
    }

    func setEnabled(id: UUID, _ enabled: Bool) async throws {
        try await mutate("\(enabled ? "activation" : "désactivation") de \(id.uuidString)") { tunnels in
            guard let index = tunnels.firstIndex(where: { $0.id == id }) else { throw DaemonError.notFound(id) }
            tunnels[index].enabled = enabled
        }
    }

    /// Uninstall: no tunnel may outlive the service, then the root files go.
    func purge() async throws {
        Log.config.info("Désinstallation demandée : arrêt des tunnels et suppression de la configuration.")
        await stopAll()
        configured = []
        hasAdoptedOrphans = true
        do {
            try FileManager.default.removeItem(at: paths.baseDirectory)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        }
    }

    /// After a host key was trusted: retry its tunnels now rather than after
    /// their backoff.
    func retryTunnels(host: String, port: Int) async {
        let states = await supervisor.states
        for tunnel in active.values where tunnel.host == host && (tunnel.port ?? 22) == port {
            if case .running = states[tunnel.id] { continue }
            Log.supervisor.info("« \(tunnel.name) » : clé d'hôte approuvée, nouvelle tentative.")
            await supervisor.start(tunnel)
        }
    }

    /// Read, change and atomically write the config, without suspension
    /// between the read and the write, then apply it.
    private func mutate(_ what: String, _ change: (inout [TunnelConfig]) throws -> Void) async throws {
        var tunnels = try SystemLayout.loadTunnels(paths, ownership: ownership)
        try change(&tunnels)
        try SystemLayout.saveTunnels(tunnels, paths, ownership: ownership)
        Log.config.info("Configuration modifiée par XPC : \(what).")
        await reload(reason: "XPC")
    }

    // MARK: - Helpers

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
            reconnections[change.id, default: 0] += 1
            let reason = await supervisor.lastFailure(for: change.id) ?? "raison inconnue"
            Log.supervisor.error("« \(name) » : reconnexion, tentative \(attempt) — \(reason)")
        case .failed(let reason, _):
            Log.supervisor.error("« \(name) » en échec : \(reason)")
        }
    }
}
