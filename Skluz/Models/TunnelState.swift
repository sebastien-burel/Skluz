import Foundation

nonisolated enum TunnelState: Equatable, Sendable {
    case stopped
    case starting
    case running(pid: Int32, since: Date)
    case failed(reason: String, at: Date)
    case reconnecting(attempt: Int)
}
