import Foundation
import Testing
@testable import Pomodorough

@Suite("Unit Positive")
struct UnitPositiveTests {
    @Test func timerAlarmIdentityUsesTimerUUID() throws {
        let uuid = try #require(UUID(uuidString: "83A06D73-1D2D-441E-AFC2-E36DA0518613"))

        #expect(TimerAlarmScheduler.alarmID(for: "timer-\(uuid.uuidString.lowercased())") == uuid)
    }

    @Test func runningTimerClampsAtPlannedDuration() {
        let timer = TestFixtures.timer(status: .running, elapsed: 50_000)

        #expect(timer.elapsed(at: TestFixtures.anchor.addingTimeInterval(20)) == 60)
        #expect(timer.remaining(at: TestFixtures.anchor.addingTimeInterval(20)) == 0)
    }

    @Test func pausedTimerDoesNotAdvance() {
        let timer = TestFixtures.timer(status: .paused, elapsed: 15_000)

        #expect(timer.elapsed(at: TestFixtures.anchor.addingTimeInterval(20)) == 15)
    }

    @Test func runningTimerDoesNotRunBackwardBeforeAnchor() {
        let timer = TestFixtures.timer(status: .running, elapsed: 15_000)

        #expect(timer.elapsed(at: TestFixtures.anchor.addingTimeInterval(-20)) == 15)
        #expect(timer.remaining(at: TestFixtures.anchor.addingTimeInterval(-20)) == 45)
    }

    @Test func timerPhasesExposeExpectedPresentationAndDefaults() {
        #expect(TimerPhase.allCases.map(\.id) == ["focus", "short_break", "long_break"])
        #expect(TimerPhase.allCases.map(\.title) == ["Focus", "Short break", "Long break"])
        #expect(TimerPhase.allCases.map(\.routeLabel) == ["Work", "Reset", "Recover"])
        #expect(TimerPhase.allCases.map(\.abbreviation) == ["F", "SB", "LB"])
        #expect(TimerPhase.allCases.map(\.defaultMinutes) == [25, 5, 15])
    }

    @Test func historyUsesBestDateAndRoundsMinutesUp() {
        let completed = HistoryItem(
            id: "history-completed",
            timerId: "timer-completed",
            commandId: "command-completed",
            phase: .focus,
            status: "completed",
            plannedDurationMs: 60_001,
            completedAt: TestFixtures.anchor,
            endedAt: TestFixtures.anchor.addingTimeInterval(10)
        )
        let cancelled = HistoryItem(
            id: "history-cancelled",
            timerId: "timer-cancelled",
            commandId: "command-cancelled",
            phase: .shortBreak,
            status: "cancelled",
            plannedDurationMs: 0,
            completedAt: nil,
            endedAt: TestFixtures.anchor
        )

        #expect(completed.date == TestFixtures.anchor)
        #expect(completed.minutes == 2)
        #expect(cancelled.date == TestFixtures.anchor)
        #expect(cancelled.minutes == 1)
    }

    @Test func reducerAppliesCommandsInDeviceSequenceOrder() {
        let start = TestFixtures.command(.start, sequence: 1, elapsed: 0)
        let pause = TestFixtures.command(.pause, sequence: 2, elapsed: 12_000)
        let finish = TestFixtures.command(.finish, sequence: 3, elapsed: 12_000)

        let result = TimerReducer.applying([finish, start, pause], to: nil, history: [])

        #expect(result.timer?.status == .completed)
        #expect(result.timer?.elapsedAtAnchorMs == 60_000)
        #expect(result.history.count == 1)
        #expect(result.history.first?.status == "completed")
    }

    @Test func accountChangeKeepsDevicePreferences() {
        var state = PersistedTimerState.fresh()
        let deviceID = state.deviceId
        state.settings.focusMinutes = 42
        state.cachedUser = User(id: String(repeating: "a", count: 32), email: "a@example.com", name: "A", avatarUrl: "")
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        state.canonicalTimer = TestFixtures.timer(status: .running, elapsed: 0)
        let newUser = User(id: String(repeating: "b", count: 32), email: "b@example.com", name: "B", avatarUrl: "")

        state.prepare(for: newUser)

        #expect(state.deviceId == deviceID)
        #expect(state.settings.focusMinutes == 42)
        #expect(state.cachedUser == newUser)
        #expect(state.pendingCommands.isEmpty)
        #expect(state.canonicalTimer == nil)
    }

    @Test func sameAccountRetainsLocalAccountData() {
        var state = PersistedTimerState.fresh()
        let user = User(id: "user-a", email: "a@example.com", name: "A", avatarUrl: "")
        state.cachedUser = user
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        state.canonicalTimer = TestFixtures.timer(status: .running, elapsed: 0)
        let original = state

        state.discardUnownedAccountData()
        state.prepare(for: user)

        #expect(state == original)
    }

    @Test func cancelAddsOptimisticHistory() {
        let running = TestFixtures.timer(status: .running, elapsed: 5_000)
        let cancel = TestFixtures.command(.cancel, sequence: 2, elapsed: 5_000)

        let result = TimerReducer.apply(cancel, to: running, history: [])

        #expect(result.0?.status == .cancelled)
        #expect(result.1.count == 1)
        #expect(result.1.first?.status == "cancelled")
        #expect(result.1.first?.endedAt == cancel.occurredAt)
    }

    @Test func clearRemovesInactiveTimerWithoutChangingHistory() {
        let completed = TestFixtures.timer(status: .completed, elapsed: 60_000)
        let clear = TestFixtures.command(.clear, sequence: 2, elapsed: 60_000)
        let history = [HistoryItem(
            id: "history-test0001",
            timerId: completed.id,
            commandId: "command-finish",
            phase: .focus,
            status: "completed",
            plannedDurationMs: 60_000,
            completedAt: TestFixtures.anchor,
            endedAt: nil
        )]

        let result = TimerReducer.apply(clear, to: completed, history: history)

        #expect(result.0 == nil)
        #expect(result.1 == history)
    }

    @Test func reducerClampsObservedElapsedAtBothBounds() throws {
        let running = TestFixtures.timer(status: .running, elapsed: 5_000)
        let pause = TestFixtures.command(.pause, sequence: 2, elapsed: -1_000)
        let paused = try #require(TimerReducer.apply(pause, to: running, history: []).0)
        let resume = TestFixtures.command(.resume, sequence: 3, elapsed: 120_000)
        let resumed = try #require(TimerReducer.apply(resume, to: paused, history: []).0)

        #expect(paused.status == .paused)
        #expect(paused.elapsedAtAnchorMs == 0)
        #expect(resumed.status == .running)
        #expect(resumed.elapsedAtAnchorMs == 60_000)
    }

    @Test func longBreakFollowsEveryFourthCompletedFocus() {
        #expect(TimerReducer.breakPhase(afterCompletedFocusCount: 3) == .shortBreak)
        #expect(TimerReducer.breakPhase(afterCompletedFocusCount: 4) == .longBreak)
        #expect(TimerReducer.breakPhase(afterCompletedFocusCount: 8) == .longBreak)
    }

    @Test func parserEmitsNamedJSONAndPlainRevisionEvents() {
        var parser = SSERevisionParser()

        #expect(parser.consume(line: "event: revision") == nil)
        #expect(parser.consume(line: "data: {\"revision\":42}") == nil)
        #expect(parser.consume(line: "") == 42)
        #expect(parser.consume(line: "data: 17") == nil)
        #expect(parser.consume(line: "") == 17)
    }

    @Test func parserCombinesMultilineEventData() {
        var parser = SSERevisionParser()

        #expect(parser.consume(line: "data: {\"revision\":") == nil)
        #expect(parser.consume(line: "data: 42}") == nil)
        #expect(parser.consume(line: "") == 42)
    }

    @Test func revisionHintDuringSyncIsCoalescedForFollowUp() {
        var hints = RevisionHintCoalescer()

        #expect(hints.receive(12, localRevision: 10, isSyncing: true) == false)
        #expect(hints.consumeFollowUp(localRevision: 10) == true)
        #expect(hints.consumeFollowUp(localRevision: 12) == false)
    }

    @Test func activeStreamLifecycleOwnsCurrentTask() throws {
        var lifecycle = RevisionStreamLifecycle()
        lifecycle.setActive(true)

        let startedStreamID = lifecycle.begin()
        let streamID = try #require(startedStreamID)

        #expect(lifecycle.owns(streamID))
        lifecycle.end(streamID)
        #expect(lifecycle.begin() != nil)
    }

    @Test func activeStreamLifecyclePreventsConcurrentStreams() throws {
        var lifecycle = RevisionStreamLifecycle()
        lifecycle.setActive(true)
        let startedStreamID = lifecycle.begin()
        let streamID = try #require(startedStreamID)

        #expect(lifecycle.begin() == nil)
        lifecycle.end(UUID())
        #expect(lifecycle.owns(streamID))
        lifecycle.cancelCurrent()
        #expect(!lifecycle.owns(streamID))
        #expect(lifecycle.begin() != nil)
    }

    @Test func syncOwnershipRequestsFollowUpForNewerGeneration() throws {
        var ownership = SyncOwnership()
        let startedOwner = ownership.begin(generation: 1)
        let owner = try #require(startedOwner)

        #expect(ownership.begin(generation: 2) == nil)
        #expect(ownership.finish(owner, currentGeneration: 2) == true)
    }

    @Test func verifiedSessionAllowsMatchingGeneration() {
        var verification = SessionVerification()

        verification.markVerified(generation: 7)

        #expect(verification.allows(generation: 7))
    }

    @Test func appErrorsProvideActionableDescriptions() {
        #expect(AppError.configuration.errorDescription == "Google Sign-In is not configured for this build.")
        #expect(AppError.missingPresentationAnchor.errorDescription == "No window is available for Google Sign-In.")
        #expect(AppError.missingIDToken.errorDescription == "Google did not return an identity token.")
        #expect(AppError.unauthorized.errorDescription == "Session expired. Sign in again.")
        #expect(AppError.server("Try later.").errorDescription == "Try later.")
        #expect(AppError.invalidResponse.errorDescription == "Server returned an invalid response.")
    }

    @Test func validStreamResponseAcceptsSSEMediaTypeParameters() {
        #expect(RevisionStreamResponse.isValid(statusCode: 200, contentType: "text/event-stream; charset=utf-8"))
    }

    @Test func foregroundPollingIsFasterForActiveTimers() {
        #expect(RemotePolling.interval(isTimerActive: true) == 2)
        #expect(RemotePolling.interval(isTimerActive: false) == 5)
    }
}
