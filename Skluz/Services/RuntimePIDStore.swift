import Foundation

/// Persiste la correspondance tunnel → PID du process ssh, pour pouvoir
/// réadopter les tunnels survivant à un crash/SIGKILL de Skluz.
/// Best-effort : toute erreur d'I/O est silencieuse (on repart de zéro).
nonisolated struct RuntimePIDStore: Sendable {
    private struct Wrapper: Codable {
        var pids: [String: Int32]
    }

    let url: URL

    init(url: URL = RuntimePIDStore.defaultURL()) {
        self.url = url
    }

    static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Skluz", isDirectory: true)
            .appendingPathComponent("runtime.json", isDirectory: false)
    }

    func load() -> [UUID: Int32] {
        guard let data = try? Data(contentsOf: url),
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else {
            return [:]
        }
        var result: [UUID: Int32] = [:]
        for (key, pid) in wrapper.pids {
            if let id = UUID(uuidString: key) { result[id] = pid }
        }
        return result
    }

    func save(_ map: [UUID: Int32]) {
        let wrapper = Wrapper(pids: Dictionary(
            uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) }
        ))
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
