import AppKit
import SkluzCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tunnelStore = TunnelStore()
    private let logStore = LogStore()
    private let configParser = SSHConfigParser()
    private lazy var runner = TunnelSupervisor(logStore: logStore, pidStore: RuntimePIDStore())
    private lazy var viewModel = TunnelsViewModel(
        store: tunnelStore,
        runner: runner,
        configParser: configParser,
        logStore: logStore
    )
    private let systemModel = SystemTunnelsModel()
    private var menuBarController: MenuBarController?
    private var updateWatch: DispatchSourceFileSystemObject?

    /// Unit tests are hosted in the app: the real startup would load the
    /// user's tunnels.json and spawn their autoStart tunnels.
    static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        // After an update relaunch, the previous instance may still be
        // quitting: two Session supervisors would fight over the same ports.
        Task {
            await Self.waitForOtherInstancesToQuit()
            start()
        }
    }

    private func start() {
        menuBarController = MenuBarController(viewModel: viewModel, system: systemModel)
        systemModel.startPolling()
        updateWatch = DaemonManager.relaunchWhenReplaced()
        Task { [viewModel] in
            await viewModel.load()
        }
    }

    /// Asks any other running Skluz to quit and waits for it (10 s at most,
    /// then forces it).
    private static func waitForOtherInstancesToQuit() async {
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != current.processIdentifier }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        let deadline = ContinuousClock.now + .seconds(10)
        while others.contains(where: { !$0.isTerminated }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
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
