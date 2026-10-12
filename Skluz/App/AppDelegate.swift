import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tunnelStore = TunnelStore()
    private let logStore = LogStore()
    private let configParser = SSHConfigParser()
    private lazy var runner = TunnelRunner(logStore: logStore)
    private lazy var viewModel = TunnelsViewModel(
        store: tunnelStore,
        runner: runner,
        configParser: configParser,
        logStore: logStore
    )
    private var menuBarController: MenuBarController?

    /// Unit tests are hosted in the app: the real startup would load the
    /// user's tunnels.json and spawn their autoStart tunnels.
    static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        menuBarController = MenuBarController(viewModel: viewModel)
        Task { [viewModel] in
            await viewModel.load()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let runner = self.runner
        Task { @MainActor in
            await runner.stopAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
