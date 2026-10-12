import Foundation
import Testing
@testable import SkluzCore

/// Runs the real supervisor against a fake ssh (a shell script that ignores
/// its arguments). Backoff sleeps are recorded and shortened, so the
/// schedule is checked without waiting for it.
struct TunnelSupervisorTests {

    // MARK: - Harness

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _delays: [Double] = []
        private var _changes: [TunnelSupervisor.StateChange] = []

        func record(delay: Duration) { lock.withLock { _delays.append(delay.timeInterval) } }
        func record(change: TunnelSupervisor.StateChange) { lock.withLock { _changes.append(change) } }
        var delays: [Double] { lock.withLock { _delays } }
        var states: [TunnelState] { lock.withLock { _changes.map(\.state) } }
    }

    private enum SleepBehavior {
        /// Backoff delays elapse almost at once.
        case fast
        /// Backoff delays never elapse unless the task is cancelled.
        case hang
    }

    private struct Harness {
        let supervisor: TunnelSupervisor
        let recorder: Recorder
        let observer: Task<Void, Never>
    }

    private func makeFakeSSH(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzFakeSSH-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ssh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// `timeScale` speeds up the supervisor's clock, so that a fake ssh living
    /// 0.5 s real counts as 50 s of uptime.
    private func makeHarness(script: String, sleep: SleepBehavior, timeScale: Double = 1) throws -> Harness {
        let recorder = Recorder()
        let start = Date()
        let environment = TunnelSupervisor.Environment(
            sshExecutable: try makeFakeSSH(script),
            systemPaths: .standard,
            now: { start.addingTimeInterval(Date().timeIntervalSince(start) * timeScale) },
            sleep: { delay in
                recorder.record(delay: delay)
                switch sleep {
                case .fast: try await Task.sleep(for: .milliseconds(5))
                case .hang: try await Task.sleep(for: .seconds(3600))
                }
            },
            random: { 0.5 }
        )
        let supervisor = TunnelSupervisor(environment: environment)
        let observer = Task {
            for await change in supervisor.stateChanges {
                recorder.record(change: change)
            }
        }
        return Harness(supervisor: supervisor, recorder: recorder, observer: observer)
    }

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func systemTunnel() -> TunnelConfig {
        TunnelConfig(name: "sys", mode: .system, type: .localForward, host: "h", user: "u",
                     keyRef: .managed("k"), localPort: 18000, remoteHost: "localhost", remotePort: 80)
    }

    private func sessionTunnel(autoRestart: Bool) -> TunnelConfig {
        TunnelConfig(name: "ses", type: .localForward, host: "h", localPort: 18001,
                     remoteHost: "localhost", remotePort: 80, autoRestart: autoRestart)
    }

    // MARK: - Backoff schedules

    @Test func systemBackoffIsExponentialAndNeverGivesUp() async throws {
        let h = try makeHarness(script: "exit 255", sleep: .fast)
        let tunnel = systemTunnel()
        await h.supervisor.start(tunnel)

        try await waitUntil { h.recorder.delays.count >= 9 }
        await h.supervisor.stop(id: tunnel.id)

        #expect(Array(h.recorder.delays.prefix(9)) == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        #expect(!h.recorder.states.contains { if case .failed = $0 { true } else { false } })
        h.observer.cancel()
    }

    @Test func sessionBackoffGivesUpAfterFiveAttempts() async throws {
        let h = try makeHarness(script: "exit 255", sleep: .fast)
        await h.supervisor.start(sessionTunnel(autoRestart: true))

        try await waitUntil {
            h.recorder.states.contains { if case .failed = $0 { true } else { false } }
        }

        #expect(h.recorder.delays == [2, 5, 15, 30, 60])
        guard case .failed(let reason, _) = h.recorder.states.last else {
            Issue.record("Expected a final .failed state")
            return
        }
        #expect(reason.hasPrefix("Reconnexion abandonnée après 5 tentatives."))
        h.observer.cancel()
    }

    @Test func sessionWithoutAutoRestartFailsAtOnce() async throws {
        let h = try makeHarness(script: "exit 255", sleep: .fast)
        await h.supervisor.start(sessionTunnel(autoRestart: false))

        try await waitUntil {
            h.recorder.states.contains { if case .failed = $0 { true } else { false } }
        }
        #expect(h.recorder.delays.isEmpty)
        h.observer.cancel()
    }

    @Test func sessionCleanExitStopsButSystemRestarts() async throws {
        let session = try makeHarness(script: "exit 0", sleep: .fast)
        await session.supervisor.start(sessionTunnel(autoRestart: true))
        try await waitUntil { session.recorder.states.last == .stopped }
        #expect(session.recorder.delays.isEmpty)
        session.observer.cancel()

        let system = try makeHarness(script: "exit 0", sleep: .hang)
        let tunnel = systemTunnel()
        await system.supervisor.start(tunnel)
        try await waitUntil { system.recorder.delays.count == 1 }
        await system.supervisor.stop(id: tunnel.id)
        system.observer.cancel()
    }

    // MARK: - Counter reset after a stable run

    @Test func quickFailuresKeepGrowingTheDelay() async throws {
        let h = try makeHarness(script: "exit 1", sleep: .fast, timeScale: 100)
        let tunnel = systemTunnel()
        await h.supervisor.start(tunnel)
        try await waitUntil { h.recorder.delays.count >= 3 }
        await h.supervisor.stop(id: tunnel.id)

        #expect(Array(h.recorder.delays.prefix(3)) == [1, 2, 4])
        h.observer.cancel()
    }

    @Test func stableRunsResetTheCounter() async throws {
        // 0.5 s real × 100 = 50 s of uptime, beyond the 30 s threshold.
        let h = try makeHarness(script: "sleep 0.5; exit 1", sleep: .fast, timeScale: 100)
        let tunnel = systemTunnel()
        await h.supervisor.start(tunnel)
        try await waitUntil { h.recorder.delays.count >= 3 }
        await h.supervisor.stop(id: tunnel.id)

        #expect(Array(h.recorder.delays.prefix(3)) == [1, 1, 1])
        h.observer.cancel()
    }

    // MARK: - Network events (System mode)

    @Test func networkBackRetriesImmediatelyWithFreshCounter() async throws {
        let h = try makeHarness(script: "exit 255", sleep: .hang)
        let (events, network) = AsyncStream.makeStream(of: NetworkEvent.self)
        await h.supervisor.watchNetwork(events)
        let tunnel = systemTunnel()
        await h.supervisor.start(tunnel)
        try await waitUntil { h.recorder.delays.count == 1 }

        network.yield(.available)
        try await waitUntil { h.recorder.delays.count == 2 }
        await h.supervisor.stop(id: tunnel.id)

        // Without the reset the second delay would be 2 s.
        #expect(h.recorder.delays == [1, 1])
        h.observer.cancel()
    }

    @Test func interfaceChangeRestartsRunningSystemTunnels() async throws {
        let h = try makeHarness(script: "exec sleep 60", sleep: .fast)
        let (events, network) = AsyncStream.makeStream(of: NetworkEvent.self)
        await h.supervisor.watchNetwork(events)
        let tunnel = systemTunnel()
        await h.supervisor.start(tunnel)

        func runningPIDs() -> [Int32] {
            h.recorder.states.compactMap { if case .running(let pid, _) = $0 { pid } else { nil } }
        }
        try await waitUntil { runningPIDs().count == 1 }
        let firstPID = runningPIDs()[0]

        network.yield(.interfacesChanged)
        try await waitUntil { runningPIDs().count == 2 }
        let secondPID = runningPIDs()[1]

        #expect(secondPID != firstPID)
        #expect(!TunnelSupervisor.isAlive(firstPID))
        #expect(h.recorder.delays.isEmpty)
        #expect(!h.recorder.states.contains { if case .reconnecting = $0 { true } else { false } })

        await h.supervisor.stopAll()
        try await waitUntil { !TunnelSupervisor.isAlive(secondPID) }
        h.observer.cancel()
    }

    @Test func sessionTunnelsIgnoreNetworkEvents() async throws {
        let h = try makeHarness(script: "exit 255", sleep: .hang)
        let (events, network) = AsyncStream.makeStream(of: NetworkEvent.self)
        await h.supervisor.watchNetwork(events)
        let tunnel = sessionTunnel(autoRestart: true)
        await h.supervisor.start(tunnel)
        try await waitUntil { h.recorder.delays.count == 1 }

        network.yield(.available)
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.recorder.delays == [2])

        await h.supervisor.stop(id: tunnel.id)
        h.observer.cancel()
    }

    // MARK: - Validation and auto-start

    @Test func invalidTunnelFailsWithoutSpawning() async throws {
        let h = try makeHarness(script: "touch \"$0.spawned\"", sleep: .fast)
        var tunnel = systemTunnel()
        tunnel.host = "-oProxyCommand=touch /tmp/pwn"
        await h.supervisor.start(tunnel)

        try await waitUntil {
            h.recorder.states.contains { if case .failed = $0 { true } else { false } }
        }
        #expect(!h.recorder.states.contains(.starting))
        h.observer.cancel()
    }

    @Test func autoStartSelectsEnabledTunnelsNotAlreadyRunning() {
        let auto = sessionTunnel(autoRestart: false).with { $0.autoStart = true }
        let manual = sessionTunnel(autoRestart: false)
        let disabled = sessionTunnel(autoRestart: false).with { $0.autoStart = true; $0.enabled = false }
        let adopted = sessionTunnel(autoRestart: false).with { $0.autoStart = true }

        let picked = TunnelSupervisor.autoStartCandidates(among: [auto, manual, disabled, adopted],
                                                          alreadyRunning: [adopted.id])
        #expect(picked.map(\.id) == [auto.id])
    }
}

private extension TunnelConfig {
    func with(_ change: (inout TunnelConfig) -> Void) -> TunnelConfig {
        var copy = self
        change(&copy)
        return copy
    }
}
