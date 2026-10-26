import Foundation
import os

/// `os.Logger` under subsystem `net.haruni.skluzd`, mirrored to stderr when
/// the daemon runs in a terminal (manual runs with `sudo`).
enum Log: String {
    case supervisor
    case xpc
    case config

    private static let echoToTerminal = isatty(STDERR_FILENO) == 1

    private var logger: Logger {
        Logger(subsystem: "net.haruni.skluzd", category: rawValue)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        echo("info", message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        echo("error", message)
    }

    private func echo(_ level: String, _ message: String) {
        guard Self.echoToTerminal else { return }
        FileHandle.standardError.write(Data("[\(rawValue)] \(level): \(message)\n".utf8))
    }
}
