import Foundation
import Testing
import SkluzCore
@testable import Skluz

@MainActor
struct SystemModeDraftTests {

    private func sessionDraft() -> TunnelDraft {
        var draft = TunnelDraft(from: TunnelConfig(
            name: "vLLM", type: .localForward, host: "dgx.haruni.net", user: "sb", port: 2022,
            keyRef: .path("~/.ssh/id_ed25519"), localPort: 8000, remoteHost: "localhost", remotePort: 8000,
            proxyJump: "bastion", extraArgs: ["-v"], autoStart: true, autoRestart: true))
        draft.mode = .system
        return draft
    }

    @Test func systemModeNeedsADedicatedKey() {
        let draft = sessionDraft()
        #expect(draft.validationError == "Choisissez ou générez une clé dédiée.")
        #expect(draft.build() == nil)
    }

    @Test func systemModeNeedsAUser() {
        var draft = sessionDraft()
        draft.managedKey = "dgx"
        draft.sshUser = ""
        #expect(draft.validationError?.contains("utilisateur SSH") == true)
    }

    /// Switching a Session tunnel to System drops what the daemon refuses.
    @Test func systemBuildKeepsOnlyTheAllowList() throws {
        var draft = sessionDraft()
        draft.managedKey = "dgx"
        let tunnel = try #require(draft.build())

        #expect(tunnel.mode == .system)
        #expect(tunnel.type == .localForward)
        #expect(tunnel.keyRef == .managed("dgx"))
        #expect(tunnel.proxyJump == nil)
        #expect(tunnel.extraArgs.isEmpty)
        #expect(!tunnel.autoStart && !tunnel.autoRestart)
        _ = try SSHCommandBuilder.arguments(for: tunnel)
    }

    @Test func backToSessionUsesTheUserKeyAgain() throws {
        var draft = sessionDraft()
        draft.managedKey = "dgx"
        draft.mode = .session
        let tunnel = try #require(draft.build())
        #expect(tunnel.keyRef == .path("~/.ssh/id_ed25519"))
        #expect(tunnel.proxyJump == "bastion")
    }
}

@MainActor
struct MenuBarStatusTests {
    @Test func systemFailuresWinOverSession() {
        #expect(MenuBarIconStatus.combined(.running, system: [.up, .hostKeyUnknown]) == .failed)
        #expect(MenuBarIconStatus.combined(.neutral, system: [.reconnecting]) == .reconnecting)
        #expect(MenuBarIconStatus.combined(.neutral, system: [.up]) == .running)
        #expect(MenuBarIconStatus.combined(.failed, system: [.up]) == .failed)
        #expect(MenuBarIconStatus.combined(.neutral, system: []) == .neutral)
    }
}
