import Foundation

nonisolated enum SSHCommandBuilder {
    static let sshPath = "/usr/bin/ssh"

    static let baseOptions: [String] = [
        "-N",
        "-T",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "StrictHostKeyChecking=accept-new"
    ]

    static func arguments(for tunnel: Tunnel) -> [String] {
        var args = baseOptions

        if let port = tunnel.sshPort {
            args.append("-p")
            args.append(String(port))
        }

        if let identity = tunnel.identityFile, !identity.isEmpty {
            args.append("-i")
            args.append(expandTilde(identity))
            args.append("-o")
            args.append("IdentitiesOnly=yes")
        }

        if let jump = tunnel.proxyJump, !jump.isEmpty {
            args.append("-J")
            args.append(jump)
        }

        switch tunnel.type {
        case .localForward:
            args.append("-L")
            args.append(forwardSpec(tunnel: tunnel))
        case .remoteForward:
            args.append("-R")
            args.append(forwardSpec(tunnel: tunnel))
        case .dynamic:
            args.append("-D")
            args.append(String(tunnel.localPort))
        }

        let userPart = tunnel.sshUser.map { "\($0)@" } ?? ""
        args.append("\(userPart)\(tunnel.sshHost)")

        args.append(contentsOf: tunnel.extraArgs)

        return args
    }

    private static func forwardSpec(tunnel: Tunnel) -> String {
        let host = tunnel.remoteHost ?? "localhost"
        let port = tunnel.remotePort ?? tunnel.localPort
        return "\(tunnel.localPort):\(host):\(port)"
    }

    private static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
