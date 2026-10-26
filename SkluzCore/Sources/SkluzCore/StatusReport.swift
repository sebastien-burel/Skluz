import Foundation

/// Text rendering of `DaemonStatus` for `skluz status` and the rule of
/// `skluz check` (`PLAN_SKLUZD.md` phase 7).
public enum StatusReport {
    static let errorWidth = 60

    /// `skluz check`: the config is trusted and every enabled tunnel is up.
    public static func isHealthy(_ status: DaemonStatus) -> Bool {
        status.configProblem == nil && status.tunnels.allSatisfy { !$0.enabled || $0.phase == .up }
    }

    /// One line for `skluz check`.
    public static func summary(_ status: DaemonStatus) -> String {
        if let problem = status.configProblem {
            return "KO : configuration refusée — \(sanitize(problem))"
        }
        let enabled = status.tunnels.filter(\.enabled)
        let down = enabled.filter { $0.phase != .up }
        guard !down.isEmpty else {
            return "OK : \(enabled.count) tunnel(s) système actif(s)"
        }
        let names = down.map { "\(sanitize($0.name)) (\($0.phase.rawValue))" }.joined(separator: ", ")
        return "KO : \(down.count)/\(enabled.count) tunnel(s) système en panne — \(names)"
    }

    /// `nom | mode | état | port local | uptime | reconnexions | dernière erreur`
    public static func table(_ status: DaemonStatus, now: Date = Date()) -> String {
        var rows = [["NOM", "MODE", "ÉTAT", "PORT", "UPTIME", "RECONNEXIONS", "DERNIÈRE ERREUR"]]
        for tunnel in status.tunnels {
            rows.append([
                sanitize(tunnel.name),
                "système",
                tunnel.enabled ? tunnel.phase.rawValue : "disabled",
                String(tunnel.localPort),
                tunnel.phase == .up ? tunnel.since.map { uptime(from: $0, to: now) } ?? "—" : "—",
                String(tunnel.reconnections),
                truncate(sanitize(tunnel.lastError ?? ""), to: errorWidth)
            ])
        }
        let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
        var lines = rows.map { row in
            zip(row, widths).enumerated().map { index, cell in
                index == row.count - 1 ? cell.0 : cell.0.padding(toLength: cell.1, withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
        }
        if status.tunnels.isEmpty {
            lines.append("(aucun tunnel système)")
        }
        var header = "skluzd \(sanitize(status.version))"
        if let problem = status.configProblem {
            header += " — CONFIGURATION REFUSÉE : \(sanitize(problem))"
        }
        return ([header, ""] + lines).joined(separator: "\n")
    }

    /// `3 j 4 h`, `2 h 05 min`, `12 min`, `40 s`.
    public static func uptime(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
        if days > 0 { return "\(days) j \(hours) h" }
        if hours > 0 { return "\(hours) h \(String(format: "%02d", minutes)) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(seconds) s"
    }

    /// Errors partly come from the remote server (ssh stderr): never let them
    /// drive the terminal with escape or control characters.
    public static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
    }

    static func truncate(_ text: String, to width: Int) -> String {
        text.count <= width ? text : String(text.prefix(width - 1)) + "…"
    }
}
