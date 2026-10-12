import Foundation
import Testing
@testable import Skluz

struct TunnelRunnerAutoStartTests {

    private func tunnel(autoStart: Bool, enabled: Bool = true) -> Tunnel {
        Tunnel(name: "t", type: .localForward, sshHost: "host", localPort: 8080,
               remoteHost: "localhost", remotePort: 80,
               autoStart: autoStart, enabled: enabled)
    }

    @Test func selectsOnlyAutoStartTunnels() {
        let auto = tunnel(autoStart: true)
        let manual = tunnel(autoStart: false)
        let picked = TunnelRunner.autoStartCandidates(among: [auto, manual], alreadyRunning: [])
        #expect(picked.map(\.id) == [auto.id])
    }

    @Test func skipsDisabledTunnels() {
        let disabled = tunnel(autoStart: true, enabled: false)
        #expect(TunnelRunner.autoStartCandidates(among: [disabled], alreadyRunning: []).isEmpty)
    }

    @Test func skipsAdoptedOrphans() {
        let adopted = tunnel(autoStart: true)
        let fresh = tunnel(autoStart: true)
        let picked = TunnelRunner.autoStartCandidates(among: [adopted, fresh],
                                                      alreadyRunning: [adopted.id])
        #expect(picked.map(\.id) == [fresh.id])
    }
}
