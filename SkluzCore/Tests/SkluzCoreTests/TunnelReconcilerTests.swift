import Foundation
import Testing
@testable import SkluzCore

struct TunnelReconcilerTests {

    private func tunnel(_ name: String, mode: TunnelMode = .system, enabled: Bool = true,
                        localPort: Int = 8000) -> TunnelConfig {
        TunnelConfig(name: name, mode: mode, type: .localForward, host: "h", user: "u",
                     keyRef: .managed("k"), localPort: localPort, enabled: enabled)
    }

    @Test func startsOnlyEnabledSystemTunnels() {
        let system = tunnel("a")
        let disabled = tunnel("b", enabled: false)
        let session = tunnel("c", mode: .session)

        let plan = TunnelReconciler.plan(active: [:], configured: [system, disabled, session])
        #expect(plan == .init(toStop: [], toStart: [system]))
    }

    @Test func unchangedConfigDoesNothing() {
        let a = tunnel("a")
        #expect(TunnelReconciler.plan(active: [a.id: a], configured: [a]) == .init(toStop: [], toStart: []))
    }

    @Test func editedTunnelIsRestarted() {
        let before = tunnel("a")
        var after = before
        after.localPort = 9000

        let plan = TunnelReconciler.plan(active: [before.id: before], configured: [after])
        #expect(plan == .init(toStop: [before.id], toStart: [after]))
    }

    @Test func removedOrDisabledTunnelsAreStopped() {
        let removed = tunnel("a")
        let disabled = tunnel("b")
        var nowDisabled = disabled
        nowDisabled.enabled = false

        let plan = TunnelReconciler.plan(active: [removed.id: removed, disabled.id: disabled],
                                         configured: [nowDisabled])
        #expect(plan == .init(toStop: [removed.id, disabled.id], toStart: []))
    }
}
