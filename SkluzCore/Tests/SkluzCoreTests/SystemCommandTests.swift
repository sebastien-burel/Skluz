import Foundation
import Testing
@testable import SkluzCore

/// System policy (`PLAN_SKLUZD.md`, security constraints) and the field
/// validation shared by both modes.
struct SystemCommandTests {

    private func systemTunnel(
        host: String = "dgx.haruni.net",
        user: String? = "sb",
        port: Int? = 2022,
        keyRef: KeyRef? = .managed("dgx"),
        localBindAddress: String? = nil,
        exposesOnNetwork: Bool = false,
        localPort: Int = 8000,
        remotePort: Int? = 8000,
        proxyJump: String? = nil,
        extraArgs: [String] = []
    ) -> TunnelConfig {
        TunnelConfig(name: "vLLM", mode: .system, type: .localForward, host: host, user: user,
                     port: port, keyRef: keyRef, localBindAddress: localBindAddress,
                     exposesOnNetwork: exposesOnNetwork, localPort: localPort,
                     remoteHost: "localhost", remotePort: remotePort,
                     proxyJump: proxyJump, extraArgs: extraArgs)
    }

    @Test func nominalSystemCommandIsTheAllowList() throws {
        #expect(try SSHCommandBuilder.arguments(for: systemTunnel()) == [
            "-N", "-T",
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"/Library/Application Support/Skluz/known_hosts\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityFile=\"/Library/Application Support/Skluz/keys/dgx\"",
            "-p", "2022",
            "-L", "127.0.0.1:8000:localhost:8000",
            "sb@dgx.haruni.net"
        ])
    }

    /// ssh splits UserKnownHostsFile on whitespace: unquoted, the path under
    /// "Application Support" would become two missing files and every host
    /// key check would fail.
    @Test func knownHostsPathIsQuoted() throws {
        let args = try SSHCommandBuilder.arguments(for: systemTunnel())
        let option = try #require(args.first { $0.hasPrefix("UserKnownHostsFile=") })
        #expect(option.hasSuffix("\"") && option.contains("=\""))
    }

    /// `-i` with a missing file is dropped by ssh, which then tries the
    /// default keys of the process owner (root for the daemon).
    @Test func keyIsPassedAsIdentityFileNeverDashI() throws {
        let args = try SSHCommandBuilder.arguments(for: systemTunnel())
        #expect(!args.contains("-i"))
        #expect(args.contains("IdentityFile=\"/Library/Application Support/Skluz/keys/dgx\""))
    }

    @Test func systemDefaultsToPort22() throws {
        let args = try SSHCommandBuilder.arguments(for: systemTunnel(port: nil))
        #expect(args[args.firstIndex(of: "-p")! + 1] == "22")
    }

    @Test func systemPathsFollowInjectedBaseDirectory() throws {
        let paths = SystemPaths(baseDirectory: URL(filePath: "/tmp/skluz-test", directoryHint: .isDirectory))
        let args = try SSHCommandBuilder.arguments(for: systemTunnel(), paths: paths)
        #expect(args.contains("UserKnownHostsFile=\"/tmp/skluz-test/known_hosts\""))
        #expect(args.contains("IdentityFile=\"/tmp/skluz-test/keys/dgx\""))
    }

    @Test func pathWithQuoteIsRejected() {
        let paths = SystemPaths(baseDirectory: URL(filePath: "/tmp/sk\"luz", directoryHint: .isDirectory))
        #expect(throws: TunnelValidationError.self) {
            try SSHCommandBuilder.arguments(for: systemTunnel(), paths: paths)
        }
    }

    // MARK: - Rejections required by PLAN_SKLUZD phase 1

    @Test func hostInjectingAnOptionIsRejected() {
        #expect(throws: TunnelValidationError.invalidHost(field: "host SSH", value: "-oProxyCommand=touch /tmp/pwn")) {
            try SSHCommandBuilder.arguments(for: systemTunnel(host: "-oProxyCommand=touch /tmp/pwn"))
        }
    }

    @Test(arguments: ["sb;rm -rf /", "sb\nroot", "-oProxyCommand=x", "", "s b"])
    func invalidUserIsRejected(user: String) {
        #expect(throws: TunnelValidationError.self) {
            try SSHCommandBuilder.arguments(for: systemTunnel(user: user))
        }
    }

    @Test(arguments: [0, 70000, -1])
    func outOfRangePortsAreRejected(port: Int) {
        #expect(throws: TunnelValidationError.invalidPort(field: "port SSH", value: port)) {
            try SSHCommandBuilder.arguments(for: systemTunnel(port: port))
        }
        #expect(throws: TunnelValidationError.invalidPort(field: "port local", value: port)) {
            try SSHCommandBuilder.arguments(for: systemTunnel(localPort: port))
        }
    }

    @Test func bindOnAllInterfacesNeedsOptIn() throws {
        #expect(throws: TunnelValidationError.bindRequiresOptIn("0.0.0.0")) {
            try SSHCommandBuilder.arguments(for: systemTunnel(localBindAddress: "0.0.0.0"))
        }
        let args = try SSHCommandBuilder.arguments(
            for: systemTunnel(localBindAddress: "0.0.0.0", exposesOnNetwork: true))
        #expect(args[args.firstIndex(of: "-L")! + 1] == "0.0.0.0:8000:localhost:8000")
    }

    @Test func extraArgsAreRejectedInSystemMode() {
        #expect(throws: TunnelValidationError.systemForbidsExtraArgs) {
            try SSHCommandBuilder.arguments(for: systemTunnel(extraArgs: ["-oProxyCommand=touch /tmp/pwn"]))
        }
    }

    @Test func proxyJumpIsRejectedInSystemMode() {
        #expect(throws: TunnelValidationError.systemForbidsProxyJump) {
            try SSHCommandBuilder.arguments(for: systemTunnel(proxyJump: "bastion"))
        }
    }

    /// Without a config file ssh would log in as the process owner: root.
    @Test func systemModeRequiresUser() {
        #expect(throws: TunnelValidationError.systemRequiresUser) {
            try SSHCommandBuilder.arguments(for: systemTunnel(user: nil))
        }
    }

    @Test func systemModeRequiresManagedKey() {
        #expect(throws: TunnelValidationError.systemRequiresManagedKey) {
            try SSHCommandBuilder.arguments(for: systemTunnel(keyRef: .path("~/.ssh/id_ed25519")))
        }
        #expect(throws: TunnelValidationError.systemRequiresManagedKey) {
            try SSHCommandBuilder.arguments(for: systemTunnel(keyRef: nil))
        }
    }

    @Test(arguments: ["../../etc/passwd", "a/b", "-x", "", "clé"])
    func unsafeKeyNamesAreRejected(name: String) {
        #expect(throws: TunnelValidationError.invalidKeyName(name)) {
            try SSHCommandBuilder.arguments(for: systemTunnel(keyRef: .managed(name)))
        }
    }

    @Test func systemModeOnlyAllowsLocalForward() {
        var tunnel = systemTunnel()
        tunnel.type = .dynamic
        #expect(throws: TunnelValidationError.systemRequiresLocalForward) {
            try SSHCommandBuilder.arguments(for: tunnel)
        }
    }

    @Test func managedKeyIsRejectedInSessionMode() {
        var tunnel = systemTunnel()
        tunnel.mode = .session
        #expect(throws: TunnelValidationError.managedKeyRequiresSystemMode) {
            try SSHCommandBuilder.arguments(for: tunnel)
        }
    }

    @Test func controlCharactersInNameAreRejected() {
        var tunnel = systemTunnel()
        tunnel.name = "vLLM\u{7}"
        #expect(throws: TunnelValidationError.controlCharacters(field: "nom")) {
            try SSHCommandBuilder.arguments(for: tunnel)
        }
    }

    /// Validation applies to Session mode too: a leading dash in the host
    /// would be read as an option even under the user's UID.
    @Test func sessionHostInjectionIsRejected() {
        let tunnel = TunnelConfig(name: "s", type: .localForward, host: "-oProxyCommand=x",
                                  localPort: 1, remoteHost: "r", remotePort: 2)
        #expect(throws: TunnelValidationError.self) {
            try SSHCommandBuilder.arguments(for: tunnel)
        }
    }

    @Test func sessionProxyJumpWithLeadingDashIsRejected() {
        let tunnel = TunnelConfig(name: "s", type: .localForward, host: "h", localPort: 1,
                                  remoteHost: "r", remotePort: 2, proxyJump: "ok,-oProxyCommand=x")
        #expect(throws: TunnelValidationError.invalidProxyJump("ok,-oProxyCommand=x")) {
            try SSHCommandBuilder.arguments(for: tunnel)
        }
    }

    @Test func sessionAcceptsUserAtHostProxyJump() throws {
        let tunnel = TunnelConfig(name: "s", type: .localForward, host: "h", localPort: 1,
                                  remoteHost: "r", remotePort: 2, proxyJump: "sb@bastion:2222,jump2")
        #expect(try SSHCommandBuilder.arguments(for: tunnel).contains("sb@bastion:2222,jump2"))
    }
}
