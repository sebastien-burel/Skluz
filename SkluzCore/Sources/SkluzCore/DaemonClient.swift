import Foundation

public enum DaemonClientError: Error, Equatable, LocalizedError {
    /// The connection failed: daemon not running, or one side refused the
    /// other's code signature.
    case unreachable(String)
    /// The daemon refused the request.
    case refused(String)
    case invalidReply

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "Service système injoignable : \(detail)"
        case .refused(let message):    message
        case .invalidReply:            "Réponse invalide du service système."
        }
    }
}

/// Async client of skluzd, for the app and the CLI.
public final class DaemonClient: @unchecked Sendable {
    // NSXPCConnection is thread-safe; it is only created and invalidated here.
    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(machServiceName: DaemonAPI.machServiceName, options: .privileged)
        connection.remoteObjectInterface = DaemonAPI.makeInterface()
        // Only talk to the real daemon, signed by the team.
        connection.setCodeSigningRequirement(DaemonAPI.daemonRequirement)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    public func version() async throws -> String {
        try await call { proxy, done in
            proxy.version { done(.success($0)) }
        }
    }

    public func listTunnels() async throws -> [TunnelConfig] {
        try await call { proxy, done in
            proxy.listTunnels { data, error in done(Self.decode(data, error)) }
        }
    }

    public func status() async throws -> DaemonStatus {
        try await call { proxy, done in
            proxy.status { data, error in done(Self.decode(data, error)) }
        }
    }

    public func upsertTunnel(_ tunnel: TunnelConfig) async throws {
        let data = try DaemonAPI.encoder().encode(tunnel)
        try await call { proxy, done in
            proxy.upsertTunnel(data) { done(Self.check($0)) }
        }
    }

    public func deleteTunnel(id: UUID) async throws {
        try await call { proxy, done in
            proxy.deleteTunnel(id: id.uuidString) { done(Self.check($0)) }
        }
    }

    public func setEnabled(id: UUID, _ enabled: Bool) async throws {
        try await call { proxy, done in
            proxy.setEnabled(id: id.uuidString, enabled: enabled) { done(Self.check($0)) }
        }
    }

    public func listKeys() async throws -> [ManagedKey] {
        try await call { proxy, done in
            proxy.listKeys { data, error in done(Self.decode(data, error)) }
        }
    }

    public func generateKey(name: String) async throws -> ManagedKey {
        try await call { proxy, done in
            proxy.generateKey(name: name) { data, error in done(Self.decode(data, error)) }
        }
    }

    public func importKey(name: String, privateKey: Data) async throws -> ManagedKey {
        try await call { proxy, done in
            proxy.importKey(name: name, privateKey: privateKey) { data, error in done(Self.decode(data, error)) }
        }
    }

    public func fetchHostKeys(host: String, port: Int) async throws -> [HostKey] {
        try await call { proxy, done in
            proxy.fetchHostKey(host: host, port: port) { data, error in done(Self.decode(data, error)) }
        }
    }

    public func trustHostKey(_ key: HostKey, host: String, port: Int) async throws {
        try await call { proxy, done in
            proxy.trustHostKey(host: host, port: port, type: key.type, key: key.key) { done(Self.check($0)) }
        }
    }

    public func installCommandLineTool() async throws {
        try await call { proxy, done in
            proxy.installCommandLineTool { done(Self.check($0)) }
        }
    }

    public func restart() async throws {
        try await call { proxy, done in
            proxy.restart { done(Self.check($0)) }
        }
    }

    public func purgeConfiguration() async throws {
        try await call { proxy, done in
            proxy.purgeConfiguration { done(Self.check($0)) }
        }
    }

    // MARK: - Plumbing

    /// Resumes exactly once, from the reply or from the connection error.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<T, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    private func call<T: Sendable>(
        _ body: (SkluzDaemonProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(DaemonClientError.unreachable(error.localizedDescription)))
            }
            guard let daemon = proxy as? SkluzDaemonProtocol else {
                once.resume(.failure(DaemonClientError.invalidReply))
                return
            }
            body(daemon) { once.resume($0) }
        }
    }

    private static func decode<T: Decodable>(_ data: Data?, _ error: String?) -> Result<T, Error> {
        if let error { return .failure(DaemonClientError.refused(error)) }
        guard let data, let value = try? DaemonAPI.decoder().decode(T.self, from: data) else {
            return .failure(DaemonClientError.invalidReply)
        }
        return .success(value)
    }

    private static func check(_ error: String?) -> Result<Void, Error> {
        error.map { .failure(DaemonClientError.refused($0)) } ?? .success(())
    }
}
