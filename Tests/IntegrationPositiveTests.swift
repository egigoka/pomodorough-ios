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

    #if os(iOS)
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
    #endif

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

    @Test @MainActor
    func localOnlyHistoryAutomaticallyReplacesRemoteWithCompleteQueues() async throws {
        let scenario = "bootstrap-local-only"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try bootstrapState(hasLocalHistory: true)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let requests = TestFixtures.recordedRequests(for: scenario)
        let syncPaths = requests.filter { $0.path == "/api/v1/bootstrap" || $0.path == "/api/v1/bootstrap/resolve" || $0.path == "/api/v1/sync" }
        #expect(syncPaths.map { "\($0.method) \($0.path)" } == [
            "GET /api/v1/bootstrap",
            "POST /api/v1/bootstrap/resolve",
            "POST /api/v1/sync"
        ])
        let resolve = try #require(requests.first { $0.path == "/api/v1/bootstrap/resolve" })
        let body = try requestJSON(resolve)
        #expect(body["strategy"] as? String == "replace_remote")
        #expect(body["expectedRevision"] as? Int == 5)
        #expect((body["commands"] as? [Any])?.count == 2)
        #expect((body["taskOperations"] as? [Any])?.count == 1)
        #expect((body["durationOperations"] as? [Any])?.count == 1)
        #expect(model.history.map(\.id) == ["local-history"])
        #expect(model.pendingChangeCount == 0)
        #expect(model.historyResolutionState == .none)
        let persisted = try persistedState(defaults)
        #expect(persisted.cachedUser == TestFixtures.user)
        #expect(persisted.bootstrapUser == nil)
        #expect(persisted.pendingBootstrapResolution == nil)
    }

    @Test @MainActor
    func remoteOnlyHistoryAutomaticallyKeepsRemoteAndDiscardsLocalStateAfterSuccess() async throws {
        let scenario = "bootstrap-remote-only"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try bootstrapState(hasLocalHistory: false)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        let body = try requestJSON(resolve)
        #expect(body["strategy"] as? String == "keep_remote")
        #expect((body["commands"] as? [Any])?.isEmpty == true)
        #expect((body["taskOperations"] as? [Any])?.isEmpty == true)
        #expect((body["durationOperations"] as? [Any])?.isEmpty == true)
        #expect(model.history.map(\.id) == ["remote-history"])
        #expect(model.canonicalTimer == nil)
        #expect(model.pendingChangeCount == 0)
        #expect(try persistedState(defaults).cachedUser == TestFixtures.user)
    }

    @Test @MainActor
    func bothHistoriesBlockSyncAndMutationsUntilConfirmedAndCancelIsSideEffectFree() async throws {
        let scenario = "bootstrap-both-cancel"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try bootstrapState(hasLocalHistory: true)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .choosing)
        #expect(model.localHistoryResolutionCount == 1)
        #expect(model.remoteHistoryResolutionCount == 1)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/sync" && $0.path != "/api/v1/bootstrap/resolve"
        })
        await model.sync(force: true)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/sync" })
        let persistedBeforeChoice = try #require(defaults.data(forKey: "timer-state-v2"))
        let pendingBefore = model.pendingChangeCount
        model.start()
        model.setDurationMinutes(90, for: .focus)
        #expect(!model.addTask("Blocked task"))
        #expect(model.pendingChangeCount == pendingBefore)

        model.requestHistoryResolution(.keepRemote)
        #expect(model.historyResolutionState == .confirming(.keepRemote))
        #expect(try persistedState(defaults).pendingBootstrapResolution == nil)
        model.cancelHistoryResolutionConfirmation()

        #expect(model.historyResolutionState == .choosing)
        model.requestHistoryResolution(.replaceRemote)
        #expect(model.historyResolutionState == .confirming(.replaceRemote))
        model.cancelHistoryResolutionConfirmation()
        #expect(defaults.data(forKey: "timer-state-v2") == persistedBeforeChoice)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve"
        })
    }

    @Test @MainActor
    func chooserCountsOnlyCompletedHistoryEntries() async throws {
        let scenario = "bootstrap-history-counts"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var initial = try bootstrapState(hasLocalHistory: true)
        initial.history = [
            TestFixtures.history(
                id: "local-cancelled",
                status: "cancelled",
                durationMs: 60_000,
                date: TestFixtures.anchor
            ),
            TestFixtures.history(
                id: "local-superseded",
                status: "superseded",
                durationMs: 60_000,
                date: TestFixtures.anchor
            )
        ]
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .choosing)
        #expect(model.history.count == 3)
        #expect(model.localHistoryResolutionCount == 1)
        #expect(model.remoteHistoryResolutionCount == 1)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve" && $0.path != "/api/v1/sync"
        })
    }

    @Test @MainActor
    func keepBothRequiresConfirmationAndInstallsMergedCanonicalHistory() async throws {
        let scenario = "bootstrap-merge"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder.api.encode(bootstrapState(hasLocalHistory: true)), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()

        model.requestHistoryResolution(.merge)
        #expect(model.historyResolutionState == .confirming(.merge))
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve"
        })
        await model.confirmHistoryResolution()

        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        let body = try requestJSON(resolve)
        #expect(body["strategy"] as? String == "merge")
        #expect((body["commands"] as? [Any])?.count == 2)
        #expect(Set(model.history.map(\.id)) == ["local-history", "remote-history"])
        #expect(model.historyResolutionState == .none)
    }

    @Test @MainActor
    func transportFailurePreservesLocalDataAndRelaunchRetriesExactResolutionRequest() async throws {
        let scenario = "bootstrap-network-retry"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder.api.encode(bootstrapState(hasLocalHistory: true)), forKey: "timer-state-v2")

        do {
            let session = TestFixtures.session(for: scenario)
            defer { session.invalidateAndCancel() }
            let model = AppModel(
                api: APIClient(session: session, keychain: StaticTokenStore()),
                defaults: defaults,
                alarmScheduler: RecordingAlarmScheduler()
            )
            await model.restore()
            model.requestHistoryResolution(.merge)
            await model.confirmHistoryResolution()

            #expect(model.historyResolutionState == .retryable(.merge))
            #expect(model.history.map(\.id) == ["local-timer"])
            let pending = try #require(persistedState(defaults).pendingBootstrapResolution)
            #expect(pending.strategy == .merge)
        }

        let firstResolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        let secondSession = TestFixtures.session(for: scenario, resetsRecorder: false)
        defer { secondSession.invalidateAndCancel() }
        let restored = AppModel(
            api: APIClient(session: secondSession, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await restored.restore()

        let resolves = TestFixtures.recordedRequests(for: scenario).filter {
            $0.path == "/api/v1/bootstrap/resolve"
        }
        #expect(resolves.count == 2)
        #expect(resolves[0].body == resolves[1].body)
        #expect(resolves[0].body == firstResolve.body)
        #expect(TestFixtures.recordedRequests(for: scenario).count { $0.path == "/api/v1/bootstrap" } == 1)
        #expect(restored.historyResolutionState == .none)
        #expect(Set(restored.history.map(\.id)) == ["local-history", "remote-history"])
        #expect(try persistedState(defaults).pendingBootstrapResolution == nil)
    }

    @Test @MainActor
    func taskSyncEncodesOperationClearsAcknowledgementAndPullsRemoteTasks() async throws {
        let scenario = "task-sync"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        let operation = try taskOperation(title: "Local task")
        state.pendingTaskOperations = [operation]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let sync = try #require(TestFixtures.recordedRequests(for: scenario).first { $0.path == "/api/v1/sync" })
        let body = try requestJSON(sync)
        let taskOperations = try #require(body["taskOperations"] as? [[String: Any]])
        let encoded = try #require(taskOperations.first)
        #expect(Set(body.keys) == ["deviceId", "lastRevision", "commands", "taskOperations", "durationOperations"])
        #expect(encoded["id"] as? String == operation.id)
        #expect(encoded["taskId"] as? String == operation.taskId)
        #expect(encoded["type"] as? String == "upsert")
        #expect(encoded["title"] as? String == "Local task")
        #expect(model.pendingChangeCount == 0)
        #expect(model.tasks.map(\.title) == ["Remote task"])
        #expect(model.history.map(\.id) == ["remote-history"])
    }

    @Test(arguments: [BootstrapResolutionStrategy.keepRemote, .replaceRemote])
    @MainActor
    func chooserAppliesReplacementStrategyAfterConfirmation(
        _ strategy: BootstrapResolutionStrategy
    ) async throws {
        let scenario = "bootstrap-choice-\(strategy.rawValue)"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder.api.encode(bootstrapState(hasLocalHistory: true)),
            forKey: "timer-state-v2"
        )
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()
        #expect(model.historyResolutionState == .choosing)
        model.requestHistoryResolution(strategy)
        #expect(model.historyResolutionState == .confirming(strategy))
        await model.confirmHistoryResolution()

        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        let body = try requestJSON(resolve)
        let includesLocal = strategy == .replaceRemote
        #expect(body["strategy"] as? String == strategy.rawValue)
        #expect((body["commands"] as? [Any])?.count == (includesLocal ? 2 : 0))
        #expect((body["taskOperations"] as? [Any])?.count == (includesLocal ? 1 : 0))
        #expect((body["durationOperations"] as? [Any])?.count == (includesLocal ? 1 : 0))
        #expect(model.history.map(\.id) == [includesLocal ? "local-history" : "remote-history"])
        #expect(model.pendingChangeCount == 0)
        #expect(model.historyResolutionState == .none)
    }

    @Test @MainActor
    func taskDeleteSyncEncodesWireContractAndClearsAcknowledgement() async throws {
        let scenario = "task-sync-delete-wire"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = try #require(FocusTask(title: "Delete remotely"))
        let operation = TaskOperation(
            id: "task-operation-delete-wire",
            taskId: task.id.uuidString.lowercased(),
            type: .delete,
            title: nil,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 2,
            hlcCounter: 0
        )
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.tasks = [task]
        state.knownTasks = [task]
        state.pendingTaskOperations = [operation]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let sync = try #require(TestFixtures.recordedRequests(for: scenario).first { $0.path == "/api/v1/sync" })
        let taskOperations = try #require(try requestJSON(sync)["taskOperations"] as? [[String: Any]])
        let encoded = try #require(taskOperations.first)
        #expect(taskOperations.count == 1)
        #expect(encoded["id"] as? String == operation.id)
        #expect(encoded["taskId"] as? String == operation.taskId)
        #expect(encoded["type"] as? String == "delete")
        #expect(encoded["title"] == nil)
        #expect(model.tasks.isEmpty)
        #expect(model.pendingChangeCount == 0)
        #expect(try persistedState(defaults).pendingTaskOperations.isEmpty)
    }

    @Test @MainActor
    func remoteTaskPullThenDeletionClearsSelectedTask() async throws {
        let scenario = "task-sync-remote-lifecycle"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()
        let remoteTask = try #require(model.tasks.first)
        #expect(model.tasks.map(\.title) == ["Remote task"])
        model.selectedTaskID = remoteTask.id
        #expect(model.selectedTaskID == remoteTask.id)

        await model.sync(force: true)

        #expect(model.tasks.isEmpty)
        #expect(model.selectedTaskID == nil)
        #expect(try persistedState(defaults).selectedTaskID == nil)
    }

    @Test @MainActor
    func taskAddedDuringSyncRebasesOntoRemoteResponseAndClearsOnFollowUp() async throws {
        let scenario = "task-sync-in-flight-rebase"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        let restoreTask = Task { await model.restore() }
        for _ in 0..<100 {
            if TestFixtures.recordedRequests(for: scenario).contains(where: { $0.path == "/api/v1/sync" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(TestFixtures.recordedRequests(for: scenario).contains { $0.path == "/api/v1/sync" })
        #expect(model.addTask("Added in flight"))

        await restoreTask.value

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let operationCounts = try syncs.map { request in
            try #require(try requestJSON(request)["taskOperations"] as? [Any]).count
        }
        #expect(operationCounts.first == 0)
        #expect(operationCounts.count { $0 == 1 } == 1)
        #expect(Set(model.tasks.map(\.title)) == ["Remote task", "Added in flight"])
        #expect(model.pendingChangeCount == 0)
    }

    @Test @MainActor
    func taskSyncBatchesMoreThan256OperationsWithoutDroppingTasks() async throws {
        let scenario = "task-sync-batching"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tasks = try (0..<257).map { index in
            try #require(FocusTask(title: "Batch task \(index)"))
        }
        let operations = tasks.enumerated().map { index, task in
            TaskOperation(
                id: "task-operation-batch-\(index)",
                taskId: task.id.uuidString.lowercased(),
                type: .upsert,
                title: task.title,
                occurredAt: TestFixtures.anchor,
                hlcWallMs: Int64(index + 1),
                hlcCounter: 0
            )
        }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.knownTasks = tasks
        state.pendingTaskOperations = operations
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let operationCounts = try syncs.map { request in
            try #require(try requestJSON(request)["taskOperations"] as? [Any]).count
        }
        #expect(operationCounts == [256, 1])
        #expect(model.tasks.count == 257)
        #expect(Set(model.tasks) == Set(tasks))
        #expect(model.pendingChangeCount == 0)
    }

    @Test @MainActor
    func remoteTimerAndHistoryResolveTheirAssociatedTask() async throws {
        let scenario = "task-sync-associations"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let task = try #require(model.tasks.first)
        let timer = try #require(model.canonicalTimer)
        let history = try #require(model.history.first)
        let historyDate = try #require(history.date)
        #expect(model.task(forTimerID: timer.id) == task)
        #expect(model.task(forTimerID: history.timerId) == task)
        let summary = try #require(model.taskSummaries(for: historyDate).first)
        #expect(summary.task == task)
        #expect(summary.finishedPomodoros == 1)
        #expect(summary.timeSpentMs == 1_500_000)
    }

    @Test @MainActor
    func differentEstablishedOwnerNeverOffersPreviousAccountHistory() async throws {
        let scenario = "task-sync-different-owner"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = User(id: "different-user", email: "old@example.com", name: "Old", avatarUrl: "")
        state.history = [TestFixtures.history(
            id: "old-account-history",
            durationMs: 25 * 60_000,
            date: TestFixtures.anchor
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.sessionState == .signedIn(TestFixtures.user))
        #expect(model.historyResolutionState == .none)
        #expect(model.history.map(\.id) == ["remote-history"])
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/bootstrap" })
    }

    @Test @MainActor
    func emptyHistoriesMergeLocalQueuesAndOtherwiseKeepRemote() async throws {
        for (scenario, state, expectedStrategy) in [
            ("bootstrap-empty-merge", try bootstrapState(hasLocalHistory: false), "merge"),
            ("bootstrap-empty-keep", emptyBootstrapState(), "keep_remote")
        ] {
            let suiteName = "PomodoroughTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
            let session = TestFixtures.session(for: scenario)
            defer { session.invalidateAndCancel() }
            let model = AppModel(
                api: APIClient(session: session, keychain: StaticTokenStore()),
                defaults: defaults,
                alarmScheduler: RecordingAlarmScheduler()
            )

            await model.restore()

            let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
                $0.path == "/api/v1/bootstrap/resolve"
            })
            #expect(try requestJSON(resolve)["strategy"] as? String == expectedStrategy)
            #expect(model.history.isEmpty)
            #expect(model.historyResolutionState == .none)
        }
    }

    private func bootstrapState(hasLocalHistory: Bool) throws -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        state.pendingCommands = hasLocalHistory
            ? [
                TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "local-timer"),
                TestFixtures.command(.finish, sequence: 2, elapsed: 60_000, timerID: "local-timer")
            ]
            : [TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "local-timer")]
        state.pendingTaskOperations = [try taskOperation(title: "Local task")]
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-bootstrap",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 3
        )]
        return state
    }

    private func emptyBootstrapState() -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        return state
    }

    private func taskOperation(title: String) throws -> TaskOperation {
        let task = try #require(FocusTask(title: title))
        return TaskOperation(
            id: "task-operation-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 2,
            hlcCounter: 0
        )
    }

    private func persistedState(_ defaults: UserDefaults) throws -> PersistedTimerState {
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
    }

    private func requestJSON(_ request: RecordedRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
