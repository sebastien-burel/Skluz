import Foundation
import Network

public enum NetworkEvent: Equatable, Sendable {
    /// Back online after having no usable path.
    case available
    /// Still online, but through other interfaces or gateways (Wi-Fi to
    /// Ethernet, new network): existing TCP connections are likely dead.
    case interfacesChanged
    case lost
}

/// `NWPathMonitor` turned into a debounced stream of `NetworkEvent`s.
public enum NetworkMonitor {
    public struct Snapshot: Equatable, Sendable {
        public var isSatisfied: Bool
        public var interfaces: [String]
        public var gateways: [String]

        public init(isSatisfied: Bool, interfaces: [String], gateways: [String]) {
            self.isSatisfied = isSatisfied
            self.interfaces = interfaces
            self.gateways = gateways
        }

        init(_ path: NWPath) {
            self.init(
                isSatisfied: path.status == .satisfied,
                interfaces: path.availableInterfaces.map(\.name).sorted(),
                gateways: path.gateways.map { "\($0)" }.sorted()
            )
        }
    }

    /// Event to emit when the settled path goes from `old` to `new`.
    public static func event(from old: Snapshot, to new: Snapshot) -> NetworkEvent? {
        switch (old.isSatisfied, new.isSatisfied) {
        case (false, true):  return .available
        case (true, false):  return .lost
        case (false, false): return nil
        case (true, true):
            return old.interfaces != new.interfaces || old.gateways != new.gateways
                ? .interfacesChanged : nil
        }
    }

    /// Live events. The first path is the baseline and emits nothing; macOS
    /// sends bursts of updates, so a change only counts once it has been
    /// stable for `debounce`.
    public static func events(debounce: Duration = .seconds(2)) -> AsyncStream<NetworkEvent> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "net.haruni.skluz.network-monitor")
            let monitor = NWPathMonitor()
            let state = DebounceState()

            monitor.pathUpdateHandler = { path in
                let snapshot = Snapshot(path)
                guard state.settled != nil else {
                    state.settled = snapshot
                    return
                }
                state.pending?.cancel()
                let work = DispatchWorkItem {
                    guard let settled = state.settled else { return }
                    state.settled = snapshot
                    if let event = event(from: settled, to: snapshot) {
                        continuation.yield(event)
                    }
                }
                state.pending = work
                queue.asyncAfter(deadline: .now() + debounce.timeInterval, execute: work)
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: queue)
        }
    }

    /// Only touched from the monitor's serial queue.
    private final class DebounceState: @unchecked Sendable {
        var settled: Snapshot?
        var pending: DispatchWorkItem?
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
