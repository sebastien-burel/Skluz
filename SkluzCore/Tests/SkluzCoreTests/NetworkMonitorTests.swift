import Testing
@testable import SkluzCore

struct NetworkMonitorTests {

    private let offline = NetworkMonitor.Snapshot(isSatisfied: false, interfaces: [], gateways: [])
    private let wifi = NetworkMonitor.Snapshot(isSatisfied: true, interfaces: ["en0"], gateways: ["192.168.1.1:0"])
    private let ethernet = NetworkMonitor.Snapshot(isSatisfied: true, interfaces: ["en7"], gateways: ["10.0.0.1:0"])

    @Test func comingOnlineIsAvailable() {
        #expect(NetworkMonitor.event(from: offline, to: wifi) == .available)
    }

    @Test func goingOfflineIsLost() {
        #expect(NetworkMonitor.event(from: wifi, to: offline) == .lost)
    }

    @Test func switchingInterfaceIsInterfacesChanged() {
        #expect(NetworkMonitor.event(from: wifi, to: ethernet) == .interfacesChanged)
    }

    @Test func newGatewayOnSameInterfaceIsInterfacesChanged() {
        var otherNetwork = wifi
        otherNetwork.gateways = ["172.16.0.1:0"]
        #expect(NetworkMonitor.event(from: wifi, to: otherNetwork) == .interfacesChanged)
    }

    @Test func unchangedPathEmitsNothing() {
        #expect(NetworkMonitor.event(from: wifi, to: wifi) == nil)
        #expect(NetworkMonitor.event(from: offline, to: offline) == nil)
    }
}
