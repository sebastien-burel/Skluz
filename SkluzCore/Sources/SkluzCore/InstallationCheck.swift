import Foundation
import Darwin

/// Whether the installed app may host the root daemon. launchd only runs a
/// `skluzd` signed by the team, but a bundle the user can write lets any of
/// their processes swap in another team-signed build (an older one, say),
/// which launchd would then run as root. A drag-and-drop install is owned by
/// the user: it must be handed to root before the service is enabled.
public enum InstallationCheck {
    /// What launchd uses for the daemon, from the bundle root down.
    public static let protectedComponents = [
        "",
        "Contents",
        "Contents/MacOS",
        "Contents/MacOS/skluzd",
        "Contents/Library",
        "Contents/Library/LaunchDaemons",
        "Contents/Library/LaunchDaemons/net.haruni.skluzd.plist",
        // Run by admins through /usr/local/bin/skluz.
        "Contents/Helpers",
        "Contents/Helpers/skluz",
        // Run as root by `sudo skluz uninstall`.
        "Contents/Resources",
        "Contents/Resources/skluz-uninstall.sh"
    ]

    public struct Problem: Error, Equatable, Sendable, LocalizedError {
        public enum Issue: Equatable, Sendable {
            case missing
            case symbolicLink
            case wrongOwner(uid: uid_t)
            case writableByOthers(mode: mode_t)
            /// A parent folder lets someone else rename the bundle away and
            /// put another one in its place.
            case unsafeAncestor(mode: mode_t)
        }

        public let path: String
        public let issue: Issue
        public let bundlePath: String

        public var errorDescription: String? { message }

        public var message: String {
            let detail = switch issue {
            case .missing:                    "est introuvable"
            case .symbolicLink:               "est un lien symbolique"
            case .wrongOwner:                 "n'appartient pas à root"
            case .writableByOthers:           "est modifiable par d'autres que root"
            case .unsafeAncestor:             "permet à d'autres que root ou le groupe admin de remplacer l'app"
            }
            return "« \(path) » \(detail) : le service système exige une app installée au nom de root."
        }

        /// Hands the whole bundle to root, read-only for everyone else.
        public var fixCommand: String {
            "sudo chown -R root:wheel \"\(bundlePath)\" && sudo chmod -R go-w \"\(bundlePath)\""
        }
    }

    public static func firstProblem(bundle: URL, owner: uid_t = 0) -> Problem? {
        let given = bundle.path(percentEncoded: false)
        guard let resolved = realpath(given, nil) else {
            return Problem(path: given, issue: .missing, bundlePath: given)
        }
        let bundlePath = String(cString: resolved)
        free(resolved)

        if let problem = firstUnsafeAncestor(of: bundlePath, owner: owner) {
            return problem
        }
        for component in protectedComponents {
            let path = component.isEmpty ? bundlePath : bundlePath + "/" + component
            var info = stat()
            guard lstat(path, &info) == 0 else {
                return Problem(path: path, issue: .missing, bundlePath: bundlePath)
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                return Problem(path: path, issue: .symbolicLink, bundlePath: bundlePath)
            }
            if info.st_uid != owner {
                return Problem(path: path, issue: .wrongOwner(uid: info.st_uid), bundlePath: bundlePath)
            }
            if info.st_mode & 0o022 != 0 {
                return Problem(path: path, issue: .writableByOthers(mode: info.st_mode & 0o777), bundlePath: bundlePath)
            }
        }
        return nil
    }

    /// Every folder above the bundle must belong to root (or `owner`, for
    /// tests), not be a symlink, and be writable by nobody else, except the
    /// admin group: /Applications is root:admin 775 on every Mac, and admins
    /// may already reconfigure the daemon.
    static func firstUnsafeAncestor(of bundlePath: String, owner: uid_t) -> Problem? {
        let adminGroup = getgrnam("admin")?.pointee.gr_gid
        var directory = (bundlePath as NSString).deletingLastPathComponent
        while true {
            var info = stat()
            guard lstat(directory, &info) == 0 else {
                return Problem(path: directory, issue: .missing, bundlePath: bundlePath)
            }
            let mode = info.st_mode & 0o777
            let groupWriteAllowed = adminGroup != nil && info.st_gid == adminGroup
            if info.st_mode & S_IFMT == S_IFLNK
                || (info.st_uid != 0 && info.st_uid != owner)
                || mode & 0o002 != 0
                || (mode & 0o020 != 0 && !groupWriteAllowed) {
                return Problem(path: directory, issue: .unsafeAncestor(mode: mode), bundlePath: bundlePath)
            }
            if directory == "/" { return nil }
            directory = (directory as NSString).deletingLastPathComponent
        }
    }
}
