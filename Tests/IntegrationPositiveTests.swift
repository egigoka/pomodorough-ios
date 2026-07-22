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
    func durationEditsClampCompactPersistAndIgnoreNoOps() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        model.setDurationMinutes(25, for: .focus)
        #expect(defaults.data(forKey: "timer-state-v2") == nil)

        model.setDurationMinutes(1, for: .focus)
        let firstData = try #require(defaults.data(forKey: "timer-state-v2"))
        let firstState = try JSONDecoder.api.decode(PersistedTimerState.self, from: firstData)
        let firstOperation = try #require(firstState.pendingDurationOperations.first)
        model.setDurationMinutes(0, for: .focus)
        #expect(defaults.data(forKey: "timer-state-v2") == firstData)

        model.setDurationMinutes(999, for: .focus)
        model.setDurationMinutes(10, for: .shortBreak)
        let finalData = try #require(defaults.data(forKey: "timer-state-v2"))
        let finalState = try JSONDecoder.api.decode(PersistedTimerState.self, from: finalData)
        let focusOperation = try #require(finalState.pendingDurationOperations.first { $0.phase == .focus })

        #expect(finalState.pendingDurationOperations.count == 2)
        #expect(focusOperation.id != firstOperation.id)
        #expect((focusOperation.hlcWallMs, focusOperation.hlcCounter) > (firstOperation.hlcWallMs, firstOperation.hlcCounter))
        #expect(focusOperation.hlcWallMs > 0)
        #expect(focusOperation.durationMs == 180 * 60_000)
        #expect(model.durationMinutes(for: .focus) == 180)
        #expect(model.pendingDurationOperationCount == 2)

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(restored.durationMinutes(for: .focus) == 180)
        #expect(restored.durationMinutes(for: .shortBreak) == 10)
        #expect(restored.pendingDurationOperationCount == 2)
    }

    @Test @MainActor
    func legacyDurationMigrationQueuesOnlyNonDefaultPhasesOnce() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let json = Data(
            #"{"deviceId":"device-legacy","nextSequence":1,"revision":0,"pendingCommands":[],"pendingTaskOperations":[],"canonicalTimer":null,"history":[],"settings":{"selectedPhase":"long_break","focusMinutes":25,"shortBreakMinutes":7,"longBreakMinutes":30,"autoStartBreaks":true}}"#.utf8
        )
        defaults.set(json, forKey: "timer-state-v2")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let migratedData = try #require(defaults.data(forKey: "timer-state-v2"))
        let migrated = try JSONDecoder.api.decode(PersistedTimerState.self, from: migratedData)

        #expect(Set(migrated.pendingDurationOperations.map(\.phase)) == [.shortBreak, .longBreak])
        #expect(migrated.pendingDurationOperations.first { $0.phase == .shortBreak }?.durationMs == Int64(7 * 60_000))
        #expect(migrated.pendingDurationOperations.first { $0.phase == .longBreak }?.durationMs == Int64(30 * 60_000))
        #expect(migrated.pendingDurationOperations.allSatisfy {
            $0.hlcWallMs == 0 && $0.hlcCounter == 0 && $0.isValid
        })
        #expect(model.selectedPhase == .longBreak)
        #expect(model.autoStartBreaks)

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(restored.pendingDurationOperationCount == 2)
    }

    @Test @MainActor
    func signedInPullAppliesCanonicalDurationsWithoutSyncingLocalOnlySettings() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.settings.selectedPhase = .longBreak
        state.settings.autoStartBreaks = true
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: "duration-sync")
        defer { session.invalidateAndCancel() }
        let api = APIClient(session: session, keychain: StaticTokenStore())
        let model = AppModel(api: api, defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        await model.restore()

        #expect(model.sessionState == .signedIn(TestFixtures.user))
        #expect(model.durationMinutes(for: .focus) == 40)
        #expect(model.durationMinutes(for: .shortBreak) == 6)
        #expect(model.durationMinutes(for: .longBreak) == 20)
        #expect(model.selectedPhase == .longBreak)
        #expect(model.autoStartBreaks)
        #expect(model.pendingDurationOperationCount == 0)
    }

    @Test @MainActor
    func changingDurationClearsInactiveTimerAndUpdatesNextRun() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.start()
        let timer = try #require(model.canonicalTimer)
        model.cancel(at: timer.anchorAt.addingTimeInterval(10))

        model.setDurationMinutes(15, for: .focus)

        #expect(model.canonicalTimer == nil)
        #expect(model.durationMinutes(for: .focus) == 15)
        model.start()
        let nextTimer = try #require(model.canonicalTimer)
        #expect(nextTimer.plannedDurationMs == Int64(15 * 60_000))
    }

    @Test @MainActor
    func inactivePersistedTimerDoesNotOverrideConfiguredDuration() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.settings.setMinutes(15, for: .focus)
        state.canonicalTimer = CanonicalTimer(
            id: "timer-stale",
            taskId: nil,
            phase: .focus,
            status: .completed,
            plannedDurationMs: 25 * 60_000,
            elapsedAtAnchorMs: 25 * 60_000,
            anchorAt: TestFixtures.anchor,
            lastIntent: nil
        )
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let staleTimer = try #require(model.canonicalTimer)

        #expect(staleTimer.plannedDurationMs == Int64(25 * 60_000))
        #expect(model.activeTimer == nil)
        #expect(model.durationMinutes(for: .focus) == 15)
    }

    @Test @MainActor
    func localTaskAssignmentSurvivesDeletionPersistenceAndRecreation() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        #expect(model.addTask("\tWrite release notes\n"))
        #expect(model.addTask("Write release notes"))
        let task = try #require(model.tasks.first)
        #expect(model.tasks.count == 1)
        model.selectedTaskID = task.id
        model.setDurationMinutes(1, for: .focus)
        model.start()
        let timer = try #require(model.canonicalTimer)
        #expect(model.task(forTimerID: timer.id) == task)
        model.finish(at: timer.anchorAt.addingTimeInterval(60))

        model.deleteTask(id: task.id)
        #expect(model.tasks.isEmpty)
        #expect(model.taskSummaries().isEmpty)
        #expect(model.addTask("Write release notes"))

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let recreated = try #require(restored.tasks.first)
        let summary = try #require(restored.taskSummaries().first)
        #expect(recreated.id == task.id)
        #expect(restored.task(forTimerID: timer.id) == task)
        #expect(summary.finishedPomodoros == 1)
        #expect(summary.timeSpentMs == 60_000)
    }

    @Test @MainActor
    func taskSummariesCountOnlyCompletedFocusPomodorosFromRequestedDay() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 21, hour: 12)))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let writing = try #require(FocusTask(title: "Writing"))
        let review = try #require(FocusTask(title: "Review"))
        var timerState = PersistedTimerState.fresh()
        timerState.history = [
            TestFixtures.history(id: "write-25", durationMs: 25 * 60_000, date: today),
            TestFixtures.history(id: "write-10", durationMs: 10 * 60_000, date: today.addingTimeInterval(60)),
            TestFixtures.history(id: "review-50", durationMs: 50 * 60_000, date: today),
            TestFixtures.history(id: "write-cancelled", status: "cancelled", durationMs: 90 * 60_000, date: today),
            TestFixtures.history(id: "write-break", phase: .shortBreak, durationMs: 5 * 60_000, date: today),
            TestFixtures.history(id: "write-yesterday", durationMs: 40 * 60_000, date: yesterday)
        ]
        let assignments = Dictionary(
            uniqueKeysWithValues: timerState.history.map { item in
                (item.timerId, item.timerId == "review-50" ? review : writing)
            }
        )
        let localTasks = LocalTaskState(
            tasks: [writing, review],
            selectedTaskID: writing.id,
            assignments: assignments
        )
        defaults.set(try JSONEncoder.api.encode(timerState), forKey: "timer-state-v2")
        defaults.set(try JSONEncoder.api.encode(localTasks), forKey: "local-tasks-v1")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let summaries = model.taskSummaries(for: today, calendar: calendar)
        let migratedData = try #require(defaults.data(forKey: "timer-state-v2"))
        let migratedState = try JSONDecoder.api.decode(PersistedTimerState.self, from: migratedData)

        #expect(summaries == [
            TaskDailySummary(task: writing, finishedPomodoros: 2, timeSpentMs: 35 * 60_000),
            TaskDailySummary(task: review, finishedPomodoros: 1, timeSpentMs: 50 * 60_000)
        ])
        #expect(defaults.data(forKey: "local-tasks-v1") == nil)
        #expect(Set(migratedState.pendingTaskOperations.map(\.taskId)) == Set([writing, review].map { $0.id.uuidString.lowercased() }))
        #expect(migratedState.legacyTaskAssignments.count == timerState.history.count)
        #expect(migratedState.history.allSatisfy { $0.taskId != nil })
    }

    @Test @MainActor
    func localTimerSurvivesOfflineLaunchWithoutCredentials() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = APIClient(keychain: EmptyTokenStore())
        let model = AppModel(api: api, defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.start()

        let restored = AppModel(api: api, defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        await restored.restore()

        #expect(restored.sessionState == .localOnly)
        #expect(restored.canonicalTimer?.status == .running)
        #expect(restored.pendingCommandCount == 1)
        #expect(restored.syncLabel == "On device")
    }

    @Test @MainActor
    func permissionIntroductionRequestsAccessOnceAndPersistsCompletion() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)

        #expect(model.needsPermissionIntroduction)
        await model.allowTimerAlerts()

        #expect(!model.needsPermissionIntroduction)
        #expect(scheduler.operations == [.requestAuthorization])
        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(!restored.needsPermissionIntroduction)
    }

    @Test @MainActor
    func permissionIntroductionCanBeSkippedWithoutRequestingAccess() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)

        model.skipTimerAlertPermissions()

        #expect(!model.needsPermissionIntroduction)
        #expect(scheduler.operations.isEmpty)
        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(!restored.needsPermissionIntroduction)
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
            .resume(timerID: running.id, phase: .focus, duration: 50),
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
        #expect(state.pendingTaskOperations.isEmpty)
        #expect(state.pendingDurationOperations.isEmpty)
        #expect(state.tasks.isEmpty)
        #expect(state.knownTasks.isEmpty)
        #expect(state.selectedTaskID == nil)
        #expect(state.legacyTaskAssignments.isEmpty)
    }
}
