import Foundation
import Darwin
import SkluzCore

// skluzd — root daemon running the System-mode tunnels (PLAN_SKLUZD.md).
//
//   sudo skluzd                 production layout, /Library/Application Support/Skluz
//   skluzd --base-dir <dir>     development only: refused as root, the files
//                               must then belong to the current user
//   skluzd --version

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("skluzd: \(message)\n".utf8))
    exit(EX_USAGE)
}

var arguments = CommandLine.arguments.dropFirst()
var devBaseDirectory: String?
while let argument = arguments.popFirst() {
    switch argument {
    case "--version":
        print("skluzd \(daemonVersion)")
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

Log.config.info("skluzd \(daemonVersion) démarre (pid \(getpid()), config : \(paths.baseDirectory.path(percentEncoded: false))).")

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

// Updating the app replaces this binary while it runs. Clients then refuse
// the old process (its signature can no longer be checked on disk) and the
// app cannot even ask it to restart: exit by itself, without stopping the
// tunnels, so that launchd (KeepAlive) starts the new binary, which adopts
// the running ssh. The delay lets the copy of the new bundle finish. Also
// active in development mode, where it is harmless and testable.
func watchOwnExecutable() -> DispatchSourceFileSystemObject? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_pidpath(getpid(), &buffer, UInt32(MAXPATHLEN))
    guard length > 0 else { return nil }
    let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename, .revoke],
                                                           queue: .main)
    source.setEventHandler {
        source.cancel()
        Log.supervisor.info("Binaire remplacé (mise à jour) : relance dans 5 s, les tunnels restent ouverts.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    return source
}
let executableWatch = watchOwnExecutable()

// The Mach service only exists when launchd runs the daemon: in development
// mode (--base-dir) there is nothing to listen on.
let xpcServer = devBaseDirectory == nil ? XPCServer(daemon: daemon) : nil

Task { [daemon, xpcServer] in
    await daemon.start()
    xpcServer?.start()
}

withExtendedLifetime((signalSources, xpcServer, executableWatch)) {
    dispatchMain()
}
