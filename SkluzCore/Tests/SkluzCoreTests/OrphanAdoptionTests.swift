import Foundation
import Testing
@testable import SkluzCore

/// A crashed app or daemon leaves its ssh children running (own process
/// group): the next run must adopt them, not fight them for the port.
struct OrphanAdoptionTests {

    private func environment(ssh: URL) -> TunnelSupervisor.Environment {
        var environment = TunnelSupervisor.Environment.live
        environment.sshExecutable = ssh
        return environment
    }

    /// A long-lived process standing for an orphaned ssh: the system
    /// /bin/sleep (no freshly written executable, see TunnelSupervisorTests).
    private func startFakeOrphan(in dir: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    @Test func registeredOrphanIsAdoptedAndStoppable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzOrphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let orphan = try startFakeOrphan(in: dir)
        defer { if orphan.isRunning { orphan.terminate() } }

        let tunnel = TunnelConfig(name: "sys", mode: .system, type: .localForward, host: "h", user: "u",
                                  keyRef: .managed("k"), localPort: 18000)
        let registry = RuntimePIDStore(url: dir.appendingPathComponent("runtime.json"))
        registry.save([tunnel.id: orphan.processIdentifier])

        let supervisor = TunnelSupervisor(environment: environment(ssh: orphan.executableURL!), pidStore: registry)
        let adopted = await supervisor.adoptOrphans(among: [tunnel])

        #expect(adopted == [tunnel.id])
        guard case .running(let pid, _) = await supervisor.states[tunnel.id] else {
            Issue.record("Expected the orphan to be adopted as running")
            return
        }
        #expect(pid == orphan.processIdentifier)

        await supervisor.stop(id: tunnel.id)
        #expect(!TunnelSupervisor.isAlive(orphan.processIdentifier))
    }

    /// A live root-or-user process at a recycled PID must not be adopted,
    /// and later killed, just because its path ends in "/ssh".
    @Test func processOfAnotherExecutableIsNotAdopted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzOrphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let impostor = try startFakeOrphan(in: dir)
        defer { impostor.terminate() }
        let tunnel = TunnelConfig(name: "sys", mode: .system, type: .localForward, host: "h", user: "u",
                                  keyRef: .managed("k"), localPort: 18000)
        let registry = RuntimePIDStore(url: dir.appendingPathComponent("runtime.json"))
        registry.save([tunnel.id: impostor.processIdentifier])

        // The supervisor launches /usr/bin/ssh; the impostor is another executable.
        let supervisor = TunnelSupervisor(pidStore: registry)
        #expect(await supervisor.adoptOrphans(among: [tunnel]).isEmpty)
        #expect(TunnelSupervisor.isAlive(impostor.processIdentifier))
    }

    @Test func unknownTunnelIsNotAdopted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzOrphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let orphan = try startFakeOrphan(in: dir)
        defer { orphan.terminate() }

        let registry = RuntimePIDStore(url: dir.appendingPathComponent("runtime.json"))
        registry.save([UUID(): orphan.processIdentifier])

        let supervisor = TunnelSupervisor(pidStore: registry)
        #expect(await supervisor.adoptOrphans(among: []).isEmpty)
    }
}
