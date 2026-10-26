import Foundation
import Darwin
import SkluzCore

// skluzd — root daemon running the System-mode tunnels (PLAN_SKLUZD.md).
//
//   sudo skluzd                 production layout, /Library/Application Support/Skluz
//   skluzd --base-dir <dir>     development only: refused as root, the files
//                               must then belong to the current user
//   skluzd --version

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("skluzd: \(message)\n".utf8))
    exit(EX_USAGE)
}

var arguments = CommandLine.arguments.dropFirst()
var devBaseDirectory: String?
while let argument = arguments.popFirst() {
    switch argument {
    case "--version":
        print("skluzd \(version)")
        exit(0)
    case "--base-dir":
        guard let value = arguments.popFirst() else { fail("--base-dir attend un dossier.") }
        devBaseDirectory = value
    default:
        fail("argument inconnu : \(argument)")
    }
}

let paths: SystemPaths
let ownership: FileOwnership
switch (getuid() == 0, devBaseDirectory) {
case (true, nil):
    paths = .standard
    ownership = .root
case (true, .some):
    // A root daemon must never be pointed at user-controlled files.
    fail("--base-dir est réservé au développement et refusé en root.")
case (false, nil):
    fail("doit tourner en root (sudo), ou avec --base-dir pour le développement.")
case (false, .some(let dir)):
    paths = SystemPaths(baseDirectory: URL(filePath: dir, directoryHint: .isDirectory))
    ownership = .current
}

Log.config.info("skluzd \(version) démarre (pid \(getpid()), config : \(paths.baseDirectory.path(percentEncoded: false))).")

let daemon = Daemon(paths: paths, ownership: ownership)

// Signals are handled on the main queue instead of the default actions.
func onSignal(_ signal: Int32, _ handler: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
    Darwin.signal(signal, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
    source.setEventHandler(handler: handler)
    source.resume()
    return source
}

let terminate: @Sendable () -> Void = { [daemon] in
    Task {
        await daemon.shutdown()
        Log.supervisor.info("skluzd arrêté.")
        exit(0)
    }
}
let signalSources = [
    onSignal(SIGTERM, terminate),
    onSignal(SIGINT, terminate),
    onSignal(SIGHUP) { [daemon] in
        Task { await daemon.reload(reason: "SIGHUP") }
    }
]

Task { [daemon] in
    await daemon.start()
}

withExtendedLifetime(signalSources) {
    dispatchMain()
}
