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
}
