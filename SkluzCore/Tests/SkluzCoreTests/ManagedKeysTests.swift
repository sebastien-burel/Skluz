import Foundation
import Testing
import Darwin
@testable import SkluzCore

/// Uses the real ssh-keygen in a temporary layout owned by the current user.
struct ManagedKeysTests {

    private func makeLayout() throws -> SystemPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkluzKeys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SystemPaths(baseDirectory: root.appending(path: "Skluz", directoryHint: .isDirectory))
        try SystemLayout.prepare(paths, ownership: .current)
        return paths
    }

    private func cleanup(_ paths: SystemPaths) {
        try? FileManager.default.removeItem(at: paths.baseDirectory.deletingLastPathComponent())
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        lstat(url.path(percentEncoded: false), &info)
        return info.st_mode & 0o777
    }

    /// A key made outside the daemon, optionally with a passphrase.
    private func externalKey(passphrase: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SkluzExt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("id")
        let output = try ToolRunner.run("/usr/bin/ssh-keygen",
                                        ["-q", "-t", "ed25519", "-N", passphrase, "-f", file.path(percentEncoded: false)])
        #expect(output.status == 0)
        return try Data(contentsOf: file)
    }

    @Test func generatedKeyIs600WithPublicHalfAndPassesTheLayoutCheck() throws {
        let paths = try makeLayout()
        defer { cleanup(paths) }

        let key = try ManagedKeys.generate(name: "dgx", comment: "skluzd@macmini", paths, ownership: .current)

        #expect(key.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(key.publicKey.hasSuffix(" skluzd@macmini"))
        #expect(mode(paths.keyFile(named: "dgx")) == 0o600)
        #expect(mode(paths.keyFile(named: "dgx.pub")) == 0o644)
        try SystemLayout.prepare(paths, ownership: .current)
        #expect(try ManagedKeys.list(paths) == [key])
    }

    @Test func generatedKeyHasNoPassphrase() throws {
        let paths = try makeLayout()
        defer { cleanup(paths) }
        _ = try ManagedKeys.generate(name: "dgx", comment: "c", paths, ownership: .current)

        let output = try ToolRunner.run("/usr/bin/ssh-keygen",
                                        ["-y", "-P", "", "-f", paths.keyFile(named: "dgx").path(percentEncoded: false)])
        #expect(output.status == 0)
    }

    @Test func fingerprintMatchesSSHKeygen() throws {
        let paths = try makeLayout()
        defer { cleanup(paths) }
        let key = try ManagedKeys.generate(name: "dgx", comment: "c", paths, ownership: .current)

        let output = try ToolRunner.run("/usr/bin/ssh-keygen",
                                        ["-l", "-E", "sha256", "-f", paths.keyFile(named: "dgx.pub").path(percentEncoded: false)])
        let printed = String(decoding: output.stdout, as: UTF8.self).split(separator: " ")[1]
        #expect(key.fingerprint == String(printed))
    }

    @Test func existingNameIsRefused() throws {
        let paths = try makeLayout()
        defer { cleanup(paths) }
        _ = try ManagedKeys.generate(name: "dgx", comment: "c", paths, ownership: .current)

        #expect(throws: ManagedKeyError.alreadyExists("dgx")) {
            try ManagedKeys.generate(name: "dgx", comment: "c", paths, ownership: .current)
        }
    }

    @Test(arguments: ["../escape", "a/b", "-oProxyCommand", ""])
    func unsafeNamesAreRefused(name: String) throws {
        let paths = try makeLayout()
        defer { cleanup(paths) }
        #expect(throws: TunnelValidationError.invalidKeyName(name)) {
            try ManagedKeys.generate(name: name, comment: "c", paths, ownership: .current)
        }
    }

    @Test func importAcceptsAKeyWithoutPassphrase() throws {
        let paths = try makeLayout()
        defer { cleanup(paths) }

        let key = try ManagedKeys.importKey(name: "old", privateKey: try externalKey(passphrase: ""),
                                            paths, ownership: .current)

        #expect(key.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(mode(paths.keyFile(named: "old")) == 0o600)
        #expect(mode(paths.keyFile(named: "old.pub")) == 0o644)
    }

    @Test func importRefusesAPassphraseProtectedKeyAndLeavesNoFile() throws {
        let paths = try makeLayout()
        defer { cleanup(paths) }

        #expect(throws: ManagedKeyError.passphraseProtected) {
            try ManagedKeys.importKey(name: "locked", privateKey: try externalKey(passphrase: "secret"),
                                      paths, ownership: .current)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.keysDirectory.path(percentEncoded: false)).isEmpty)
    }

    @Test func importRefusesGarbage() throws {
        let paths = try makeLayout()
        defer { cleanup(paths) }
        #expect(throws: ManagedKeyError.self) {
            try ManagedKeys.importKey(name: "junk", privateKey: Data("not a key".utf8), paths, ownership: .current)
        }
    }

    @Test func restrictedAuthorizedKeysLine() {
        #expect(ManagedKeys.restrictedAuthorizedKeysLine(publicKey: "ssh-ed25519 AAAA skluzd@macmini",
                                                         remoteHost: "localhost", remotePort: 8000)
                == "restrict,port-forwarding,permitopen=\"localhost:8000\" ssh-ed25519 AAAA skluzd@macmini")
        #expect(ManagedKeys.restrictedAuthorizedKeysLine(publicKey: "k", remoteHost: "::1", remotePort: 80)
                == "restrict,port-forwarding,permitopen=\"[::1]:80\" k")
    }
}
