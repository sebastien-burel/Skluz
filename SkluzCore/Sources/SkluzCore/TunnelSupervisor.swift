import Foundation
import Darwin

/// Runs and watches the ssh processes of tunnels: start/stop, stderr capture,
/// restart per `RestartPolicy`, reaction to network changes (System mode).
public actor TunnelSupervisor {
    /// Side effects the supervisor depends on, injectable for tests.
    public struct Environment: Sendable {
        /// Always `/usr/bin/ssh` in production (`.live`). Overridden only by
        /// tests, which run a fake ssh script.
        public var sshExecutable: URL
        /// Put before the ssh arguments; empty in production. Tests run
        /// `/bin/sh <script>`: launching a freshly written script directly
        /// can leave it suspended in macOS's launch assessment.
        public var leadingArguments: [String]
        public var systemPaths: SystemPaths
        public var now: @Sendable () -> Date
        public var sleep: @Sendable (Duration) async throws -> Void
        /// Uniform value in `0..<1`, used for the System-mode jitter.
        public var random: @Sendable () -> Double

        public init(
            sshExecutable: URL,
            leadingArguments: [String] = [],
            systemPaths: SystemPaths,
            now: @escaping @Sendable () -> Date,
            sleep: @escaping @Sendable (Duration) async throws -> Void,
            random: @escaping @Sendable () -> Double
        ) {
            self.sshExecutable = sshExecutable
            self.leadingArguments = leadingArguments
            self.systemPaths = systemPaths
            self.now = now
            self.sleep = sleep
            self.random = random
        }

        public static let live = Environment(
            sshExecutable: URL(fileURLWithPath: SSHCommandBuilder.sshPath),
            systemPaths: .standard,
            now: { Date() },
            sleep: { try await Task.sleep(for: $0) },
            random: { Double.random(in: 0..<1) }
        )
    }

    public struct StateChange: Sendable {
        public let id: UUID
        public let state: TunnelState
    }

    /// Un tunnel actif : soit un process que nous avons lancé (`process != nil`),
    /// soit un process ssh adopté après un crash de Skluz (`process == nil`,
    /// surveillé par polling via `monitor`).
    private struct RunningEntry {
        let pid: Int32
        let process: Process?
        let stderrPipe: Pipe?
        let stderr: StderrCapture?
        let stdoutPipe: Pipe?
        let startedAt: Date
        var monitor: Task<Void, Never>?
    }

    private var running: [UUID: RunningEntry] = [:]
    private var tunnelsById: [UUID: TunnelConfig] = [:]
    private var userStoppedIds: Set<UUID> = []
    /// Tunnels killed on purpose to be respawned at once (network change).
    private var immediateRestartIds: Set<UUID> = []
    /// Why the last run of each tunnel ended, kept across reconnections.
    private var lastFailures: [UUID: String] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var networkTask: Task<Void, Never>?
    public private(set) var states: [UUID: TunnelState] = [:]

    private let environment: Environment
    private let logStore: LogStore?
    private let pidStore: RuntimePIDStore?

    public nonisolated let stateChanges: AsyncStream<StateChange>
    private nonisolated let continuation: AsyncStream<StateChange>.Continuation

    /// `pidStore` enables orphan adoption; leave it `nil` where ssh children
    /// cannot outlive the process (the daemon) and in tests.
    public init(environment: Environment = .live, logStore: LogStore? = nil, pidStore: RuntimePIDStore? = nil) {
        self.environment = environment
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
    public func start(_ tunnel: TunnelConfig) {
        cancelReconnect(id: tunnel.id)
        reconnectAttempts[tunnel.id] = 0
        userStoppedIds.remove(tunnel.id)
        spawn(tunnel)
    }

    public func stop(id: UUID) async {
        cancelReconnect(id: id)
        reconnectAttempts[id] = 0
        immediateRestartIds.remove(id)

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

    public func stopAll() async {
        for id in reconnectTasks.keys {
            cancelReconnect(id: id)
        }
        immediateRestartIds.removeAll()

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
    /// Children get their own process group, so neither the app's exit nor
    /// launchd's cleanup of the daemon kills them.
    @discardableResult
    public func adoptOrphans(among tunnels: [TunnelConfig]) -> [UUID] {
        guard let registry = pidStore?.load(), !registry.isEmpty else { return [] }

        var adopted: [UUID] = []
        for (id, pid) in registry {
            guard running[id] == nil,
                  let tunnel = tunnels.first(where: { $0.id == id }),
                  Self.isAlive(pid),
                  // Exactly the binary we launch (/usr/bin/ssh in production),
                  // not any process whose path merely ends in "ssh".
                  Self.executablePath(pid: pid) == Self.canonicalPath(environment.sshExecutable),
                  // A recycled PID may belong to someone else's ssh: never
                  // adopt (and later kill) it, above all as root.
                  Self.ownerUID(pid: pid) == getuid() else {
                continue
            }
            adopted.append(id)
            tunnelsById[id] = tunnel
            let monitor = makeAdoptedMonitor(id: id, pid: pid)
            running[id] = RunningEntry(pid: pid, process: nil, stderrPipe: nil, stderr: nil, stdoutPipe: nil,
                                       startedAt: environment.now(), monitor: monitor)
            emit(.running(pid: pid, since: environment.now()), for: id)
        }
        writeRegistry()
        return adopted
    }

    /// À appeler au démarrage, après `adoptOrphans` : lance les tunnels marqués
    /// « Démarrer au lancement » qui ne tournent pas déjà.
    public func startAutoStartTunnels(among tunnels: [TunnelConfig]) {
        for tunnel in Self.autoStartCandidates(among: tunnels, alreadyRunning: Set(running.keys)) {
            start(tunnel)
        }
    }

    /// Tunnels à démarrer au lancement : `autoStart` et activés, en excluant
    /// ceux déjà actifs (un orphelin réadopté occupe déjà son port local).
    public static func autoStartCandidates(among tunnels: [TunnelConfig], alreadyRunning: Set<UUID>) -> [TunnelConfig] {
        tunnels.filter { $0.autoStart && $0.enabled && !alreadyRunning.contains($0.id) }
    }

    /// Reacts to network changes for System-mode tunnels (the daemon passes
    /// `NetworkMonitor.events()`; the Session app does not watch the network).
    /// Why the last run of `id` ended, if it failed. A System-mode tunnel never
    /// reaches `.failed`: this is where its ssh errors surface.
    public func lastFailure(for id: UUID) -> String? {
        lastFailures[id]
    }

    public func watchNetwork(_ events: AsyncStream<NetworkEvent>) {
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            for await event in events {
                await self?.handleNetwork(event)
            }
        }
    }

    // MARK: - Process lifecycle

    private func spawn(_ tunnel: TunnelConfig) {
        guard running[tunnel.id] == nil else { return }
        tunnelsById[tunnel.id] = tunnel

        let arguments: [String]
        do {
            arguments = try SSHCommandBuilder.arguments(for: tunnel, paths: environment.systemPaths)
        } catch {
            emit(.failed(reason: error.localizedDescription, at: environment.now()), for: tunnel.id)
            return
        }
        emit(.starting, for: tunnel.id)

        let process = Process()
        process.executableURL = environment.sshExecutable
        process.arguments = environment.leadingArguments + arguments

        // ssh never needs input (-N, BatchMode); a daemon run from a terminal
        // must not hand it the tty.
        process.standardInput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        let stderr = StderrCapture()
        attachStderrReader(stderrPipe, capture: stderr, tunnelId: tunnel.id)
        attachStdoutDrain(stdoutPipe)

        let tunnelId = tunnel.id
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { [weak self] in
                // The exit can be reported before the reader got the last
                // stderr bytes: wait for EOF so the failure reason is complete
                // (bounded, in case another process still holds the pipe).
                await stderr.waitUntilFinished(timeout: .milliseconds(500))
                await self?.handleTermination(id: tunnelId, exitCode: code)
            }
        }

        do {
            try process.run()
            running[tunnel.id] = RunningEntry(
                pid: process.processIdentifier,
                process: process,
                stderrPipe: stderrPipe,
                stderr: stderr,
                stdoutPipe: stdoutPipe,
                startedAt: environment.now(),
                monitor: nil
            )
            writeRegistry()
            let id = tunnel.id
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                await self?.confirmRunning(id: id)
            }
        } catch {
            emit(.failed(reason: error.localizedDescription, at: environment.now()), for: tunnel.id)
        }
    }

    private func confirmRunning(id: UUID) {
        guard let entry = running[id], let process = entry.process, process.isRunning else { return }
        if case .starting = states[id] {
            emit(.running(pid: process.processIdentifier, since: environment.now()), for: id)
        }
    }

    private func handleTermination(id: UUID, exitCode: Int32) {
        guard let entry = running.removeValue(forKey: id) else { return }
        entry.stderrPipe?.fileHandleForReading.readabilityHandler = nil
        entry.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        writeRegistry()

        let stderrTail = entry.stderr?.lastLine
        finishRun(id: id, startedAt: entry.startedAt, exitCode: exitCode,
                  reason: failureReason(exitCode: exitCode, stderrTail: stderrTail))
    }

    /// Mort détectée par polling pour un process adopté (pas de terminationHandler).
    private func handleAdoptedDeath(id: UUID) {
        guard let entry = running.removeValue(forKey: id) else { return }
        writeRegistry()
        finishRun(id: id, startedAt: entry.startedAt, exitCode: nil,
                  reason: "Connexion perdue (process ssh adopté terminé).")
    }

    private func finishRun(id: UUID, startedAt: Date, exitCode: Int32?, reason: String) {
        if userStoppedIds.remove(id) != nil {
            emit(.stopped, for: id)
            return
        }
        guard let tunnel = tunnelsById[id] else {
            emit(.stopped, for: id)
            return
        }
        if immediateRestartIds.remove(id) != nil {
            reconnectAttempts[id] = 0
            spawn(tunnel)
            return
        }
        // Any exit we did not ask for, even with status 0: ssh exits 0 on
        // SIGTERM, so an external kill would otherwise leave no trace.
        lastFailures[id] = reason
        guard RestartPolicy.shouldRestart(mode: tunnel.mode, autoRestart: tunnel.autoRestart, exitCode: exitCode) else {
            emit(exitCode == 0 ? .stopped : .failed(reason: reason, at: environment.now()), for: id)
            return
        }
        let uptime = environment.now().timeIntervalSince(startedAt)
        let attempt = RestartPolicy.nextAttempt(previous: reconnectAttempts[id] ?? 0, uptime: uptime)
        scheduleReconnect(tunnel: tunnel, attempt: attempt, lastReason: reason)
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

    // MARK: - Auto-restart

    private func scheduleReconnect(tunnel: TunnelConfig, attempt: Int, lastReason: String) {
        let id = tunnel.id
        guard let delay = RestartPolicy.delay(forAttempt: attempt, mode: tunnel.mode,
                                              random: environment.random()) else {
            reconnectAttempts[id] = 0
            emit(.failed(
                reason: "Reconnexion abandonnée après \(RestartPolicy.sessionSchedule.count) tentatives. \(lastReason)",
                at: environment.now()
            ), for: id)
            return
        }

        reconnectAttempts[id] = attempt
        emit(.reconnecting(attempt: attempt), for: id)

        let sleep = environment.sleep
        reconnectTasks[id] = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
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

    // MARK: - Network (System mode)

    private func handleNetwork(_ event: NetworkEvent) {
        switch event {
        case .available:
            // Back online: retry now instead of waiting out a long backoff.
            for id in Array(reconnectTasks.keys) {
                guard let tunnel = tunnelsById[id], tunnel.mode == .system else { continue }
                cancelReconnect(id: id)
                reconnectAttempts[id] = 0
                spawn(tunnel)
            }
        case .interfacesChanged:
            // The TCP connections are likely dead but ssh would only notice
            // after ServerAlive (45 s): restart the running tunnels now.
            for (id, entry) in running {
                guard tunnelsById[id]?.mode == .system else { continue }
                immediateRestartIds.insert(id)
                if let process = entry.process {
                    if process.isRunning { process.terminate() }
                } else {
                    kill(entry.pid, SIGTERM)
                }
            }
        case .lost:
            break
        }
    }

    // MARK: - Helpers

    private func writeRegistry() {
        guard let pidStore else { return }
        var map: [UUID: Int32] = [:]
        for (id, entry) in running {
            map[id] = entry.pid
        }
        pidStore.save(map)
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// `realpath`, comparable with `proc_pidpath` (Foundation's
    /// `resolvingSymlinksInPath` strips `/private`, `proc_pidpath` keeps it).
    static func canonicalPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func ownerUID(pid: Int32) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func failureReason(exitCode: Int32, stderrTail: String?) -> String {
        if let tail = stderrTail, !tail.isEmpty {
            return tail
        }
        if exitCode == 255 {
            return "ssh a échoué (code 255) — port local occupé, host inaccessible ou clé refusée."
        }
        if exitCode == 0 {
            return "ssh s'est arrêté sans erreur (code 0) — processus tué ou connexion fermée par le serveur."
        }
        return "ssh sortie avec code \(exitCode)."
    }


    private func emit(_ state: TunnelState, for id: UUID) {
        states[id] = state
        continuation.yield(StateChange(id: id, state: state))
    }

    private func attachStderrReader(_ pipe: Pipe, capture: StderrCapture, tunnelId: UUID) {
        let logStore = self.logStore
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // EOF : sans cette garde, la dispatch source reste « lisible »
            // après fermeture du pipe et le handler boucle à vide (~100 % CPU).
            if data.isEmpty {
                handle.readabilityHandler = nil
                capture.finish()
                return
            }
            // Recorded synchronously, so that the failure reason is complete
            // when the exit is handled; only the log copy is asynchronous.
            let lines = capture.absorb(data)
            if let logStore, !lines.isEmpty {
                Task {
                    for line in lines { await logStore.append(line, for: tunnelId) }
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

/// stderr of one ssh run, written by the pipe reader and read at exit.
final class StderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastLine: String?
    private var _isFinished = false

    var lastLine: String? { lock.withLock { _lastLine } }

    /// EOF reached: every line ssh wrote has been recorded.
    func finish() {
        lock.withLock { _isFinished = true }
    }

    func waitUntilFinished(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while !lock.withLock({ _isFinished }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Records a chunk and returns its non-empty lines.
    func absorb(_ data: Data) -> [String] {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        if let last = lines.last {
            lock.withLock { _lastLine = last }
        }
        return lines
    }
}
