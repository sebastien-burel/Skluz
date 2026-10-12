import Foundation

public actor LogStore {
    private let capacityPerTunnel: Int
    private var buffers: [UUID: [String]] = [:]

    public init(capacityPerTunnel: Int = 1000) {
        self.capacityPerTunnel = capacityPerTunnel
    }

    public func append(_ line: String, for id: UUID) {
        var buffer = buffers[id] ?? []
        buffer.append(line)
        if buffer.count > capacityPerTunnel {
            buffer.removeFirst(buffer.count - capacityPerTunnel)
        }
        buffers[id] = buffer
    }

    public func lines(for id: UUID) -> [String] {
        buffers[id] ?? []
    }

    public func clear(_ id: UUID) {
        buffers.removeValue(forKey: id)
    }
}
