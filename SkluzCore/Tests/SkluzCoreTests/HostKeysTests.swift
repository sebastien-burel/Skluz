import Foundation
import Testing
import Darwin
@testable import SkluzCore

struct HostKeysTests {

    /// Real-shaped ssh-keyscan output: comments, a duplicate, an unknown type.
    private let keyscanOutput = """
    # dgx.haruni.net:2022 SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20
    [dgx.haruni.net]:2022 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C7okWi0dh2l9GKJl
    [dgx.haruni.net]:2022 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C7okWi0dh2l9GKJl
    [dgx.haruni.net]:2022 ssh-dss AAAAB3NzaC1kc3MAAACBAP
    """

    private func makeLayout() throws -> SystemPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzHosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SystemPaths(baseDirectory: root.appending(path: "Skluz", directoryHint: .isDirectory))
        try SystemLayout.prepare(paths, ownership: .current)
        return paths
    }

    @Test func parseKeepsAllowedDistinctKeys() throws {
        let keys = HostKeys.parse(keyscanOutput)
        #expect(keys.count == 1)
        let key = try #require(keys.first)
        #expect(key.type == "ssh-ed25519")
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(!key.fingerprint.hasSuffix("="))
    }

    @Test func patternFollowsKnownHostsSyntax() {
        #expect(HostKeys.pattern(host: "dgx.haruni.net", port: 22) == "dgx.haruni.net")
        #expect(HostKeys.pattern(host: "dgx.haruni.net", port: 2022) == "[dgx.haruni.net]:2022")
    }

    @Test func trustAppendsOnceAndKeeps644() throws {
        let paths = try makeLayout()
        defer { try? FileManager.default.removeItem(at: paths.baseDirectory.deletingLastPathComponent()) }
        let key = try #require(HostKeys.parse(keyscanOutput).first)

        try HostKeys.trust(type: key.type, key: key.key, host: "dgx.haruni.net", port: 2022, paths, ownership: .current)
        try HostKeys.trust(type: key.type, key: key.key, host: "dgx.haruni.net", port: 2022, paths, ownership: .current)

        let content = try String(contentsOf: paths.knownHostsFile, encoding: .utf8)
        #expect(content == "[dgx.haruni.net]:2022 ssh-ed25519 \(key.key)\n")
        var info = stat()
        lstat(paths.knownHostsFile.path(percentEncoded: false), &info)
        #expect(info.st_mode & 0o777 == 0o644)
    }

    /// The entry must be one ssh itself matches for this host and port.
    @Test func trustedEntryIsFoundBySSHKeygen() throws {
        let paths = try makeLayout()
        defer { try? FileManager.default.removeItem(at: paths.baseDirectory.deletingLastPathComponent()) }
        let key = try #require(HostKeys.parse(keyscanOutput).first)
        try HostKeys.trust(type: key.type, key: key.key, host: "dgx.haruni.net", port: 2022, paths, ownership: .current)

        let output = try ToolRunner.run("/usr/bin/ssh-keygen",
                                        ["-F", "[dgx.haruni.net]:2022", "-f", paths.knownHostsFile.path(percentEncoded: false)])
        #expect(output.status == 0)
    }

    @Test func trustRefusesUnknownTypesBadKeysAndBadHosts() throws {
        let paths = try makeLayout()
        defer { try? FileManager.default.removeItem(at: paths.baseDirectory.deletingLastPathComponent()) }

        #expect(throws: HostKeyError.invalidKey) {
            try HostKeys.trust(type: "ssh-dss", key: "AAAA", host: "h", port: 22, paths, ownership: .current)
        }
        #expect(throws: HostKeyError.invalidKey) {
            try HostKeys.trust(type: "ssh-ed25519", key: "not base64!\nh ssh-ed25519 AAAA", host: "h", port: 22,
                               paths, ownership: .current)
        }
        #expect(throws: TunnelValidationError.self) {
            try HostKeys.trust(type: "ssh-ed25519", key: "AAAA", host: "h\n* ssh-ed25519 AAAA", port: 22,
                               paths, ownership: .current)
        }
        #expect(try String(contentsOf: paths.knownHostsFile, encoding: .utf8).isEmpty)
    }

    @Test func scanRefusesAnOptionAsHost() {
        #expect(throws: TunnelValidationError.self) {
            try HostKeys.scan(host: "-oProxyCommand=touch /tmp/pwn", port: 22)
        }
    }

    @Test func classifiesHostKeyFailures() {
        #expect(HostKeys.failure(inLog: [
            "No ED25519 host key is known for [dgx.haruni.net]:2022 and you have requested strict checking.",
            "Host key verification failed."
        ]) == .hostKeyUnknown)
        #expect(HostKeys.failure(inLog: [
            "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @",
            "Host key verification failed."
        ]) == .hostKeyChanged)
        #expect(HostKeys.failure(inLog: ["Permission denied (publickey)."]) == nil)
    }
}
