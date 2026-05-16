import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private let tunnelStore = TunnelStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
        Task { [tunnelStore] in
            do {
                try await tunnelStore.load()
                let count = await tunnelStore.tunnels.count
                print("[Skluz] loaded \(count) tunnel(s) from disk")
            } catch {
                print("[Skluz] failed to load tunnels: \(error)")
            }
        }
    }
}
