import Foundation

/// Root-owned files of the daemon (`PLAN_SKLUZD.md`, target architecture).
public struct SystemPaths: Hashable, Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public static let standard = SystemPaths(
        baseDirectory: URL(filePath: "/Library/Application Support/Skluz", directoryHint: .isDirectory)
    )

    public var tunnelsFile: URL { baseDirectory.appending(path: "tunnels.json") }
    public var keysDirectory: URL { baseDirectory.appending(path: "keys", directoryHint: .isDirectory) }
    public var knownHostsFile: URL { baseDirectory.appending(path: "known_hosts") }

    public func keyFile(named name: String) -> URL {
        keysDirectory.appending(path: name)
    }
}
