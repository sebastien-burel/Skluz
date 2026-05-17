import Foundation

/// Lance un tunnel ssh de façon éphémère pour valider une configuration
/// (bouton « Tester » de l'éditeur, plan §8). N'interagit ni avec le
/// TunnelRunner, ni avec le LogStore, ni avec la persistance.
actor TunnelTester {
    enum Result: Sendable, Equatable {
        case success
        case failure(String)
    }

    private final class StderrBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lastLine: String?
        func absorb(_ chunk: String) {
            let lines = chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard let last = lines.last else { return }
            lock.lock(); lastLine = last; lock.unlock()
        }
        func last() -> String? {
            lock.lock(); defer { lock.unlock() }
            return lastLine
        }
    }

    func test(
        _ tunnel: Tunnel,
        successAfter: Duration = .seconds(4),
        hardCap: Duration = .seconds(10)
    ) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommandBuilder.sshPath)
        process.arguments = SSHCommandBuilder.arguments(for: tunnel)

        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        let box = StderrBox()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                box.absorb(text)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }

        let clock = ContinuousClock()
        let start = clock.now
        while process.isRunning {
            let elapsed = clock.now - start
            if elapsed >= successAfter {
                terminate(process, errPipe: errPipe, outPipe: outPipe)
                return .success
            }
            if elapsed >= hardCap { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let code = process.terminationStatus
        terminate(process, errPipe: errPipe, outPipe: outPipe)
        if let line = box.last(), !line.isEmpty {
            return .failure(line)
        }
        return .failure("ssh a quitté (code \(code)).")
    }

    private func terminate(_ process: Process, errPipe: Pipe, outPipe: Pipe) {
        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
