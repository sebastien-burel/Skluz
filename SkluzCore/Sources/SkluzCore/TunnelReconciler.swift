import Foundation

/// What the daemon must change when the config is (re)loaded: only enabled
/// System-mode tunnels run, and an edited tunnel is restarted.
public enum TunnelReconciler {
    public struct Plan: Equatable, Sendable {
        public var toStop: [UUID]
        public var toStart: [TunnelConfig]
    }

    public static func plan(active: [UUID: TunnelConfig], configured: [TunnelConfig]) -> Plan {
        let desired = Dictionary(
            configured.filter { $0.mode == .system && $0.enabled }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let toStop = active.keys.filter { desired[$0] != active[$0] }
        let toStart = desired.values.filter { active[$0.id] != $0 }
        return Plan(
            toStop: toStop.sorted { (active[$0]?.name ?? "") < (active[$1]?.name ?? "") },
            toStart: toStart.sorted { $0.name < $1.name }
        )
    }
}
