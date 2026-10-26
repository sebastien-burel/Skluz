import Foundation

/// Runs a system tool by absolute path, arguments as an array, never through
/// a shell, and collects its output.
enum ToolRunner {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data

        var stderrText: String {
            String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func run(_ path: String, _ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        // Drain both pipes concurrently: a full pipe would block the child.
        let errorData = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData.value = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: outputData, stderr: errorData.value)
    }

    private final class Box: @unchecked Sendable {
        var value = Data()
    }
}
