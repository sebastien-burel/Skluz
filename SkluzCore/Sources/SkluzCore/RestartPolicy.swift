import Foundation

/// Reconnection rules, per mode (`PLAN_SKLUZD.md` phase 1, decision D3).
public enum RestartPolicy {
    /// A run this long is a real reconnection: the failure counter restarts
    /// from zero on its next exit.
    public static let stableUptime: TimeInterval = 30

    /// Session: fixed schedule from `PLAN_SKLUZ.md` §6, then give up.
    public static let sessionSchedule: [Double] = [2, 5, 15, 30, 60]

    /// System: exponential from 1 s, capped, jittered, never gives up.
    public static let systemMaxDelay: Double = 60
    public static let systemJitter: Double = 0.2

    /// Delay before attempt `attempt` (1-based), or `nil` to give up.
    /// `random` is a uniform value in `0..<1`, injected for tests.
    public static func delay(forAttempt attempt: Int, mode: TunnelMode, random: Double) -> Duration? {
        guard attempt >= 1 else { return nil }
        switch mode {
        case .session:
            guard attempt <= sessionSchedule.count else { return nil }
            return .seconds(sessionSchedule[attempt - 1])
        case .system:
            // 2^6 = 64 already exceeds the cap: stop growing to avoid overflow.
            let base = min(systemMaxDelay, Double(1 << min(attempt - 1, 6)))
            let factor = 1 - systemJitter + 2 * systemJitter * random
            return .seconds(min(systemMaxDelay, base * factor))
        }
    }

    /// Whether an ssh that exited on its own should be restarted.
    /// `exitCode` is `nil` for an adopted process, whose status is unknown.
    public static func shouldRestart(mode: TunnelMode, autoRestart: Bool, exitCode: Int32?) -> Bool {
        switch mode {
        case .session: autoRestart && exitCode != 0
        case .system:  true
        }
    }

    /// Failure counter after an exit: back to the first attempt if the run
    /// was stable, otherwise one more.
    public static func nextAttempt(previous: Int, uptime: TimeInterval) -> Int {
        uptime >= stableUptime ? 1 : previous + 1
    }
}
