import Foundation
import Darwin
import Darwin.membership
import SkluzCore

/// Accepts XPC clients signed by the team (`DaemonAPI.clientRequirement`)
/// and hands each connection its own `DaemonService`.
final class XPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener(machServiceName: DaemonAPI.machServiceName)
    private let daemon: Daemon

    init(daemon: Daemon) {
        self.daemon = daemon
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
        Log.xpc.info("Écoute XPC sur \(DaemonAPI.machServiceName).")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Checked by the system on every message, against the audit token
        // of the peer: a client that fails it is invalidated.
        connection.setCodeSigningRequirement(DaemonAPI.clientRequirement)
        let uid = connection.effectiveUserIdentifier
        let pid = connection.processIdentifier
        connection.exportedInterface = DaemonAPI.makeInterface()
        connection.exportedObject = DaemonService(daemon: daemon, uid: uid, pid: pid)
        connection.invalidationHandler = {
            Log.xpc.info("Client pid \(pid) déconnecté.")
        }
        connection.resume()
        Log.xpc.info("Client pid \(pid) (uid \(uid)) connecté.")
        return true
    }
}

/// One per connection: knows who the caller is, to restrict mutations to
/// admins (`PLAN_SKLUZD.md` security constraint 6).
final class DaemonService: NSObject, SkluzDaemonProtocol, @unchecked Sendable {
    private let daemon: Daemon
    private let uid: uid_t
    private let pid: pid_t

    init(daemon: Daemon, uid: uid_t, pid: pid_t) {
        self.daemon = daemon
        self.uid = uid
        self.pid = pid
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(daemonVersion)
    }

    func listTunnels(reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task {
            do {
                reply(try DaemonAPI.encoder().encode(await daemon.listTunnels()), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func status(reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task {
            do {
                reply(try DaemonAPI.encoder().encode(await daemon.status()), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func upsertTunnel(_ tunnel: Data, reply: @escaping @Sendable (String?) -> Void) {
        mutate("upsertTunnel", reply: reply) { daemon in
            let config: TunnelConfig
            do {
                config = try DaemonAPI.decoder().decode(TunnelConfig.self, from: tunnel)
            } catch {
                throw DaemonError.invalidRequest("Tunnel illisible : \(error.localizedDescription)")
            }
            try await daemon.upsert(config)
        }
    }

    func deleteTunnel(id: String, reply: @escaping @Sendable (String?) -> Void) {
        mutate("deleteTunnel", reply: reply) { daemon in
            try await daemon.delete(id: try Self.parse(id))
        }
    }

    func setEnabled(id: String, enabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        mutate("setEnabled", reply: reply) { daemon in
            try await daemon.setEnabled(id: try Self.parse(id), enabled)
        }
    }

    // MARK: - Keys and host keys

    func listKeys(reply: @escaping @Sendable (Data?, String?) -> Void) {
        let paths = daemon.paths
        Task {
            Self.answer(reply) { try ManagedKeys.list(paths) }
        }
    }

    func generateKey(name: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        let (paths, ownership) = (daemon.paths, daemon.ownership)
        adminOnly("generateKey", reply: { reply(nil, $0) }) {
            Self.answer(reply) {
                let key = try ManagedKeys.generate(name: name, comment: "skluzd@\(Self.shortHostName)",
                                                   paths, ownership: ownership)
                Log.config.info("Clé « \(name) » générée (\(key.fingerprint)).")
                return key
            }
        }
    }

    func importKey(name: String, privateKey: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        let (paths, ownership) = (daemon.paths, daemon.ownership)
        adminOnly("importKey", reply: { reply(nil, $0) }) {
            Self.answer(reply) {
                let key = try ManagedKeys.importKey(name: name, privateKey: privateKey, paths, ownership: ownership)
                Log.config.info("Clé « \(name) » importée (\(key.fingerprint)).")
                return key
            }
        }
    }

    /// Admins only, one scan at a time: otherwise any local account could
    /// make root run unbounded ssh-keyscan against hosts of its choice.
    func fetchHostKey(host: String, port: Int, reply: @escaping @Sendable (Data?, String?) -> Void) {
        adminOnly("fetchHostKey", reply: { reply(nil, $0) }) {
            guard Self.scanGate.enter() else {
                reply(nil, "Une récupération de clé d'hôte est déjà en cours, réessayez dans quelques secondes.")
                return
            }
            defer { Self.scanGate.leave() }
            Self.answer(reply) { try HostKeys.scan(host: host, port: port) }
        }
    }

    func trustHostKey(host: String, port: Int, type: String, key: String,
                      reply: @escaping @Sendable (String?) -> Void) {
        let daemon = self.daemon
        adminOnly("trustHostKey", reply: reply) {
            do {
                try HostKeys.trust(type: type, key: key, host: host, port: port, daemon.paths,
                                   ownership: daemon.ownership)
                let fingerprint = ManagedKeys.fingerprint(ofBlob: key) ?? "?"
                Log.config.info("Clé d'hôte approuvée pour \(HostKeys.pattern(host: host, port: port)) : \(type) \(fingerprint).")
                reply(nil)
                await daemon.retryTunnels(host: host, port: port)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var busy = false

        func enter() -> Bool {
            lock.withLock {
                guard !busy else { return false }
                busy = true
                return true
            }
        }

        func leave() {
            lock.withLock { busy = false }
        }
    }

    private static let scanGate = Gate()

    private static var shortHostName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "mac" }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.split(separator: ".").first.map(String.init) ?? "mac"
    }

    private static func answer(_ reply: @Sendable (Data?, String?) -> Void,
                               _ body: () throws -> some Encodable) {
        do {
            reply(try DaemonAPI.encoder().encode(try body()), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    /// Runs `body` off the XPC queue if the caller is an admin, otherwise
    /// replies with the refusal.
    private func adminOnly(_ call: String, reply: @escaping @Sendable (String) -> Void,
                           _ body: @escaping @Sendable () async -> Void) {
        guard Self.isAdmin(uid: uid) else {
            Log.xpc.error("\(call) refusé : pid \(pid), uid \(uid) n'est pas administrateur.")
            reply("Modification réservée aux administrateurs de ce Mac.")
            return
        }
        Task { await body() }
    }

    private func mutate(_ call: String, reply: @escaping @Sendable (String?) -> Void,
                        _ body: @escaping @Sendable (Daemon) async throws -> Void) {
        guard Self.isAdmin(uid: uid) else {
            Log.xpc.error("\(call) refusé : pid \(pid), uid \(uid) n'est pas administrateur.")
            reply("Modification réservée aux administrateurs de ce Mac.")
            return
        }
        let daemon = self.daemon
        let pid = self.pid
        Task {
            do {
                try await body(daemon)
                reply(nil)
            } catch {
                Log.xpc.error("\(call) refusé (pid \(pid)) : \(error.localizedDescription)")
                reply(error.localizedDescription)
            }
        }
    }

    private static func parse(_ id: String) throws -> UUID {
        guard let uuid = UUID(uuidString: id) else { throw DaemonError.invalidRequest("Identifiant invalide : \(id)") }
        return uuid
    }

    static func isAdmin(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        guard let group = getgrnam("admin") else { return false }
        var userUUID = UUID().uuid
        var groupUUID = UUID().uuid
        var isMember: Int32 = 0
        let ok = withUnsafeMutableBytes(of: &userUUID) { user in
            withUnsafeMutableBytes(of: &groupUUID) { grp in
                let u = user.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let g = grp.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return mbr_uid_to_uuid(uid, u) == 0
                    && mbr_gid_to_uuid(group.pointee.gr_gid, g) == 0
                    && mbr_check_membership(u, g, &isMember) == 0
            }
        }
        return ok && isMember != 0
    }
}
