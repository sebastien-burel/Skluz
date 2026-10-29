import Foundation
import CryptoKit

/// A dedicated daemon key, as listed over XPC (the private half never
/// leaves `keys/`).
public struct ManagedKey: Codable, Equatable, Sendable {
    public var name: String
    /// `ssh-ed25519 AAAA… comment`
    public var publicKey: String
    /// `SHA256:…`, as printed by `ssh-keygen -l`.
    public var fingerprint: String

    public init(name: String, publicKey: String, fingerprint: String) {
        self.name = name
        self.publicKey = publicKey
        self.fingerprint = fingerprint
    }
}

public enum ManagedKeyError: Error, Equatable, LocalizedError {
    case alreadyExists(String)
    case notFound(String)
    case passphraseProtected
    case invalidKey(String)
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            "Une clé « \(name) » existe déjà."
        case .notFound(let name):
            "Aucune clé « \(name) »."
        case .passphraseProtected:
            "Clé refusée : elle est protégée par une passphrase. Le service système démarre avant toute "
                + "ouverture de session et ne peut pas la déverrouiller : utilisez une clé dédiée sans passphrase, "
                + "restreinte côté serveur."
        case .invalidKey(let detail):
            "Clé privée invalide : \(detail)"
        case .toolFailed(let detail):
            "ssh-keygen a échoué : \(detail)"
        }
    }
}

/// Dedicated keys of the daemon under `keys/` (`PLAN_SKLUZD.md` phase 5).
/// Private keys are 600, public halves 644, both owned like the daemon files.
public enum ManagedKeys {
    static let sshKeygen = "/usr/bin/ssh-keygen"
    static let maxPrivateKeySize = 16 * 1024

    public static func list(_ paths: SystemPaths) throws -> [ManagedKey] {
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.keysDirectory.path(percentEncoded: false))
        return names
            .filter { !$0.hasSuffix(".pub") && (try? SSHCommandBuilder.validateKeyName($0)) != nil }
            .sorted()
            .compactMap { name in
                guard let publicKey = try? publicKey(named: name, paths) else { return nil }
                return ManagedKey(name: name, publicKey: publicKey, fingerprint: fingerprint(ofPublicKey: publicKey) ?? "?")
            }
    }

    public static func publicKey(named name: String, _ paths: SystemPaths) throws -> String {
        let url = paths.keyFile(named: name + ".pub")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ManagedKeyError.notFound(name) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `ssh-keygen -t ed25519 -N ""`: no passphrase, since nobody can type it
    /// before the session opens.
    public static func generate(name: String, comment: String, _ paths: SystemPaths,
                                ownership: FileOwnership) throws -> ManagedKey {
        try SSHCommandBuilder.validateKeyName(name)
        let key = paths.keyFile(named: name)
        guard !exists(key), !exists(paths.keyFile(named: name + ".pub")) else {
            throw ManagedKeyError.alreadyExists(name)
        }
        let output = try ToolRunner.run(sshKeygen, [
            "-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", key.path(percentEncoded: false)
        ])
        guard output.status == 0 else { throw ManagedKeyError.toolFailed(output.stderrText) }
        try secure(name: name, paths, ownership: ownership)
        return try describe(name: name, paths)
    }

    /// Accepts an existing private key only if it has no passphrase:
    /// `ssh-keygen -y -P ""` must be able to derive its public half.
    public static func importKey(name: String, privateKey: Data, _ paths: SystemPaths,
                                 ownership: FileOwnership) throws -> ManagedKey {
        try SSHCommandBuilder.validateKeyName(name)
        guard privateKey.count <= maxPrivateKeySize else { throw ManagedKeyError.invalidKey("fichier trop gros") }
        let key = paths.keyFile(named: name)
        guard !exists(key), !exists(paths.keyFile(named: name + ".pub")) else {
            throw ManagedKeyError.alreadyExists(name)
        }

        // Checked in place, already 600, so the key is never readable by others.
        let candidate = paths.keyFile(named: ".import-\(UUID().uuidString)")
        try SystemLayout.writeFile(privateKey, to: candidate, mode: 0o600, ownership: ownership)
        defer { try? FileManager.default.removeItem(at: candidate) }

        let output = try ToolRunner.run(sshKeygen, ["-y", "-P", "", "-f", candidate.path(percentEncoded: false)])
        guard output.status == 0 else {
            let detail = output.stderrText
            if detail.localizedCaseInsensitiveContains("passphrase") {
                throw ManagedKeyError.passphraseProtected
            }
            throw ManagedKeyError.invalidKey(detail.isEmpty ? "format non reconnu" : detail)
        }
        let derived = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        try SystemLayout.writeFile(privateKey, to: key, mode: 0o600, ownership: ownership)
        try SystemLayout.writeFile(Data("\(derived) skluzd-import:\(name)\n".utf8),
                                   to: paths.keyFile(named: name + ".pub"), mode: 0o644, ownership: ownership)
        return try describe(name: name, paths)
    }

    /// `SHA256:<base64 without padding>` of the key blob, like `ssh-keygen -l`.
    public static func fingerprint(ofPublicKey line: String) -> String? {
        let fields = line.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return fingerprint(ofBlob: String(fields[1]))
    }

    public static func fingerprint(ofBlob base64: String) -> String? {
        guard let blob = Data(base64Encoded: base64) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// The `authorized_keys` line to install on the server: the key may only
    /// open this one forward. `restrict` alone still lets the key run
    /// commands (only the pty is refused): the forced `/bin/false` blocks
    /// them, and never runs for the daemon, whose `ssh -N` opens no session.
    public static func restrictedAuthorizedKeysLine(publicKey: String, remoteHost: String, remotePort: Int) -> String {
        restrictedAuthorizedKeysLine(publicKey: publicKey, destinations: [(remoteHost, remotePort)])
    }

    /// One line for every destination a key opens on a server: sshd only
    /// applies the first `authorized_keys` line matching a key, so a second
    /// line for the same key is silently ignored and its forward refused.
    public static func restrictedAuthorizedKeysLine(publicKey: String,
                                                    destinations: [(host: String, port: Int)]) -> String {
        var seen = Set<String>()
        let permits = destinations.compactMap { destination -> String? in
            let host = destination.host.contains(":") ? "[\(destination.host)]" : destination.host
            let permit = "permitopen=\"\(host):\(destination.port)\""
            return seen.insert(permit).inserted ? permit : nil
        }
        return "restrict,port-forwarding,\(permits.joined(separator: ",")),command=\"/bin/false\" \(publicKey)"
    }

    // MARK: - Helpers

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    private static func secure(name: String, _ paths: SystemPaths, ownership: FileOwnership) throws {
        for (file, mode) in [(name, mode_t(0o600)), (name + ".pub", mode_t(0o644))] {
            let path = paths.keyFile(named: file).path(percentEncoded: false)
            guard chmod(path, mode) == 0, lchown(path, ownership.uid, ownership.gid) == 0 else {
                throw ManagedKeyError.toolFailed("droits de \(file) : \(String(cString: strerror(errno)))")
            }
        }
    }

    private static func describe(name: String, _ paths: SystemPaths) throws -> ManagedKey {
        let publicKey = try publicKey(named: name, paths)
        return ManagedKey(name: name, publicKey: publicKey, fingerprint: fingerprint(ofPublicKey: publicKey) ?? "?")
    }
}
