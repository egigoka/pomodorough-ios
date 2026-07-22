#if os(macOS)
import Testing
@testable import Pomodorough

@Suite("macOS")
@MainActor
struct MacOSTests {
    @Test func alarmSchedulerOperationsAreSafeWithoutAlarmKit() async throws {
        let scheduler = TimerAlarmScheduler()
        let timerID = "timer-83a06d73-1d2d-441e-afc2-e36da0518613"

        try await scheduler.requestAuthorization()
        try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 60)
        try scheduler.pause(timerID: timerID)
        try await scheduler.resume(timerID: timerID, phase: .focus, duration: 30)
        try scheduler.cancel(timerID: timerID)
    }
}
#endif
