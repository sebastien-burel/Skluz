import Foundation
import Observation
import ServiceManagement
import SkluzCore

/// The app's view of skluzd (`PLAN_SKLUZD.md` phase 6): System tunnels and
/// their live status, polled every 5 s while the service is enabled, plus
/// the key and host key actions used by the editor.
@Observable
final class SystemTunnelsModel {
    static let pollInterval: Duration = .seconds(5)

    private(set) var isServiceEnabled = false
    /// The daemon answered the last poll.
    private(set) var isReachable = false
    private(set) var status: DaemonStatus?
    private(set) var tunnels: [TunnelConfig] = []
    private(set) var keys: [ManagedKey] = []
    private(set) var lastError: String?
    /// Outcome of the automatic restart after an update, for Preferences.
    private(set) var updateMessage: String?
    let isAdmin = AdminCheck.isCurrentUserAdmin
    private var hasRequestedRestart = false

    /// Notifies the menu bar when System states change.
    var onChange: (() -> Void)?

    private var client: DaemonClient?
    nonisolated(unsafe) private var pollTask: Task<Void, Never>?

    deinit {
        pollTask?.cancel()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Mode changes and edits are only possible with a running service, as
    /// an admin.
    var canManage: Bool {
        isReachable && isAdmin
    }

    /// Why System actions are unavailable, if they are.
    var unavailableReason: String? {
        if !isServiceEnabled { return "Activez le service système dans les Préférences." }
        if !isReachable { return "Service système injoignable\(lastError.map { " : \($0)" } ?? ".")" }
        if !isAdmin { return "Modification réservée aux administrateurs de ce Mac." }
        return nil
    }

    func status(for id: UUID) -> TunnelStatus? {
        status?.tunnels.first { $0.id == id }
    }

    func refresh() async {
        isServiceEnabled = DaemonManager.status == .enabled
        guard isServiceEnabled else {
            reset(error: nil)
            return
        }
        do {
            let client = connection()
            let newStatus = try await client.status()
            let newTunnels = try await client.listTunnels()
            status = newStatus
            tunnels = newTunnels
            isReachable = true
            lastError = nil
            await restartIfOutdated(newStatus)
        } catch {
            reset(error: error.localizedDescription)
        }
        onChange?()
    }

    func refreshKeys() async {
        guard isReachable else { return }
        keys = (try? await connection().listKeys()) ?? keys
    }

    // MARK: - Actions (admins, through the daemon's own checks)

    func upsert(_ tunnel: TunnelConfig) async throws {
        try await run { try await $0.upsertTunnel(tunnel) }
    }

    func delete(id: UUID) async throws {
        try await run { try await $0.deleteTunnel(id: id) }
    }

    func setEnabled(id: UUID, _ enabled: Bool) async throws {
        try await run { try await $0.setEnabled(id: id, enabled) }
    }

    func generateKey(name: String) async throws -> ManagedKey {
        let key = try await connection().generateKey(name: name)
        await refreshKeys()
        return key
    }

    func fetchHostKeys(host: String, port: Int) async throws -> [HostKey] {
        try await connection().fetchHostKeys(host: host, port: port)
    }

    /// /usr/local/bin/skluz, created by the daemon (admins only).
    func installCommandLineTool() async throws {
        try await connection().installCommandLineTool()
    }

    /// Whether /usr/local/bin/skluz points to the CLI of the installed app.
    var isCommandLineToolInstalled: Bool {
        CommandLineLink.isInstalled(target: URL(filePath: DaemonManager.requiredBundlePath)
            .appending(path: "Contents/Helpers/skluz"))
    }

    func trust(_ key: HostKey, host: String, port: Int) async throws {
        try await run { try await $0.trustHostKey(key, host: host, port: port) }
    }

    /// Whether the daemon runs the same version as this app.
    var isDaemonUpToDate: Bool {
        guard let status else { return true }
        let app = DaemonManager.appVersion
        return status.version == app.short && status.build == app.build
    }

    /// After an update the daemon still runs the old binary: ask it to exit
    /// so launchd starts the new one (tunnels stay open and are adopted).
    /// Only from the installed app: a Debug build must not bounce it.
    private func restartIfOutdated(_ status: DaemonStatus) async {
        guard !isDaemonUpToDate else {
            if hasRequestedRestart { updateMessage = "Service mis à jour (\(status.version), build \(status.build ?? "?"))." }
            return
        }
        guard DaemonManager.isInstalledInApplications, isAdmin, !hasRequestedRestart else { return }
        hasRequestedRestart = true
        do {
            try await connection().restart()
            client = nil
            updateMessage = "Service en cours de relance sur la nouvelle version…"
        } catch {
            updateMessage = "Relance automatique impossible (\(error.localizedDescription)) : "
                + "désactivez puis réactivez le service."
        }
    }

    /// Removes Skluz entirely, run by the daemon as root.
    func uninstallApp(purge: Bool) async throws {
        try await connection().uninstallApp(purge: purge)
    }

    /// Uninstall, before unregistering: tunnels stopped, root files deleted.
    func purgeConfiguration() async throws {
        try await connection().purgeConfiguration()
    }

    // MARK: - Helpers

    private func connection() -> DaemonClient {
        if let client { return client }
        let client = DaemonClient()
        self.client = client
        return client
    }

    /// Runs a mutation, then refreshes so the menu reflects it at once.
    private func run(_ action: (DaemonClient) async throws -> Void) async throws {
        try await action(connection())
        await refresh()
    }

    private func reset(error: String?) {
        // A failed connection is not reusable: reconnect on the next poll.
        client = nil
        isReachable = false
        status = nil
        tunnels = []
        lastError = error
    }
}
