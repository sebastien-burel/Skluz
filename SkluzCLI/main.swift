import Foundation
import SkluzCore

// skluz — status of the System tunnels run by skluzd, usable over SSH with
// no graphical session (PLAN_SKLUZD.md phase 7).
//
//   skluz status           table: nom | mode | état | port | uptime | reconnexions | dernière erreur
//   skluz status --json    the daemon's status, as JSON
//   skluz check            exit 0 if every enabled System tunnel is up, 1 otherwise
//   skluz --version

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

let usage = """
    usage: skluz status [--json]
           skluz check
           skluz --version
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("skluz: \(message)\n".utf8))
    exit(code)
}

func fetchStatus() async -> DaemonStatus {
    do {
        return try await DaemonClient().status()
    } catch {
        fail(error.localizedDescription)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments {
case ["--version"]:
    print("skluz \(version)")

case ["status"]:
    print(StatusReport.table(await fetchStatus()))

case ["status", "--json"]:
    let encoder = DaemonAPI.encoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        print(String(decoding: try encoder.encode(await fetchStatus()), as: UTF8.self))
    } catch {
        fail(error.localizedDescription)
    }

case ["check"]:
    let status = await fetchStatus()
    print(StatusReport.summary(status))
    exit(StatusReport.isHealthy(status) ? 0 : 1)

default:
    fail(usage, code: EX_USAGE)
}
