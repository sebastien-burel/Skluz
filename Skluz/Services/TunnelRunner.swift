import Foundation

actor TunnelRunner {
    private struct RunningEntry {
        let process: Process
        let stderrPipe: Pipe
        let stdoutPipe: Pipe
    }

    private var running: [UUID: RunningEntry] = [:]
    private var userStoppedIds: Set<UUID> = []
    private var lastStderrLine: [UUID: String] = [:]
    private(set) var states: [UUID: TunnelState] = [:]

    private let logStore: LogStore

    nonisolated let stateChanges: AsyncStream<StateChange>
    private nonisolated let continuation: AsyncStream<StateChange>.Continuation

    struct StateChange: Sendable {
        let id: UUID
        let state: TunnelState
    }

    init(logStore: LogStore) {
        self.logStore = logStore
        var c: AsyncStream<StateChange>.Continuation!
        self.stateChanges = AsyncStream { c = $0 }
        self.continuation = c
    }

    deinit {
        continuation.finish()
    }

    func start(_ tunnel: Tunnel) {
        guard running[tunnel.id] == nil else { return }
        userStoppedIds.remove(tunnel.id)
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
                process: process,
                stderrPipe: stderrPipe,
                stdoutPipe: stdoutPipe
            )
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
        guard let entry = running[id], entry.process.isRunning else { return }
        if case .starting = states[id] {
            emit(.running(pid: entry.process.processIdentifier, since: Date()), for: id)
        }
    }

    func stop(id: UUID) async {
        guard let entry = running[id] else { return }
        userStoppedIds.insert(id)
        let process = entry.process
        guard process.isRunning else { return }

        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func stopAll() async {
        let snapshot = running
        guard !snapshot.isEmpty else { return }

        for id in snapshot.keys {
            userStoppedIds.insert(id)
        }
        for entry in snapshot.values where entry.process.isRunning {
            entry.process.terminate()
        }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && snapshot.values.contains(where: { $0.process.isRunning }) {
            try? await Task.sleep(for: .milliseconds(50))
        }

        for entry in snapshot.values where entry.process.isRunning {
            kill(entry.process.processIdentifier, SIGKILL)
        }
    }

    private func handleTermination(id: UUID, exitCode: Int32) {
        guard let entry = running.removeValue(forKey: id) else { return }
        entry.stderrPipe.fileHandleForReading.readabilityHandler = nil
        entry.stdoutPipe.fileHandleForReading.readabilityHandler = nil

        let stderrTail = lastStderrLine.removeValue(forKey: id)

        if userStoppedIds.remove(id) != nil || exitCode == 0 {
            emit(.stopped, for: id)
        } else {
            emit(.failed(reason: failureReason(exitCode: exitCode, stderrTail: stderrTail), at: Date()), for: id)
        }
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
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
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
        pipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
    }
}
