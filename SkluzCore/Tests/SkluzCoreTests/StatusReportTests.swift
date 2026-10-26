import Foundation
import Testing
@testable import SkluzCore

struct StatusReportTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tunnel(_ name: String, _ phase: TunnelStatus.Phase, enabled: Bool = true,
                        error: String? = nil, upFor seconds: TimeInterval = 0) -> TunnelStatus {
        TunnelStatus(id: UUID(), name: name, localPort: 18000, enabled: enabled, phase: phase,
                     pid: phase == .up ? 42 : nil, since: phase == .up ? now.addingTimeInterval(-seconds) : nil,
                     lastError: error, reconnections: 2)
    }

    private func status(_ tunnels: [TunnelStatus], problem: String? = nil) -> DaemonStatus {
        DaemonStatus(version: "1.0.1", configProblem: problem, tunnels: tunnels)
    }

    // MARK: - check

    @Test func healthyWhenEveryEnabledTunnelIsUp() {
        #expect(StatusReport.isHealthy(status([tunnel("a", .up), tunnel("b", .stopped, enabled: false)])))
        #expect(StatusReport.isHealthy(status([])))
    }

    @Test func unhealthyWhenOneEnabledTunnelIsDown() {
        #expect(!StatusReport.isHealthy(status([tunnel("a", .up), tunnel("b", .reconnecting)])))
        #expect(!StatusReport.isHealthy(status([tunnel("a", .hostKeyUnknown)])))
    }

    @Test func unhealthyWhenTheConfigIsRefused() {
        #expect(!StatusReport.isHealthy(status([], problem: "tunnels.json est en 644")))
    }

    @Test func summaryNamesTheTunnelsDown() {
        #expect(StatusReport.summary(status([tunnel("a", .up), tunnel("b", .reconnecting)]))
                == "KO : 1/2 tunnel(s) système en panne — b (reconnecting)")
        #expect(StatusReport.summary(status([tunnel("a", .up)])) == "OK : 1 tunnel(s) système actif(s)")
    }

    // MARK: - status table

    @Test func tableHasThePlannedColumns() {
        let text = StatusReport.table(status([tunnel("vllm", .up, upFor: 7_500)]), now: now)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "skluzd 1.0.1")
        #expect(lines[1].hasPrefix("NOM") && lines[1].contains("RECONNEXIONS") && lines[1].hasSuffix("DERNIÈRE ERREUR"))
        #expect(lines[2].hasPrefix("vllm  système  up"))
        #expect(lines[2].contains("2 h 05 min"))
    }

    @Test func disabledTunnelsShowAsDisabled() {
        let text = StatusReport.table(status([tunnel("off", .stopped, enabled: false)]), now: now)
        #expect(text.contains("off  système  disabled"))
    }

    /// stderr text partly comes from the server: no terminal escapes.
    @Test func controlCharactersAreNeutralized() {
        let text = StatusReport.table(status([tunnel("x", .reconnecting, error: "evil\u{1B}[2Jbanner\r\nnext")]), now: now)
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\r"))
    }

    @Test func longErrorsAreTruncatedInTheTable() {
        let text = StatusReport.table(status([tunnel("x", .reconnecting, error: String(repeating: "e", count: 200))]), now: now)
        #expect(text.contains(String(repeating: "e", count: 59) + "…"))
    }

    @Test func refusedForwardsShowInTableAndSummary() {
        var refused = tunnel("vLLM", .up, upFor: 60)
        refused.forwardError = "Le serveur refuse la redirection vers localhost:8888"
        let report = status([refused])
        #expect(StatusReport.table(report, now: now).contains("Le serveur refuse la redirection"))
        #expect(StatusReport.summary(report).hasSuffix("redirection refusée par le serveur : vLLM"))
        #expect(StatusReport.isHealthy(report))
    }

    @Test func statusWithoutBuildDecodes() throws {
        let json = #"{"version":"1.0.1","tunnels":[]}"#
        let decoded = try DaemonAPI.decoder().decode(DaemonStatus.self, from: Data(json.utf8))
        #expect(decoded.build == nil)
    }

    @Test func uptimeFormats() {
        #expect(StatusReport.uptime(from: now.addingTimeInterval(-40), to: now) == "40 s")
        #expect(StatusReport.uptime(from: now.addingTimeInterval(-720), to: now) == "12 min")
        #expect(StatusReport.uptime(from: now.addingTimeInterval(-277_200), to: now) == "3 j 5 h")
    }

    /// A daemon from before `enabled` must stay readable by a newer CLI.
    @Test func statusWithoutEnabledFieldDecodes() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"a","localPort":1,"phase":"up","reconnections":0}"#
        let decoded = try DaemonAPI.decoder().decode(TunnelStatus.self, from: Data(json.utf8))
        #expect(decoded.enabled)
    }
}

struct CommandLineLinkTests {

    private func makeTarget() throws -> (dir: URL, target: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SkluzLink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("skluz")
        FileManager.default.createFile(atPath: target.path(percentEncoded: false), contents: Data(),
                                       attributes: [.posixPermissions: 0o755])
        return (dir, target)
    }

    @Test func installsThenIsIdempotent() throws {
        let (dir, target) = try makeTarget()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("bin/skluz")

        try CommandLineLink.install(link: link, target: target)
        try CommandLineLink.install(link: link, target: target)
        #expect(CommandLineLink.isInstalled(link: link, target: target))
    }

    @Test func repointsAStaleLink() throws {
        let (dir, target) = try makeTarget()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("skluz-link")
        try FileManager.default.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: "/old/skluz")

        try CommandLineLink.install(link: link, target: target)
        #expect(CommandLineLink.isInstalled(link: link, target: target))
    }

    @Test func neverReplacesARegularFile() throws {
        let (dir, target) = try makeTarget()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("existing")
        try Data("mine".utf8).write(to: link)

        #expect(throws: CommandLineLinkError.occupied(link.path(percentEncoded: false))) {
            try CommandLineLink.install(link: link, target: target)
        }
        #expect(try String(contentsOf: link, encoding: .utf8) == "mine")
    }
}

struct ForwardFailureTests {
    @Test func messagesAreActionable() {
        #expect(ForwardFailure.isForwardFailure("channel 3: open failed: connect failed: Connection refused"))
        #expect(!ForwardFailure.isForwardFailure("Permission denied (publickey)."))
        #expect(ForwardFailure.message(for: "channel 2: open failed: administratively prohibited: open failed",
                                       remoteHost: "localhost", remotePort: 8888).contains("permitopen"))
        #expect(ForwardFailure.message(for: "channel 3: open failed: connect failed: Connection refused",
                                       remoteHost: "localhost", remotePort: 8888)
                == "Aucun service n'écoute sur localhost:8888 côté serveur : les connexions au tunnel échouent.")
    }
}
