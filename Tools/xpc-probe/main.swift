import Foundation

// skluzd-xpc-probe — test client of the skluzd XPC API (PLAN_SKLUZD.md
// phase 4), built by Tools/xpc-probe/build.sh together with the SkluzCore
// sources. Not shipped.
//
//   probe version | status | list
//   probe upsert <tunnel.json> | delete <id> | enable <id> on|off

func output(_ value: some Encodable) throws {
    let encoder = DaemonAPI.encoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

let arguments = Array(CommandLine.arguments.dropFirst())
let client = DaemonClient()

let exitCode: Int32
do {
    switch arguments.first {
    case "version":
        print(try await client.version())
    case "status":
        try output(try await client.status())
    case "list":
        try output(try await client.listTunnels())
    case "upsert" where arguments.count == 2:
        let data = try Data(contentsOf: URL(filePath: arguments[1]))
        try await client.upsertTunnel(try DaemonAPI.decoder().decode(TunnelConfig.self, from: data))
        print("ok")
    case "delete" where arguments.count == 2:
        try await client.deleteTunnel(id: UUID(uuidString: arguments[1]) ?? UUID())
        print("ok")
    case "enable" where arguments.count == 3:
        try await client.setEnabled(id: UUID(uuidString: arguments[1]) ?? UUID(), arguments[2] == "on")
        print("ok")
    default:
        FileHandle.standardError.write(Data("usage: probe version|status|list|upsert <file>|delete <id>|enable <id> on|off\n".utf8))
        exit(EX_USAGE)
    }
    exitCode = 0
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exitCode = 1
}
exit(exitCode)
