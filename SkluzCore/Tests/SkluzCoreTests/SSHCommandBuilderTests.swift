import Foundation
import Testing
@testable import SkluzCore

/// Session policy: same expected arguments as Skluz 1.0, only the field
/// names changed (`sshHost` → `host`, `identityFile` → `keyRef`).
struct SSHCommandBuilderTests {

    @Test func localForwardWithUserAndCustomSSHPort() throws {
        let tunnel = TunnelConfig(
            name: "prod-postgres",
            type: .localForward,
            host: "bastion.example.com",
            user: "sebastien",
            port: 2022,
            localPort: 5432,
            remoteHost: "db.internal",
            remotePort: 5432
        )

        #expect(try SSHCommandBuilder.arguments(for: tunnel) == [
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

    @Test func localForwardUsingSSHConfigAlias() throws {
        let tunnel = TunnelConfig(
            name: "via-alias",
            type: .localForward,
            host: "mon-alias",
            user: nil,
            port: nil,
            localPort: 5432,
            remoteHost: "db",
            remotePort: 5432
        )

        let args = try SSHCommandBuilder.arguments(for: tunnel)

        #expect(!args.contains("-p"))
        #expect(args.last == "mon-alias")
        #expect(args.contains("-L"))
        let lIndex = args.firstIndex(of: "-L")!
        #expect(args[lIndex + 1] == "5432:db:5432")
    }

    @Test func remoteForwardArgs() throws {
        let tunnel = TunnelConfig(
            name: "remote",
            type: .remoteForward,
            host: "public.example.com",
            user: "deploy",
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 8080
        )

        let args = try SSHCommandBuilder.arguments(for: tunnel)
        let rIndex = args.firstIndex(of: "-R")!
        #expect(args[rIndex + 1] == "8080:localhost:8080")
        #expect(args.last == "deploy@public.example.com")
    }

    @Test func dynamicSocksOmitsRemoteHostAndPort() throws {
        let tunnel = TunnelConfig(
            name: "socks",
            type: .dynamic,
            host: "gateway.example.com",
            user: "user",
            localPort: 1080
        )

        let args = try SSHCommandBuilder.arguments(for: tunnel)
        let dIndex = args.firstIndex(of: "-D")!
        #expect(args[dIndex + 1] == "1080")
        #expect(!args.contains("-L"))
        #expect(!args.contains("-R"))
    }

    @Test func proxyJumpInsertedBeforeForward() throws {
        let tunnel = TunnelConfig(
            name: "via-jump",
            type: .localForward,
            host: "target",
            user: "user",
            localPort: 5432,
            remoteHost: "db",
            remotePort: 5432,
            proxyJump: "jump.example.com"
        )

        let args = try SSHCommandBuilder.arguments(for: tunnel)
        let jIndex = args.firstIndex(of: "-J")!
        let lIndex = args.firstIndex(of: "-L")!
        #expect(args[jIndex + 1] == "jump.example.com")
        #expect(jIndex < lIndex)
    }

    @Test func extraArgsAppendedLast() throws {
        let tunnel = TunnelConfig(
            name: "verbose",
            type: .localForward,
            host: "host",
            user: "u",
            localPort: 1,
            remoteHost: "r",
            remotePort: 2,
            extraArgs: ["-v", "-C"]
        )

        let args = try SSHCommandBuilder.arguments(for: tunnel)
        #expect(args.suffix(2) == ["-v", "-C"])
    }

    @Test func identityFileEmitsDashIAndIdentitiesOnly() throws {
        let tunnel = TunnelConfig(
            name: "with-key",
            type: .localForward,
            host: "host",
            user: "u",
            port: 22,
            keyRef: .path("/Users/sb/Library/Application Support/NVIDIA/Sync/config/nvsync.key"),
            localPort: 5432,
            remoteHost: "r",
            remotePort: 5432
        )

        let args = try SSHCommandBuilder.arguments(for: tunnel)
        let iIndex = args.firstIndex(of: "-i")!
        #expect(args[iIndex + 1] == "/Users/sb/Library/Application Support/NVIDIA/Sync/config/nvsync.key")
        #expect(args.contains("IdentitiesOnly=yes"))
    }

    @Test func identityFileTildeExpansion() throws {
        let tunnel = TunnelConfig(
            name: "tilde",
            type: .dynamic,
            host: "h",
            keyRef: .path("~/.ssh/id_ed25519_haruni"),
            localPort: 1080
        )

        let args = try SSHCommandBuilder.arguments(for: tunnel)
        let iIndex = args.firstIndex(of: "-i")!
        #expect(args[iIndex + 1].hasPrefix("/"))
        #expect(args[iIndex + 1].hasSuffix("/.ssh/id_ed25519_haruni"))
    }

    @Test func baseOptionsAlwaysIncludeHardenedDefaults() throws {
        let tunnel = TunnelConfig(name: "x", type: .dynamic, host: "h", localPort: 1080)
        let args = try SSHCommandBuilder.arguments(for: tunnel)
        #expect(args.contains("ExitOnForwardFailure=yes"))
        #expect(args.contains("StrictHostKeyChecking=accept-new"))
        #expect(args.contains("ServerAliveInterval=30"))
        #expect(args.contains("ServerAliveCountMax=3"))
        #expect(args.contains("-N"))
        #expect(args.contains("-T"))
    }

    // MARK: - Session additions

    @Test func sessionBindAddressPrefixesForwardSpec() throws {
        let tunnel = TunnelConfig(name: "b", type: .localForward, host: "h",
                                  localBindAddress: "127.0.0.1", localPort: 8080,
                                  remoteHost: "r", remotePort: 80)
        let args = try SSHCommandBuilder.arguments(for: tunnel)
        #expect(args[args.firstIndex(of: "-L")! + 1] == "127.0.0.1:8080:r:80")
    }

    @Test func ipv6AddressesAreBracketed() throws {
        let tunnel = TunnelConfig(name: "v6", type: .localForward, host: "h",
                                  localBindAddress: "::1", localPort: 8080,
                                  remoteHost: "fd00::5", remotePort: 80)
        let args = try SSHCommandBuilder.arguments(for: tunnel)
        #expect(args[args.firstIndex(of: "-L")! + 1] == "[::1]:8080:[fd00::5]:80")
    }
}
