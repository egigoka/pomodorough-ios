import Foundation
import Testing
@testable import Pomodorough

@Suite("Integration Negative")
struct IntegrationNegativeTests {
    @Test @MainActor
    func activeTimerKeepsCapturedDurationWhenFuturePreferenceChanges() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.start()
        let timer = try #require(model.canonicalTimer)

        model.selectedPhase = .longBreak
        model.setDurationMinutes(90, for: .focus)
        model.resume(at: timer.anchorAt.addingTimeInterval(5))
        model.clear()

        #expect(model.selectedPhase == .focus)
        #expect(model.durationMinutes(for: .focus) == 90)
        #expect(model.canonicalTimer == timer)
        #expect(model.canonicalTimer?.plannedDurationMs == Int64(25 * 60_000))
        #expect(model.pendingCommandCount == 2)
        #expect(model.pendingDurationOperationCount == 1)
    }

    @Test @MainActor
    func activeTimerKeepsItsTaskWhenFutureSelectionChanges() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(model.addTask("Build"))
        #expect(model.addTask("Review"))
        let build = try #require(model.tasks.first)
        let review = try #require(model.tasks.last)
        model.selectedTaskID = build.id
        model.start()
        let timer = try #require(model.canonicalTimer)

        model.selectedTaskID = review.id

        #expect(model.selectedTaskID == build.id)
        #expect(model.task(forTimerID: timer.id) == build)
    }

    @Test @MainActor
    func corruptedPersistedStateFallsBackToFreshState() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "timer-state-v2")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        #expect(model.canonicalTimer == nil)
        #expect(model.history.isEmpty)
        #expect(model.pendingCommandCount == 0)
        #expect(model.durationMinutes(for: .focus) == 25)
    }

    @Test @MainActor
    func invalidDurationAcknowledgementKeepsQueueAndPausesAutomaticSync() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.settings.setMinutes(30, for: .focus)
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-pending",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 1
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: "duration-invalid-ack")
        defer { session.invalidateAndCancel() }
        let api = APIClient(session: session, keychain: StaticTokenStore())
        let model = AppModel(api: api, defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        await model.restore()

        #expect(model.pendingDurationOperationCount == 1)
        #expect(model.durationMinutes(for: .focus) == 30)
        #expect(model.errorMessage?.contains("Sync paused") == true)
        #expect(model.errorMessage?.contains("1 queued changes remain") == true)
        #expect(!model.isOffline)
    }

    @Test @MainActor
    func timerActionsWithoutTimerAreNoOps() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        model.pause()
        model.resume()
        model.finish()
        model.cancel()
        model.clear()

        #expect(model.canonicalTimer == nil)
        #expect(model.history.isEmpty)
        #expect(model.pendingCommandCount == 0)
    }

    @Test func apiClientMapsServerErrorResponse() async {
        let session = TestFixtures.session(for: "server-error")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        do {
            _ = try await client.challenge()
            Issue.record("Expected server error")
        } catch AppError.server(let message) {
            #expect(message == "Challenge expired.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test @MainActor
    func deniedAlarmAuthorizationKeepsTimerRunningAndReportsFallback() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        scheduler.schedulingError = TimerAlarmError.authorizationDenied
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)

        model.start()
        await model.waitForAlarmOperations()

        #expect(model.canonicalTimer?.status == .running)
        #expect(model.errorMessage?.contains("Timer continues in Pomodorough") == true)
        #expect(model.errorMessage?.contains("Allow notifications or alarms in Settings") == true)
    }

    @Test @MainActor
    func clearingCancelledTimerIgnoresStaleAlarmCleanupFailure() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)

        model.start()
        await model.waitForAlarmOperations()
        let timer = try #require(model.canonicalTimer)
        model.cancel(at: timer.anchorAt.addingTimeInterval(10))
        await model.waitForAlarmOperations()
        scheduler.cancellationError = TimerAlarmError.authorizationDenied

        model.clear()
        await model.waitForAlarmOperations()

        #expect(model.canonicalTimer == nil)
        #expect(model.errorMessage == nil)
        #expect(scheduler.operations.suffix(2) == [
            .cancel(timerID: timer.id),
            .cancel(timerID: timer.id)
        ])
    }

    @Test func apiClientMapsUnauthorizedResponse() async {
        let session = TestFixtures.session(for: "unauthorized")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        do {
            _ = try await client.challenge()
            Issue.record("Expected unauthorized error")
        } catch AppError.unauthorized {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func apiClientUsesFallbackForMalformedServerError() async {
        let session = TestFixtures.session(for: "fallback-server-error")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        do {
            _ = try await client.challenge()
            Issue.record("Expected server error")
        } catch AppError.server(let message) {
            #expect(message == "Request failed (503).")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func apiClientRejectsMalformedSuccessPayload() async {
        let session = TestFixtures.session(for: "malformed-success")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        do {
            _ = try await client.challenge()
            Issue.record("Expected decoding error")
        } catch is DecodingError {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func apiClientRejectsNonHTTPResponse() async {
        let session = TestFixtures.session(for: "non-http-response")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        do {
            _ = try await client.challenge()
            Issue.record("Expected invalid response error")
        } catch AppError.invalidResponse {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test @MainActor
    func bootstrapRevisionConflictPreservesLocalDataAndReturnsToChooser() async throws {
        let scenario = "bootstrap-cas-conflict"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        state.pendingCommands = [
            TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "local-timer"),
            TestFixtures.command(.finish, sequence: 2, elapsed: 60_000, timerID: "local-timer")
        ]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()

        model.requestHistoryResolution(.keepRemote)
        await model.confirmHistoryResolution()

        #expect(model.historyResolutionState == .choosing)
        #expect(model.history.map(\.id) == ["local-timer"])
        #expect(model.pendingCommandCount == 2)
        let persistedData = try #require(defaults.data(forKey: "timer-state-v2"))
        let persisted = try JSONDecoder.api.decode(PersistedTimerState.self, from: persistedData)
        #expect(persisted.cachedUser == nil)
        #expect(persisted.pendingBootstrapResolution == nil)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.count { $0.path == "/api/v1/bootstrap" } == 2)
        #expect(requests.count { $0.path == "/api/v1/bootstrap/resolve" } == 1)
        #expect(requests.allSatisfy { $0.path != "/api/v1/sync" })
    }

    @Test @MainActor
    func missingTaskAcknowledgementPreservesQueueAndCanonicalState() async throws {
        let scenario = "task-missing-ack"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = try #require(FocusTask(title: "Local task"))
        let operation = TaskOperation(
            id: "task-operation-missing-ack",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 2,
            hlcCounter: 0
        )
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
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

        #expect(model.pendingChangeCount == 1)
        #expect(model.tasks == [task])
        #expect(model.history.isEmpty)
        #expect(model.errorMessage?.contains("1 queued changes remain") == true)
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        let persisted = try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
        #expect(persisted.pendingTaskOperations == [operation])
    }

    @Test @MainActor
    func persistedBootstrapResolutionBlocksMutationsBeforeAndWithoutAuthentication() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let model = AppModel(
            api: APIClient(keychain: EmptyTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        #expect(model.isHistoryResolutionBlocking)
        #expect(model.historyResolutionState == .retryable(.merge))
        let pendingCount = model.pendingChangeCount
        let selectedPhase = model.selectedPhase
        let autoStartBreaks = model.autoStartBreaks
        let selectedTaskID = model.selectedTaskID
        let taskID = try #require(model.tasks.first?.id)

        model.start()
        model.setDurationMinutes(90, for: .focus)
        #expect(!model.addTask("Blocked task"))
        model.deleteTask(id: taskID)
        model.selectedPhase = .longBreak
        model.autoStartBreaks.toggle()
        model.selectedTaskID = taskID

        #expect(model.pendingChangeCount == pendingCount)
        #expect(model.selectedPhase == selectedPhase)
        #expect(model.autoStartBreaks == autoStartBreaks)
        #expect(model.selectedTaskID == selectedTaskID)

        await model.restore()

        #expect(model.sessionState == .localOnly)
        #expect(model.isHistoryResolutionBlocking)
        #expect(try persistedState(defaults) == initial)
    }

    @Test @MainActor
    func signedOutLocalStateWithoutBootstrapResolutionRemainsMutable() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            api: APIClient(keychain: EmptyTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()
        #expect(!model.isHistoryResolutionBlocking)
        model.setDurationMinutes(1, for: .focus)
        #expect(model.addTask("Usable local task"))
        model.start()

        #expect(model.sessionState == .localOnly)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.pendingCommandCount == 1)
        #expect(model.pendingDurationOperationCount == 1)
        #expect(model.tasks.map(\.title) == ["Usable local task"])
    }

    @Test @MainActor
    func persistedBootstrapResolutionBlocksMutationsWhileProfileVerificationIsDelayed() async throws {
        let scenario = "bootstrap-delayed-me"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        let request = try #require(initial.pendingBootstrapResolution)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        let restoreTask = Task { await model.restore() }
        for _ in 0..<100 {
            if TestFixtures.recordedRequests(for: scenario).contains(where: { $0.path == "/api/v1/me" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(TestFixtures.recordedRequests(for: scenario).contains { $0.path == "/api/v1/me" })
        #expect(model.isHistoryResolutionBlocking)
        let pendingCount = model.pendingChangeCount

        model.start()
        model.setDurationMinutes(90, for: .focus)
        #expect(!model.addTask("Blocked during profile verification"))
        #expect(model.pendingChangeCount == pendingCount)
        await model.retryHistoryResolution()
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve"
        })
        #expect(try persistedState(defaults).pendingBootstrapResolution == request)

        await restoreTask.value

        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        #expect(try decodedResolutionRequest(resolve) == request)
        #expect(model.historyResolutionState == .none)
    }

    @Test(
        arguments: [
            "bootstrap-response-missing-tasks",
            "bootstrap-response-task-ack-malformed",
            "bootstrap-response-task-ack-missing",
            "bootstrap-response-task-ack-duplicate",
            "bootstrap-response-task-ack-extra",
            "bootstrap-response-task-ack-absent",
            "bootstrap-response-timer-ack-malformed",
            "bootstrap-response-timer-ack-missing",
            "bootstrap-response-timer-ack-duplicate",
            "bootstrap-response-timer-ack-extra",
            "bootstrap-response-timer-ack-absent",
            "bootstrap-response-duration-ack-malformed",
            "bootstrap-response-duration-ack-missing",
            "bootstrap-response-duration-ack-duplicate",
            "bootstrap-response-duration-ack-extra",
            "bootstrap-response-duration-ack-absent"
        ]
    )
    @MainActor
    func invalidBootstrapResolutionResponsePreservesEntirePersistedClaim(_ scenario: String) async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        let request = try #require(initial.pendingBootstrapResolution)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .retryable(.merge))
        #expect(model.isHistoryResolutionBlocking)
        #expect(model.pendingChangeCount == 4)
        #expect(try persistedState(defaults) == initial)
        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        #expect(try decodedResolutionRequest(resolve) == request)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/sync" })
    }

    @Test @MainActor
    func bootstrapResolveUnauthorizedSurvivesSignOutAndSameUserReauthenticationWithExactRequest() async throws {
        let scenario = "bootstrap-resolve-unauthorized"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        let request = try #require(initial.pendingBootstrapResolution)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")

        do {
            let session = TestFixtures.session(for: scenario)
            defer { session.invalidateAndCancel() }
            let model = AppModel(
                api: APIClient(session: session, keychain: StaticTokenStore()),
                defaults: defaults,
                alarmScheduler: RecordingAlarmScheduler()
            )

            await model.restore()

            #expect(model.sessionState == .localOnly)
            #expect(model.historyResolutionState == .retryable(.merge))
            #expect(model.isHistoryResolutionBlocking)
            #expect(!model.isWorking)
            #expect(try persistedState(defaults) == initial)
            model.signOut()
            #expect(try persistedState(defaults) == initial)
        }

        let firstResolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        #expect(try decodedResolutionRequest(firstResolve) == request)
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
        #expect(try decodedResolutionRequest(resolves[1]) == request)
        #expect(restored.historyResolutionState == .none)
        #expect(!restored.isHistoryResolutionBlocking)
        #expect(try persistedState(defaults).cachedUser == TestFixtures.user)
    }

    @Test @MainActor
    func bootstrapResolve404PreservesExactPersistedClaimWithoutSyncFallback() async throws {
        let scenario = "bootstrap-resolve-404"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        let request = try #require(initial.pendingBootstrapResolution)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .retryable(.merge))
        #expect(model.isHistoryResolutionBlocking)
        #expect(!model.isOffline)
        #expect(model.errorMessage?.contains("server update") == true)
        #expect(model.history.map(\.id) == ["local-timer"])
        #expect(model.pendingChangeCount == 4)
        let persisted = try persistedState(defaults)
        #expect(persisted == initial)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.count { $0.path == "/api/v1/bootstrap/resolve" } == 1)
        #expect(requests.allSatisfy { $0.path != "/api/v1/sync" })
        let resolve = try #require(requests.first { $0.path == "/api/v1/bootstrap/resolve" })
        #expect(try decodedResolutionRequest(resolve) == request)
    }

    @Test @MainActor
    func bootstrapGet404RequiresExplicitUpdateRetryWithoutAutomaticLoop() async throws {
        let scenario = "bootstrap-get-404"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var initial = try unresolvedBootstrapState()
        initial.pendingBootstrapResolution = nil
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            retryDelay: .milliseconds(10)
        )

        await model.restore()
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.historyResolutionState == .retryable(nil))
        #expect(model.isHistoryResolutionBlocking)
        #expect(!model.isOffline)
        #expect(model.errorMessage?.contains("server update") == true)
        #expect(try persistedState(defaults) == initial)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.count { $0.path == "/api/v1/bootstrap" } == 1)
        #expect(requests.allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve" && $0.path != "/api/v1/sync"
        })
    }

    @Test @MainActor
    func replaceRemote404RaceNeverFallsBackToSyncOrClearsLocalQueues() async throws {
        let scenario = "bootstrap-resolve-race-404"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var initial = try unresolvedBootstrapState()
        initial.pendingBootstrapResolution = nil
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .retryable(.replaceRemote))
        #expect(model.isHistoryResolutionBlocking)
        #expect(!model.isOffline)
        #expect(model.errorMessage?.contains("server update") == true)
        #expect(model.history.map(\.id) == ["local-timer"])
        #expect(model.pendingChangeCount == 4)
        let persisted = try persistedState(defaults)
        let request = try #require(persisted.pendingBootstrapResolution)
        #expect(request.strategy == .replaceRemote)
        #expect(request.commands == initial.pendingCommands)
        #expect(request.taskOperations == initial.pendingTaskOperations)
        #expect(request.durationOperations == initial.pendingDurationOperations)
        #expect(persisted.bootstrapUser == initial.bootstrapUser)
        #expect(persisted.cachedUser == nil)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.count { $0.path == "/api/v1/bootstrap" } == 1)
        #expect(requests.count { $0.path == "/api/v1/bootstrap/resolve" } == 1)
        #expect(requests.allSatisfy { $0.path != "/api/v1/sync" })
    }

    @Test @MainActor
    func verifiedDifferentUserClearsOldResolutionBeforeAnyBootstrapRequest() async throws {
        let scenario = "bootstrap-reauth-different-user"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        let restoreTask = Task { await model.restore() }
        for _ in 0..<100 {
            if TestFixtures.recordedRequests(for: scenario).contains(where: { $0.path == "/api/v1/me" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(TestFixtures.recordedRequests(for: scenario).contains { $0.path == "/api/v1/me" })
        await model.retryHistoryResolution()
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve"
        })
        #expect(try persistedState(defaults) == initial)

        await restoreTask.value

        let persisted = try persistedState(defaults)
        #expect(persisted.bootstrapUser?.id == "different-bootstrap-user")
        #expect(persisted.pendingBootstrapResolution == nil)
        #expect(persisted.cachedUser == nil)
        #expect(persisted.pendingCommands == initial.pendingCommands)
        #expect(model.historyResolutionState == .choosing)
        #expect(model.isHistoryResolutionBlocking)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.contains { $0.path == "/api/v1/bootstrap" })
        #expect(requests.allSatisfy { $0.path != "/api/v1/bootstrap/resolve" })
    }

    private func unresolvedBootstrapState() throws -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        let task = try #require(FocusTask(title: "Persisted task"))
        let commands = [
            TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "local-timer"),
            TestFixtures.command(.finish, sequence: 2, elapsed: 60_000, timerID: "local-timer")
        ]
        let taskOperations = [TaskOperation(
            id: "task-operation-persisted",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 2,
            hlcCounter: 0
        )]
        let durationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-persisted",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 3
        )]
        state.bootstrapUser = TestFixtures.user
        state.pendingCommands = commands
        state.pendingTaskOperations = taskOperations
        state.pendingDurationOperations = durationOperations
        state.knownTasks = [task]
        state.settings.setMinutes(30, for: .focus)
        state.pendingBootstrapResolution = BootstrapResolveRequest(
            requestId: "bootstrap-resolution-persisted",
            deviceId: state.deviceId,
            expectedRevision: 8,
            strategy: .merge,
            commands: commands,
            taskOperations: taskOperations,
            durationOperations: durationOperations
        )
        return state
    }

    private func persistedState(_ defaults: UserDefaults) throws -> PersistedTimerState {
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
    }

    private func decodedResolutionRequest(_ request: RecordedRequest) throws -> BootstrapResolveRequest {
        let data = try #require(request.body)
        return try JSONDecoder.api.decode(BootstrapResolveRequest.self, from: data)
    }
}
