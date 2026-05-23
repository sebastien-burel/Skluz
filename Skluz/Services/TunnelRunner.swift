import Foundation
import Darwin

actor TunnelRunner {
    /// Un tunnel actif : soit un process que nous avons lancé (`process != nil`),
    /// soit un process ssh adopté après un crash de Skluz (`process == nil`,
    /// surveillé par polling via `monitor`).
    private struct RunningEntry {
        let pid: Int32
        let process: Process?
        let stderrPipe: Pipe?
        let stdoutPipe: Pipe?
        var monitor: Task<Void, Never>?
    }

    /// Backoff entre tentatives de reconnexion, en secondes (plan §6).
    /// Le nombre d'entrées définit aussi le plafond de tentatives consécutives.
    static let backoffSeconds: [Int] = [2, 5, 15, 30, 60]

    /// Délai avant la tentative `attempt` (1-indexé), ou `nil` si on a dépassé le plafond.
    static func backoffDelay(forAttempt attempt: Int) -> Int? {
        guard attempt >= 1, attempt <= backoffSeconds.count else { return nil }
        return backoffSeconds[attempt - 1]
    }

    private var running: [UUID: RunningEntry] = [:]
    private var tunnelsById: [UUID: Tunnel] = [:]
    private var userStoppedIds: Set<UUID> = []
    private var lastStderrLine: [UUID: String] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var states: [UUID: TunnelState] = [:]

    private let logStore: LogStore
    private let pidStore: RuntimePIDStore

    nonisolated let stateChanges: AsyncStream<StateChange>
    private nonisolated let continuation: AsyncStream<StateChange>.Continuation

    struct StateChange: Sendable {
        let id: UUID
        let state: TunnelState
    }

    init(logStore: LogStore, pidStore: RuntimePIDStore = RuntimePIDStore()) {
        self.logStore = logStore
        self.pidStore = pidStore
        var c: AsyncStream<StateChange>.Continuation!
        self.stateChanges = AsyncStream { c = $0 }
        self.continuation = c
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Public API

    /// Démarrage manuel : remet à zéro le compteur de reconnexion.
    func start(_ tunnel: Tunnel) {
        cancelReconnect(id: tunnel.id)
        reconnectAttempts[tunnel.id] = 0
        userStoppedIds.remove(tunnel.id)
        spawn(tunnel)
    }

    func stop(id: UUID) async {
        cancelReconnect(id: id)
        reconnectAttempts[id] = 0

        guard let entry = running[id] else {
            if case .reconnecting = states[id] {
                userStoppedIds.remove(id)
                emit(.stopped, for: id)
            }
            return
        }

        userStoppedIds.insert(id)
        entry.monitor?.cancel()

        if let process = entry.process {
            guard process.isRunning else {
                running.removeValue(forKey: id)
                writeRegistry()
                return
            }
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        } else {
            // Process adopté : pas d'objet Process, on signale par PID.
            kill(entry.pid, SIGTERM)
            let deadline = Date().addingTimeInterval(3)
            while Self.isAlive(entry.pid) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if Self.isAlive(entry.pid) {
                kill(entry.pid, SIGKILL)
            }
            running.removeValue(forKey: id)
            emit(.stopped, for: id)
            writeRegistry()
        }
    }

    func stopAll() async {
        for id in reconnectTasks.keys {
            cancelReconnect(id: id)
        }

        let snapshot = running
        guard !snapshot.isEmpty else { return }

        for (id, entry) in snapshot {
            userStoppedIds.insert(id)
            entry.monitor?.cancel()
        }
        for entry in snapshot.values {
            if let process = entry.process {
                if process.isRunning { process.terminate() }
            } else {
                kill(entry.pid, SIGTERM)
            }
        }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && snapshot.values.contains(where: { Self.isAlive($0.pid) }) {
            try? await Task.sleep(for: .milliseconds(50))
        }

        for entry in snapshot.values where Self.isAlive(entry.pid) {
            kill(entry.pid, SIGKILL)
        }

        for id in snapshot.keys where running[id]?.process == nil {
            running.removeValue(forKey: id)
        }
        writeRegistry()
    }

    /// À appeler au démarrage : réadopte les ssh orphelins survivant à un
    /// crash/SIGKILL de Skluz, en validant le PID contre la liste connue.
    func adoptOrphans(among tunnels: [Tunnel]) {
        let registry = pidStore.load()
        guard !registry.isEmpty else { return }

        for (id, pid) in registry {
            guard running[id] == nil,
                  let tunnel = tunnels.first(where: { $0.id == id }),
                  Self.isAlive(pid),
                  let path = Self.executablePath(pid: pid),
                  path.hasSuffix("/ssh") else {
                continue
            }
            tunnelsById[id] = tunnel
            let monitor = makeAdoptedMonitor(id: id, pid: pid)
            running[id] = RunningEntry(pid: pid, process: nil,
                                       stderrPipe: nil, stdoutPipe: nil, monitor: monitor)
            emit(.running(pid: pid, since: Date()), for: id)
        }
        writeRegistry()
    }

    // MARK: - Process lifecycle

    private func spawn(_ tunnel: Tunnel) {
        guard running[tunnel.id] == nil else { return }
        tunnelsById[tunnel.id] = tunnel
        lastStderrLine.removeValue(forKey: tunnel.id)
        emit(.starting, for: tunnel.id)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommandBuilder.sshPath)
        process.arguments = SSHCommandBuilder.arguments(for: tunnel)

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        attachStderrReader(stderrPipe, tunnelId: tunnel.id)
        attachStdoutDrain(stdoutPipe)

        let tunnelId = tunnel.id
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { [weak self] in
                await self?.handleTermination(id: tunnelId, exitCode: code)
            }
        }

        do {
            try process.run()
            running[tunnel.id] = RunningEntry(
                pid: process.processIdentifier,
                process: process,
                stderrPipe: stderrPipe,
                stdoutPipe: stdoutPipe,
                monitor: nil
            )
            writeRegistry()
            let id = tunnel.id
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                await self?.confirmRunning(id: id)
            }
        } catch {
            emit(.failed(reason: error.localizedDescription, at: Date()), for: tunnel.id)
        }
    }

    private func confirmRunning(id: UUID) {
        guard let entry = running[id], let process = entry.process, process.isRunning else { return }
        if case .starting = states[id] {
            reconnectAttempts[id] = 0
            emit(.running(pid: process.processIdentifier, since: Date()), for: id)
        }
    }

    private func handleTermination(id: UUID, exitCode: Int32) {
        guard let entry = running.removeValue(forKey: id) else { return }
        entry.stderrPipe?.fileHandleForReading.readabilityHandler = nil
        entry.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        writeRegistry()

        let stderrTail = lastStderrLine.removeValue(forKey: id)

        if userStoppedIds.remove(id) != nil || exitCode == 0 {
            emit(.stopped, for: id)
            return
        }

        let reason = failureReason(exitCode: exitCode, stderrTail: stderrTail)
        guard let tunnel = tunnelsById[id], tunnel.autoRestart else {
            emit(.failed(reason: reason, at: Date()), for: id)
            return
        }
        scheduleReconnect(tunnel: tunnel, lastReason: reason)
    }

    /// Mort détectée par polling pour un process adopté (pas de terminationHandler).
    private func handleAdoptedDeath(id: UUID) {
        guard running.removeValue(forKey: id) != nil else { return }
        writeRegistry()

        if userStoppedIds.remove(id) != nil {
            emit(.stopped, for: id)
            return
        }
        let reason = "Connexion perdue (process ssh adopté terminé)."
        guard let tunnel = tunnelsById[id], tunnel.autoRestart else {
            emit(.failed(reason: reason, at: Date()), for: id)
            return
        }
        scheduleReconnect(tunnel: tunnel, lastReason: reason)
    }

    private func makeAdoptedMonitor(id: UUID, pid: Int32) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                if !Self.isAlive(pid) {
                    await self?.handleAdoptedDeath(id: id)
                    return
                }
            }
        }
    }

    // MARK: - Auto-restart (backoff exponentiel)

    private func scheduleReconnect(tunnel: Tunnel, lastReason: String) {
        let id = tunnel.id
        let attempt = (reconnectAttempts[id] ?? 0) + 1

        guard let delay = Self.backoffDelay(forAttempt: attempt) else {
            reconnectAttempts[id] = 0
            emit(.failed(
                reason: "Reconnexion abandonnée après \(Self.backoffSeconds.count) tentatives. \(lastReason)",
                at: Date()
            ), for: id)
            return
        }

        reconnectAttempts[id] = attempt
        emit(.reconnecting(attempt: attempt), for: id)

        reconnectTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            await self?.performReconnect(id: id)
        }
    }

    private func performReconnect(id: UUID) {
        reconnectTasks[id] = nil
        guard !userStoppedIds.contains(id) else { return }
        guard case .reconnecting = states[id] else { return }
        guard let tunnel = tunnelsById[id] else { return }
        spawn(tunnel)
    }

    private func cancelReconnect(id: UUID) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
    }

    // MARK: - Helpers

    private func writeRegistry() {
        var map: [UUID: Int32] = [:]
        for (id, entry) in running {
            map[id] = entry.pid
        }
        pidStore.save(map)
    }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func failureReason(exitCode: Int32, stderrTail: String?) -> String {
        if let tail = stderrTail, !tail.isEmpty {
            return tail
        }
        if exitCode == 255 {
            return "ssh a échoué (code 255) — port local occupé, host inaccessible ou clé refusée."
        }
        return "ssh sortie avec code \(exitCode)."
    }

    fileprivate func recordStderr(_ line: String, for id: UUID) {
        lastStderrLine[id] = line
    }

    private func emit(_ state: TunnelState, for id: UUID) {
        states[id] = state
        continuation.yield(StateChange(id: id, state: state))
    }

    private func attachStderrReader(_ pipe: Pipe, tunnelId: UUID) {
        let logStore = self.logStore
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF : sans cette garde, la dispatch source reste « lisible »
            // après fermeture du pipe et le handler boucle à vide (~100 % CPU).
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = String(raw)
                guard !line.isEmpty else { continue }
                Task { [weak self] in
                    await logStore.append(line, for: tunnelId)
                    await self?.recordStderr(line, for: tunnelId)
                }
            }
        }
    }

    private func attachStdoutDrain(_ pipe: Pipe) {
        // ssh -N n'écrit pas sur stdout mais on draine pour éviter SIGPIPE.
        // Même garde EOF que pour stderr : un pipe fermé reste signalé lisible
        // indéfiniment, et `availableData` renvoie vide en boucle.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }
}
