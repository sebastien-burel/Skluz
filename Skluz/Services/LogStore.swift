import Foundation

actor LogStore {
    private let capacityPerTunnel: Int
    private var buffers: [UUID: [String]] = [:]

    init(capacityPerTunnel: Int = 1000) {
        self.capacityPerTunnel = capacityPerTunnel
    }

    func append(_ line: String, for id: UUID) {
        var buffer = buffers[id] ?? []
        buffer.append(line)
        if buffer.count > capacityPerTunnel {
            buffer.removeFirst(buffer.count - capacityPerTunnel)
        }
        buffers[id] = buffer
    }

    func lines(for id: UUID) -> [String] {
        buffers[id] ?? []
    }

    func clear(_ id: UUID) {
        buffers.removeValue(forKey: id)
    }
}
