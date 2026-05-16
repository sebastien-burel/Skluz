import Foundation

nonisolated enum TunnelType: String, Codable, CaseIterable, Sendable {
    case localForward       // -L localPort:remoteHost:remotePort
    case remoteForward      // -R localPort:remoteHost:remotePort
    case dynamic            // -D localPort (SOCKS)
}
