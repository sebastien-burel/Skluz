import Foundation
import Testing
@testable import Skluz

struct SSHCommandBuilderTests {

    @Test func localForwardWithUserAndCustomSSHPort() {
        let tunnel = Tunnel(
            name: "prod-postgres",
            type: .localForward,
            sshHost: "bastion.example.com",
            sshUser: "sebastien",
            sshPort: 2022,
            localPort: 5432,
            remoteHost: "db.internal",
            remotePort: 5432
        )

        #expect(SSHCommandBuilder.arguments(for: tunnel) == [
            "-N", "-T",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", "2022",
            "-L", "5432:db.internal:5432",
            "sebastien@bastion.example.com"
        ])
    }

    @Test func localForwardUsingSSHConfigAlias() {
        let tunnel = Tunnel(
            name: "via-alias",
            type: .localForward,
            sshHost: "mon-alias",
            sshUser: nil,
            sshPort: nil,
            localPort: 5432,
            remoteHost: "db",
            remotePort: 5432
        )

        let args = SSHCommandBuilder.arguments(for: tunnel)

        #expect(!args.contains("-p"))
        #expect(args.last == "mon-alias")
        #expect(args.contains("-L"))
        let lIndex = args.firstIndex(of: "-L")!
        #expect(args[lIndex + 1] == "5432:db:5432")
    }

    @Test func remoteForwardArgs() {
        let tunnel = Tunnel(
            name: "remote",
            type: .remoteForward,
            sshHost: "public.example.com",
            sshUser: "deploy",
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 8080
        )

        let args = SSHCommandBuilder.arguments(for: tunnel)
        let rIndex = args.firstIndex(of: "-R")!
        #expect(args[rIndex + 1] == "8080:localhost:8080")
        #expect(args.last == "deploy@public.example.com")
    }

    @Test func dynamicSocksOmitsRemoteHostAndPort() {
        let tunnel = Tunnel(
            name: "socks",
            type: .dynamic,
            sshHost: "gateway.example.com",
            sshUser: "user",
            localPort: 1080
        )

        let args = SSHCommandBuilder.arguments(for: tunnel)
        let dIndex = args.firstIndex(of: "-D")!
        #expect(args[dIndex + 1] == "1080")
        #expect(!args.contains("-L"))
        #expect(!args.contains("-R"))
    }

    @Test func proxyJumpInsertedBeforeForward() {
        let tunnel = Tunnel(
            name: "via-jump",
            type: .localForward,
            sshHost: "target",
            sshUser: "user",
            localPort: 5432,
            remoteHost: "db",
            remotePort: 5432,
            proxyJump: "jump.example.com"
        )

        let args = SSHCommandBuilder.arguments(for: tunnel)
        let jIndex = args.firstIndex(of: "-J")!
        let lIndex = args.firstIndex(of: "-L")!
        #expect(args[jIndex + 1] == "jump.example.com")
        #expect(jIndex < lIndex)
    }

    @Test func extraArgsAppendedLast() {
        let tunnel = Tunnel(
            name: "verbose",
            type: .localForward,
            sshHost: "host",
            sshUser: "u",
            localPort: 1,
            remoteHost: "r",
            remotePort: 2,
            extraArgs: ["-v", "-C"]
        )

        let args = SSHCommandBuilder.arguments(for: tunnel)
        #expect(args.suffix(2) == ["-v", "-C"])
    }

    @Test func identityFileEmitsDashIAndIdentitiesOnly() {
        let tunnel = Tunnel(
            name: "with-key",
            type: .localForward,
            sshHost: "host",
            sshUser: "u",
            sshPort: 22,
            identityFile: "/Users/sb/Library/Application Support/NVIDIA/Sync/config/nvsync.key",
            localPort: 5432,
            remoteHost: "r",
            remotePort: 5432
        )

        let args = SSHCommandBuilder.arguments(for: tunnel)
        let iIndex = args.firstIndex(of: "-i")!
        #expect(args[iIndex + 1] == "/Users/sb/Library/Application Support/NVIDIA/Sync/config/nvsync.key")
        #expect(args.contains("IdentitiesOnly=yes"))
    }

    @Test func identityFileTildeExpansion() {
        let tunnel = Tunnel(
            name: "tilde",
            type: .dynamic,
            sshHost: "h",
            identityFile: "~/.ssh/id_ed25519_haruni",
            localPort: 1080
        )

        let args = SSHCommandBuilder.arguments(for: tunnel)
        let iIndex = args.firstIndex(of: "-i")!
        #expect(args[iIndex + 1].hasPrefix("/"))
        #expect(args[iIndex + 1].hasSuffix("/.ssh/id_ed25519_haruni"))
    }

    @Test func baseOptionsAlwaysIncludeHardenedDefaults() {
        let tunnel = Tunnel(name: "x", type: .dynamic, sshHost: "h", localPort: 1080)
        let args = SSHCommandBuilder.arguments(for: tunnel)
        #expect(args.contains("ExitOnForwardFailure=yes"))
        #expect(args.contains("StrictHostKeyChecking=accept-new"))
        #expect(args.contains("ServerAliveInterval=30"))
        #expect(args.contains("ServerAliveCountMax=3"))
        #expect(args.contains("-N"))
        #expect(args.contains("-T"))
    }
}
