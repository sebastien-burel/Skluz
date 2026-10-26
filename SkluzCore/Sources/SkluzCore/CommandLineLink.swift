import Foundation
import Darwin

public enum CommandLineLinkError: Error, Equatable, LocalizedError {
    case occupied(String)
    case targetMissing(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .occupied(let path): "« \(path) » existe déjà et n'est pas un lien vers Skluz : supprimez-le d'abord."
        case .targetMissing(let path): "Commande introuvable dans l'app : \(path)"
        case .failed(let detail): "Installation de la commande impossible : \(detail)"
        }
    }
}

/// The `/usr/local/bin/skluz` symlink to the CLI inside the app
/// (`PLAN_SKLUZD.md` phase 7), created by the daemon for admins.
public enum CommandLineLink {
    public static let standardLink = URL(filePath: "/usr/local/bin/skluz")

    /// Whether `link` already points to `target`.
    public static func isInstalled(link: URL = standardLink, target: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)))
            == target.path(percentEncoded: false)
    }

    /// Creates or repoints the symlink; never replaces anything but a symlink.
    public static func install(link: URL = standardLink, target: URL) throws {
        let linkPath = link.path(percentEncoded: false)
        let targetPath = target.path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: targetPath) else {
            throw CommandLineLinkError.targetMissing(targetPath)
        }
        let directory = link.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
        } catch {
            throw CommandLineLinkError.failed(error.localizedDescription)
        }

        var info = stat()
        if lstat(linkPath, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFLNK else { throw CommandLineLinkError.occupied(linkPath) }
            if isInstalled(link: link, target: target) { return }
            guard unlink(linkPath) == 0 else { throw CommandLineLinkError.failed(String(cString: strerror(errno))) }
        }
        guard symlink(targetPath, linkPath) == 0 else {
            throw CommandLineLinkError.failed(String(cString: strerror(errno)))
        }
    }
}
