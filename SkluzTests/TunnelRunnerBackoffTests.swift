import Foundation
import Testing
@testable import Skluz

struct TunnelRunnerBackoffTests {

    @Test func backoffFollowsPlannedSchedule() {
        #expect(TunnelRunner.backoffDelay(forAttempt: 1) == 2)
        #expect(TunnelRunner.backoffDelay(forAttempt: 2) == 5)
        #expect(TunnelRunner.backoffDelay(forAttempt: 3) == 15)
        #expect(TunnelRunner.backoffDelay(forAttempt: 4) == 30)
        #expect(TunnelRunner.backoffDelay(forAttempt: 5) == 60)
    }

    @Test func backoffReturnsNilBeyondCap() {
        #expect(TunnelRunner.backoffDelay(forAttempt: 6) == nil)
        #expect(TunnelRunner.backoffDelay(forAttempt: 99) == nil)
    }

    @Test func backoffRejectsNonPositiveAttempt() {
        #expect(TunnelRunner.backoffDelay(forAttempt: 0) == nil)
        #expect(TunnelRunner.backoffDelay(forAttempt: -1) == nil)
    }

    @Test func backoffScheduleIsMonotonicAndCappedAtSixty() {
        let schedule = TunnelRunner.backoffSeconds
        #expect(schedule == schedule.sorted())
        #expect(schedule.max() == 60)
        #expect(schedule.count == 5)
    }
}
