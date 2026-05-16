import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tunnelStore = TunnelStore()
    private lazy var viewModel = TunnelsViewModel(store: tunnelStore)
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(viewModel: viewModel)
        Task { [viewModel] in
            await viewModel.load()
        }
    }
}
