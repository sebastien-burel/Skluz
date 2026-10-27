import Foundation
import SkluzCore

// skluz — status of the System tunnels run by skluzd, usable over SSH with
// no graphical session (PLAN_SKLUZD.md phase 7).
//
//   skluz status           table: nom | mode | état | port | uptime | reconnexions | dernière erreur
//   skluz status --json    the daemon's status, as JSON
//   skluz check            exit 0 if every enabled System tunnel is up, 1 otherwise
//   sudo skluz uninstall [--purge] [--yes]
//                          remove the service, the app and the link; --purge
//                          also deletes the System tunnels and dedicated keys
//   skluz --version

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

let usage = """
    usage: skluz status [--json]
           skluz check
           sudo skluz uninstall [--purge] [--yes]
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

/// The app bundle this CLI belongs to: …/Skluz.app/Contents/Helpers/skluz,
/// through the /usr/local/bin/skluz link.
func appBundle() -> URL? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_pidpath(getpid(), &buffer, UInt32(MAXPATHLEN))
    guard length > 0 else { return nil }
    let executable = URL(fileURLWithPath: String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
                                                 as: UTF8.self))
    return executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// Runs the bundled uninstall script as root, after checking that the
/// bundle (and so the script) can only have been written by root.
func uninstall(purge: Bool, assumeYes: Bool) -> Never {
    guard getuid() == 0 else { fail("à lancer avec sudo : sudo skluz uninstall") }
    guard let bundle = appBundle() else { fail("emplacement de l'app introuvable.") }
    if let problem = InstallationCheck.firstProblem(bundle: bundle) {
        fail("refusé, le script de désinstallation n'est pas sûr : \(problem.message)")
    }
    let script = bundle.appending(path: "Contents/Resources/skluz-uninstall.sh")

    if !assumeYes {
        print("Supprimer le service système, \(bundle.path(percentEncoded: false)) et /usr/local/bin/skluz ?")
        print(purge
              ? "La configuration système (tunnels Système, clés dédiées, known_hosts) sera AUSSI effacée."
              : "La configuration système est conservée (--purge pour l'effacer).")
        print("Confirmer [o/N] : ", terminator: "")
        guard let answer = readLine()?.lowercased(), ["o", "oui", "y", "yes"].contains(answer) else {
            print("Annulé.")
            exit(0)
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path(percentEncoded: false)] + (purge ? ["--purge"] : [])
    do {
        try process.run()
    } catch {
        fail(error.localizedDescription)
    }
    process.waitUntilExit()
    exit(process.terminationStatus)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "uninstall" {
    let options = Set(arguments.dropFirst())
    guard options.isSubset(of: ["--purge", "--yes"]) else { fail(usage, code: EX_USAGE) }
    uninstall(purge: options.contains("--purge"), assumeYes: options.contains("--yes"))
}
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
