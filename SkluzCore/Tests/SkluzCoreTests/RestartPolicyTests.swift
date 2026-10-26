import Foundation
import Testing
@testable import SkluzCore

struct RestartPolicyTests {

    private func seconds(_ attempt: Int, _ mode: TunnelMode, random: Double = 0.5) -> Double? {
        RestartPolicy.delay(forAttempt: attempt, mode: mode, random: random)?.timeInterval
    }

    // MARK: - Session (unchanged schedule, PLAN_SKLUZ.md §6)

    @Test func sessionFollowsPlannedSchedule() {
        #expect((1...5).map { seconds($0, .session) } == [2, 5, 15, 30, 60])
    }

    @Test func sessionGivesUpBeyondFiveAttempts() {
        #expect(seconds(6, .session) == nil)
        #expect(seconds(99, .session) == nil)
    }

    @Test func sessionHasNoJitter() {
        #expect(seconds(3, .session, random: 0) == 15)
        #expect(seconds(3, .session, random: 0.999) == 15)
    }

    @Test func nonPositiveAttemptIsRejected() {
        #expect(seconds(0, .session) == nil)
        #expect(seconds(-1, .system) == nil)
    }

    // MARK: - System

    @Test func systemIsExponentialAndCappedWithoutJitterAtMidpoint() {
        #expect((1...9).map { seconds($0, .system) } == [1, 2, 4, 8, 16, 32, 60, 60, 60])
    }

    @Test func systemNeverGivesUp() {
        #expect(seconds(10_000, .system) == 60)
    }

    @Test func systemJitterStaysWithinTwentyPercentAndUnderCap() throws {
        let low = try #require(seconds(4, .system, random: 0))
        let high = try #require(seconds(4, .system, random: 0.999_999))
        #expect(abs(low - 6.4) < 1e-9)
        #expect(high > 9.59 && high <= 9.6)
        #expect(try #require(seconds(7, .system, random: 0.999_999)) <= 60)
        #expect(try #require(seconds(7, .system, random: 0)) >= 48)
    }

    // MARK: - Restart decision and counter

    @Test func sessionRestartsOnlyOnFailureWithAutoRestart() {
        #expect(RestartPolicy.shouldRestart(mode: .session, autoRestart: true, exitCode: 255))
        #expect(RestartPolicy.shouldRestart(mode: .session, autoRestart: true, exitCode: nil))
        #expect(!RestartPolicy.shouldRestart(mode: .session, autoRestart: true, exitCode: 0))
        #expect(!RestartPolicy.shouldRestart(mode: .session, autoRestart: false, exitCode: 255))
    }

    @Test func systemAlwaysRestarts() {
        #expect(RestartPolicy.shouldRestart(mode: .system, autoRestart: false, exitCode: 0))
        #expect(RestartPolicy.shouldRestart(mode: .system, autoRestart: false, exitCode: 255))
    }

    @Test func counterResetsOnlyAfterStableUptime() {
        #expect(RestartPolicy.nextAttempt(previous: 3, uptime: 29.9) == 4)
        #expect(RestartPolicy.nextAttempt(previous: 3, uptime: 30) == 1)
        #expect(RestartPolicy.nextAttempt(previous: 0, uptime: 0.4) == 1)
    }
}

struct AdminCheckTests {
    @Test func rootIsAdminAndNobodyIsNot() {
        #expect(AdminCheck.isAdmin(uid: 0))
        #expect(!AdminCheck.isAdmin(uid: uid_t(UInt32(bitPattern: -2))))
    }
}
