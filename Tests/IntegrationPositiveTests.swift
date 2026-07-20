import Foundation
import Testing
@testable import Pomodorough

@Suite("Integration Positive")
struct IntegrationPositiveTests {
    @Test @MainActor
    func optimisticTimerWorkflowSurvivesPersistenceRoundTrip() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        model.setDurationMinutes(1, for: .focus)
        model.start()
        let started = try #require(model.canonicalTimer)
        model.pause(at: started.anchorAt.addingTimeInterval(10))

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let paused = try #require(restored.canonicalTimer)
        #expect(paused.status == .paused)
        #expect(paused.elapsedAtAnchorMs == 10_000)
        #expect(restored.pendingCommandCount == 2)

        restored.resume(at: paused.anchorAt.addingTimeInterval(5))
        let resumed = try #require(restored.canonicalTimer)
        restored.finish(at: resumed.anchorAt.addingTimeInterval(20))

        let finalModel = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(finalModel.canonicalTimer?.status == .completed)
        #expect(finalModel.canonicalTimer?.elapsedAtAnchorMs == 60_000)
        #expect(finalModel.history.count == 1)
        #expect(finalModel.pendingCommandCount == 4)
    }

    @Test @MainActor
    func idleConfigurationSurvivesPersistenceRoundTrip() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        model.selectedPhase = .longBreak
        model.setDurationMinutes(45, for: .longBreak)
        model.autoStartBreaks = true

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(restored.selectedPhase == .longBreak)
        #expect(restored.durationMinutes(for: .longBreak) == 45)
        #expect(restored.autoStartBreaks)
    }

    @Test @MainActor
    func completedFocusAutomaticallyStartsShortBreak() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.autoStartBreaks = true
        model.start()
        let focus = try #require(model.canonicalTimer)

        model.finish(at: focus.anchorAt.addingTimeInterval(60))

        #expect(model.canonicalTimer?.status == .running)
        #expect(model.canonicalTimer?.phase == .shortBreak)
        #expect(model.selectedPhase == .shortBreak)
        #expect(model.completedFocusCount == 1)
        #expect(model.pendingCommandCount == 3)
    }

    @Test @MainActor
    func completedTimerIsQueuedOnlyOnce() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.start()
        let timer = try #require(model.canonicalTimer)

        model.completeIfNeeded(timerID: "timer-other", at: timer.anchorAt.addingTimeInterval(60))
        model.completeIfNeeded(timerID: timer.id, at: timer.anchorAt.addingTimeInterval(59))
        #expect(model.pendingCommandCount == 1)

        model.completeIfNeeded(timerID: timer.id, at: timer.anchorAt.addingTimeInterval(60))
        model.completeIfNeeded(timerID: timer.id, at: timer.anchorAt.addingTimeInterval(61))

        #expect(model.canonicalTimer?.status == .completed)
        #expect(model.history.count == 1)
        #expect(model.pendingCommandCount == 2)
    }

    @Test @MainActor
    func cancelledTimerCanBeClearedAcrossPersistenceRoundTrip() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.start()
        let timer = try #require(model.canonicalTimer)

        model.cancel(at: timer.anchorAt.addingTimeInterval(10))
        #expect(model.canonicalTimer?.status == .cancelled)
        model.clear()

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(restored.canonicalTimer == nil)
        #expect(restored.history.count == 1)
        #expect(restored.history.first?.status == "cancelled")
        #expect(restored.pendingCommandCount == 3)
    }

    @Test func apiClientBuildsAndDecodesChallengeRequest() async throws {
        let session = TestFixtures.session(for: "challenge-success")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        let challenge = try await client.challenge()

        #expect(challenge.challenge == "challenge-123")
        #expect(challenge.nonce == "nonce-456")
        #expect(challenge.expiresAt == Date(timeIntervalSince1970: 1_784_550_896.789))
    }

    @Test @MainActor
    func timerControlsUpdateSystemAlarmInOrder() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)
        model.setDurationMinutes(1, for: .focus)

        model.start()
        await model.waitForAlarmOperations()
        let running = try #require(model.canonicalTimer)
        model.pause(at: running.anchorAt.addingTimeInterval(10))
        await model.waitForAlarmOperations()
        let paused = try #require(model.canonicalTimer)
        model.resume(at: paused.anchorAt.addingTimeInterval(5))
        await model.waitForAlarmOperations()
        let resumed = try #require(model.canonicalTimer)
        model.finish(at: resumed.anchorAt.addingTimeInterval(10))
        await model.waitForAlarmOperations()

        #expect(scheduler.operations == [
            .schedule(timerID: running.id, phase: .focus, duration: 60),
            .pause(timerID: running.id),
            .resume(timerID: running.id),
            .cancel(timerID: running.id)
        ])
    }

    @Test @MainActor
    func naturalCompletionKeepsAlarmAudibleAndSchedulesAutomaticBreak() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)
        model.setDurationMinutes(1, for: .focus)
        model.setDurationMinutes(1, for: .shortBreak)
        model.autoStartBreaks = true
        model.start()
        await model.waitForAlarmOperations()
        let focus = try #require(model.canonicalTimer)

        model.completeIfNeeded(timerID: focus.id, at: focus.anchorAt.addingTimeInterval(60))
        await model.waitForAlarmOperations()

        let shortBreak = try #require(model.canonicalTimer)
        #expect(shortBreak.phase == .shortBreak)
        #expect(scheduler.operations == [
            .schedule(timerID: focus.id, phase: .focus, duration: 60),
            .schedule(timerID: shortBreak.id, phase: .shortBreak, duration: 60)
        ])
    }

    @Test func apiClientAcceptsStandardRFC3339Date() async throws {
        let session = TestFixtures.session(for: "standard-date")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        let challenge = try await client.challenge()

        #expect(challenge.expiresAt == Date(timeIntervalSince1970: 1_784_550_896))
    }

    @Test func persistedStateBackfillsNewSettingsAndClockFields() throws {
        let json = Data(
            #"{"deviceId":"device-test0001","nextSequence":1,"revision":0,"pendingCommands":[],"canonicalTimer":null,"history":[]}"#.utf8
        )

        let state = try JSONDecoder.api.decode(PersistedTimerState.self, from: json)

        #expect(state.settings.focusMinutes == 25)
        #expect(state.hlcWallMs == 0)
        #expect(state.cachedUser == nil)
    }
}
