import Foundation
import Testing
import Darwin
@testable import SkluzCore

/// Runs as the current user: the expected owner is injected, so the same
/// checks apply as for root in production.
struct SystemLayoutTests {

    private func makePaths() -> SystemPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzLayout-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SystemPaths(baseDirectory: root.appending(path: "Skluz", directoryHint: .isDirectory))
    }

    private func cleanup(_ paths: SystemPaths) {
        try? FileManager.default.removeItem(at: paths.baseDirectory.deletingLastPathComponent())
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        lstat(url.path(percentEncoded: false), &info)
        return info.st_mode & 0o777
    }

    private func issue(_ paths: SystemPaths, ownership: FileOwnership = .current) -> SystemLayoutProblem.Issue? {
        do {
            try SystemLayout.prepare(paths, ownership: ownership)
            return nil
        } catch let problem as SystemLayoutProblem {
            return problem.issue
        } catch {
            Issue.record("Unexpected error \(error)")
            return nil
        }
    }

    @Test func firstStartCreatesLayoutWithExpectedModes() async throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let tunnels = try await SystemLayout.loadTunnels(paths, ownership: .current)

        #expect(tunnels.isEmpty)
        #expect(mode(paths.baseDirectory) == 0o755)
        #expect(mode(paths.keysDirectory) == 0o700)
        #expect(mode(paths.tunnelsFile) == 0o600)
        #expect(mode(paths.knownHostsFile) == 0o644)
    }

    @Test func secondStartKeepsExistingFiles() async throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try SystemLayout.prepare(paths, ownership: .current)
        try Data("dgx ssh-ed25519 AAAA\n".utf8).write(to: paths.knownHostsFile)

        try SystemLayout.prepare(paths, ownership: .current)
        #expect(try String(contentsOf: paths.knownHostsFile, encoding: .utf8) == "dgx ssh-ed25519 AAAA\n")
    }

    @Test func readableTunnelsFileIsRefused() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try SystemLayout.prepare(paths, ownership: .current)
        chmod(paths.tunnelsFile.path(percentEncoded: false), 0o644)

        #expect(issue(paths) == .tooPermissive(mode: 0o644, expected: 0o600))
    }

    @Test func refusalMessageGivesTheFixCommand() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try SystemLayout.prepare(paths, ownership: .current)
        chmod(paths.tunnelsFile.path(percentEncoded: false), 0o644)

        #expect(throws: SystemLayoutProblem.self) {
            try SystemLayout.prepare(paths, ownership: .current)
        }
        do {
            try SystemLayout.prepare(paths, ownership: .current)
        } catch {
            #expect(error.localizedDescription.contains("sudo chmod 600"))
        }
    }

    @Test func symlinkedTunnelsFileIsRefused() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try SystemLayout.prepare(paths, ownership: .current)
        let elsewhere = paths.baseDirectory.deletingLastPathComponent().appending(path: "elsewhere.json")
        try SystemLayout.emptyTunnelsFile.write(to: elsewhere)
        try FileManager.default.removeItem(at: paths.tunnelsFile)
        try FileManager.default.createSymbolicLink(at: paths.tunnelsFile, withDestinationURL: elsewhere)

        #expect(issue(paths) == .symbolicLink)
    }

    @Test func groupWritableBaseDirectoryIsRefused() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try SystemLayout.prepare(paths, ownership: .current)
        chmod(paths.baseDirectory.path(percentEncoded: false), 0o775)

        #expect(issue(paths) == .tooPermissive(mode: 0o775, expected: 0o755))
    }

    @Test func openKeysDirectoryIsRefused() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try SystemLayout.prepare(paths, ownership: .current)
        chmod(paths.keysDirectory.path(percentEncoded: false), 0o755)

        #expect(issue(paths) == .tooPermissive(mode: 0o755, expected: 0o700))
    }

    @Test func readablePrivateKeyIsRefusedButPublicHalfIsFine() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try SystemLayout.prepare(paths, ownership: .current)
        let key = paths.keyFile(named: "dgx")
        let pub = paths.keyFile(named: "dgx.pub")
        FileManager.default.createFile(atPath: key.path(percentEncoded: false), contents: Data("k".utf8),
                                       attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: pub.path(percentEncoded: false), contents: Data("p".utf8),
                                       attributes: [.posixPermissions: 0o644])
        #expect(issue(paths) == nil)

        chmod(key.path(percentEncoded: false), 0o640)
        #expect(issue(paths) == .tooPermissive(mode: 0o640, expected: 0o600))
    }

    @Test func foreignOwnerIsRefused() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try SystemLayout.prepare(paths, ownership: .current)

        let someoneElse = FileOwnership(uid: getuid() + 1, gid: getgid())
        #expect(issue(paths, ownership: someoneElse) == .wrongOwner(uid: getuid()))
    }

    // MARK: - Writes (XPC mutations)

    @Test func savedTunnelsStay600AndRoundTrip() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try SystemLayout.prepare(paths, ownership: .current)
        let tunnel = TunnelConfig(name: "vllm", mode: .system, type: .localForward, host: "dgx.haruni.net",
                                  user: "sb", port: 2022, keyRef: .managed("vllm"), localPort: 18000,
                                  remoteHost: "localhost", remotePort: 8000)

        try SystemLayout.saveTunnels([tunnel], paths, ownership: .current)

        #expect(mode(paths.tunnelsFile) == 0o600)
        #expect(try SystemLayout.loadTunnels(paths, ownership: .current) == [tunnel])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.baseDirectory.path(percentEncoded: false))
            .filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func savingReplacesASymlinkInsteadOfWritingThroughIt() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try SystemLayout.prepare(paths, ownership: .current)
        let victim = paths.baseDirectory.deletingLastPathComponent().appending(path: "victim")
        try Data("intact".utf8).write(to: victim)
        try FileManager.default.removeItem(at: paths.tunnelsFile)
        try FileManager.default.createSymbolicLink(at: paths.tunnelsFile, withDestinationURL: victim)

        try SystemLayout.saveTunnels([], paths, ownership: .current)

        #expect(try String(contentsOf: victim, encoding: .utf8) == "intact")
        #expect(mode(paths.tunnelsFile) == 0o600)
    }
}
