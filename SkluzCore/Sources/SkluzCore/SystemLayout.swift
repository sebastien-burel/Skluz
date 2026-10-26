import Foundation
import Darwin

/// Owner expected on the daemon files: root in production, the current user
/// only for the development mode and tests.
public struct FileOwnership: Hashable, Sendable {
    public var uid: uid_t
    public var gid: gid_t

    public init(uid: uid_t, gid: gid_t) {
        self.uid = uid
        self.gid = gid
    }

    public static let root = FileOwnership(uid: 0, gid: 0)
    public static var current: FileOwnership { FileOwnership(uid: getuid(), gid: getgid()) }
}

/// A daemon file that cannot be trusted. The daemon then starts no tunnel and
/// reports the problem; it never repairs permissions itself (they may reveal
/// tampering or a leaked key).
public struct SystemLayoutProblem: Error, Equatable, Sendable, LocalizedError {
    public enum Issue: Equatable, Sendable {
        case symbolicLink
        case wrongType(expectedDirectory: Bool)
        case wrongOwner(uid: uid_t)
        case tooPermissive(mode: mode_t, expected: mode_t)
        case ioError(String)
    }

    public let path: String
    public let issue: Issue

    public var errorDescription: String? { message }

    public var message: String {
        switch issue {
        case .symbolicLink:
            "« \(path) » est un lien symbolique, refusé — corriger avec : sudo rm \"\(path)\""
        case .wrongType(let expectedDirectory):
            "« \(path) » devrait être un \(expectedDirectory ? "dossier" : "fichier")."
        case .wrongOwner(let uid):
            "« \(path) » appartient à l'UID \(uid) au lieu de root — corriger avec : sudo chown root:wheel \"\(path)\""
        case .tooPermissive(let mode, let expected):
            "« \(path) » est en \(Self.octal(mode)) (attendu \(Self.octal(expected))) — corriger avec : sudo chmod \(Self.octal(expected)) \"\(path)\""
        case .ioError(let detail):
            "« \(path) » est inaccessible : \(detail)"
        }
    }

    private static func octal(_ mode: mode_t) -> String {
        String(mode & 0o777, radix: 8)
    }
}

/// Creates the missing daemon files and checks the existing ones
/// (`PLAN_SKLUZD.md` phase 2, security constraint 7).
public enum SystemLayout {
    private struct Element {
        let url: URL
        let isDirectory: Bool
        /// Mode used on creation, and suggested in fix commands.
        let mode: mode_t
        /// Permission bits that must never be set.
        let forbidden: mode_t
        let initialContents: Data
    }

    static let emptyTunnelsFile = Data("{\n  \"tunnels\" : [\n\n  ],\n  \"version\" : \(TunnelStore.currentVersion)\n}\n".utf8)

    private static func elements(_ paths: SystemPaths) -> [Element] {
        [
            Element(url: paths.baseDirectory, isDirectory: true, mode: 0o755, forbidden: 0o022, initialContents: Data()),
            Element(url: paths.keysDirectory, isDirectory: true, mode: 0o700, forbidden: 0o077, initialContents: Data()),
            Element(url: paths.tunnelsFile, isDirectory: false, mode: 0o600, forbidden: 0o077, initialContents: emptyTunnelsFile),
            Element(url: paths.knownHostsFile, isDirectory: false, mode: 0o644, forbidden: 0o022, initialContents: Data())
        ]
    }

    /// Creates what is missing, then verifies everything, keys included.
    public static func prepare(_ paths: SystemPaths, ownership: FileOwnership) throws {
        for element in elements(paths) {
            try createIfMissing(element, ownership: ownership)
            try verify(path: element.url.path(percentEncoded: false), isDirectory: element.isDirectory,
                       mode: element.mode, forbidden: element.forbidden, ownership: ownership)
        }
        let keysPath = paths.keysDirectory.path(percentEncoded: false)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: keysPath).sorted()
        } catch {
            throw SystemLayoutProblem(path: keysPath, issue: .ioError(error.localizedDescription))
        }
        for name in names {
            // Public halves may be world-readable; private keys never.
            let isPublic = name.hasSuffix(".pub")
            try verify(path: paths.keyFile(named: name).path(percentEncoded: false), isDirectory: false,
                       mode: isPublic ? 0o644 : 0o600, forbidden: isPublic ? 0o022 : 0o077,
                       ownership: ownership)
        }
    }

    /// Prepares the layout and reads the tunnels file.
    public static func loadTunnels(_ paths: SystemPaths, ownership: FileOwnership) async throws -> [TunnelConfig] {
        try prepare(paths, ownership: ownership)
        let store = TunnelStore(storageURL: paths.tunnelsFile)
        try await store.load()
        return await store.tunnels
    }

    private static func createIfMissing(_ element: Element, ownership: FileOwnership) throws {
        let path = element.url.path(percentEncoded: false)
        var info = stat()
        if lstat(path, &info) == 0 { return }
        guard errno == ENOENT else { throw problem(path) }

        if element.isDirectory {
            guard mkdir(path, element.mode) == 0 else { throw problem(path) }
        } else {
            let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, element.mode)
            guard fd >= 0 else { throw problem(path) }
            defer { close(fd) }
            let written = element.initialContents.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == element.initialContents.count else { throw problem(path) }
        }
        // mkdir/open honor the umask, and new entries inherit the parent's
        // group (admin under /Library): set both explicitly.
        guard chmod(path, element.mode) == 0, lchown(path, ownership.uid, ownership.gid) == 0 else {
            throw problem(path)
        }
    }

    private static func verify(path: String, isDirectory: Bool, mode: mode_t, forbidden: mode_t,
                               ownership: FileOwnership) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw problem(path) }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK {
            throw SystemLayoutProblem(path: path, issue: .symbolicLink)
        }
        guard type == (isDirectory ? S_IFDIR : S_IFREG) else {
            throw SystemLayoutProblem(path: path, issue: .wrongType(expectedDirectory: isDirectory))
        }
        guard info.st_uid == ownership.uid else {
            throw SystemLayoutProblem(path: path, issue: .wrongOwner(uid: info.st_uid))
        }
        guard info.st_mode & forbidden == 0 else {
            throw SystemLayoutProblem(path: path, issue: .tooPermissive(mode: info.st_mode & 0o777, expected: mode))
        }
    }

    /// Wraps the current `errno`; call right after the failing syscall.
    private static func problem(_ path: String) -> SystemLayoutProblem {
        let code = errno
        return SystemLayoutProblem(path: path, issue: .ioError(String(cString: strerror(code))))
    }
}
