import Foundation

// skluzd-xpc-probe — test client of the skluzd XPC API (PLAN_SKLUZD.md
// phase 4), built by Tools/xpc-probe/build.sh together with the SkluzCore
// sources. Not shipped.
//
//   probe version | status | list
//   probe upsert <tunnel.json> | delete <id> | enable <id> on|off
//   probe keys | genkey <name> | importkey <name> <private-key-file>
//   probe hostkeys <host> <port> | trust <host> <port> <type> <base64>

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
    case "keys":
        try output(try await client.listKeys())
    case "genkey" where arguments.count == 2:
        try output(try await client.generateKey(name: arguments[1]))
    case "importkey" where arguments.count == 3:
        try output(try await client.importKey(name: arguments[1],
                                              privateKey: try Data(contentsOf: URL(filePath: arguments[2]))))
    case "hostkeys" where arguments.count == 3:
        try output(try await client.fetchHostKeys(host: arguments[1], port: Int(arguments[2]) ?? 0))
    case "trust" where arguments.count == 5:
        try await client.trustHostKey(HostKey(type: arguments[3], key: arguments[4], fingerprint: ""),
                                      host: arguments[1], port: Int(arguments[2]) ?? 0)
        print("ok")
    default:
        FileHandle.standardError.write(Data("usage: see Tools/xpc-probe/main.swift\n".utf8))
        exit(EX_USAGE)
    }
    exitCode = 0
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exitCode = 1
}
exit(exitCode)
