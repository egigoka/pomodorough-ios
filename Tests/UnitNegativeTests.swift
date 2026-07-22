import Foundation
import Testing
@testable import Pomodorough

@Suite("Unit Negative")
struct UnitNegativeTests {
    @Test func taskRejectsTitleContainingOnlyInvisibleEdges() {
        #expect(FocusTask(title: "\u{0000}\t\n") == nil)
    }

    @Test func timerAlarmIdentityRejectsMalformedTimerIDs() {
        #expect(TimerAlarmScheduler.alarmID(for: "remote-timer") == nil)
        #expect(TimerAlarmScheduler.alarmID(for: "timer-not-a-uuid") == nil)
    }

    @Test func settingsClampDurationsOutsideAPIContract() {
        var settings = TimerSettings()

        settings.setMinutes(0, for: .focus)
        settings.setMinutes(999, for: .longBreak)

        #expect(settings.minutes(for: .focus) == 1)
        #expect(settings.minutes(for: .longBreak) == 180)
    }

    @Test func legacyMinuteDecodingClampsBeforeIntegerConversion() throws {
        let json = Data(
            "{\"focusMinutes\":\(Int.max),\"shortBreakMinutes\":\(Int.min),\"longBreakMinutes\":15}".utf8
        )

        let settings = try JSONDecoder.api.decode(TimerSettings.self, from: json)

        #expect(settings.durationMs(for: .focus) == DurationValues.validRange.upperBound)
        #expect(settings.durationMs(for: .shortBreak) == DurationValues.validRange.lowerBound)
    }

    @Test func persistedMillisecondDurationsNormalizeToDisplayedMinutes() throws {
        let json = Data(
            #"{"focusDurationMs":90000,"shortBreakDurationMs":300000,"longBreakDurationMs":900000}"#.utf8
        )

        let settings = try JSONDecoder.api.decode(TimerSettings.self, from: json)

        #expect(settings.minutes(for: .focus) == 2)
        #expect(settings.durationMs(for: .focus) == 120_000)
    }

    @Test func canonicalAndOperationValidationRejectSubMinuteValues() {
        let durations = DurationValues(
            focus: 60_001,
            shortBreak: DurationValues.defaults.shortBreak,
            longBreak: DurationValues.defaults.longBreak
        )
        let operation = TestFixtures.durationOperation(
            id: "duration-operation-subminute",
            phase: .focus,
            durationMs: 60_001,
            wallMs: 1
        )

        #expect(!durations.isValid)
        #expect(!operation.isValid)
    }

    @Test func persistedPendingDurationsRejectMalformedHLC() throws {
        var state = PersistedTimerState.fresh()
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-malformed",
            phase: .focus,
            durationMs: 60_000,
            wallMs: 0,
            counter: 1
        )]
        let data = try JSONEncoder.api.encode(state)

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
        }
    }

    @Test func syncResponseRequiresFixedDurationFields() {
        let json = Data(
            #"{"acknowledgements":[],"revision":0,"canonicalTimer":null,"history":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":0}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(SyncResponse.self, from: json)
        }
    }

    @Test(
        arguments: [
            "acknowledgements",
            "taskAcknowledgements",
            "durationAcknowledgements",
            "durationsMs",
            "revision",
            "canonicalTimer",
            "history",
            "tasks",
            "serverTime",
            "serverHlcWallMs",
            "serverHlcCounter"
        ]
    )
    func bootstrapResponseRequiresEveryCanonicalField(_ missingKey: String) throws {
        let complete = Data(
            #"{"acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[],"durationsMs":{"focus":1500000,"short_break":300000,"long_break":900000},"revision":1,"canonicalTimer":null,"history":[],"tasks":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":0}"#.utf8
        )
        var object = try #require(JSONSerialization.jsonObject(with: complete) as? [String: Any])
        object.removeValue(forKey: missingKey)
        let incomplete = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(BootstrapResponse.self, from: incomplete)
        }
    }

    @Test func bootstrapResponseRejectsMalformedCanonicalTimer() throws {
        let json = Data(
            #"{"acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[],"durationsMs":{"focus":1500000,"short_break":300000,"long_break":900000},"revision":1,"canonicalTimer":"invalid","history":[],"tasks":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":0}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(BootstrapResponse.self, from: json)
        }
    }

    @Test func durationSyncRejectsDuplicateAcknowledgementsWithoutMutatingState() {
        var state = PersistedTimerState.fresh()
        let operation = TestFixtures.durationOperation(
            id: "duration-operation-test",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 1
        )
        state.pendingDurationOperations = [operation]
        state.settings.setMinutes(30, for: .focus)
        let original = state
        let acknowledgement = DurationAcknowledgement(
            operationId: operation.id,
            outcome: "applied",
            reason: ""
        )

        #expect(throws: AppError.self) {
            try state.applyDurationSync(
                canonicalDurations: .defaults,
                sentOperations: [operation],
                acknowledgements: [acknowledgement, acknowledgement]
            )
        }
        #expect(state == original)
    }

    @Test func durationSyncRejectsOutOfBoundsCanonicalValuesWithoutMutatingState() {
        var state = PersistedTimerState.fresh()
        let original = state

        #expect(throws: AppError.self) {
            try state.applyDurationSync(
                canonicalDurations: DurationValues(
                    focus: DurationValues.validRange.lowerBound - 1,
                    shortBreak: DurationValues.defaults.shortBreak,
                    longBreak: DurationValues.defaults.longBreak
                ),
                sentOperations: [],
                acknowledgements: []
            )
        }
        #expect(state == original)
    }

    @Test func reducerRejectsInvalidStateTransitions() {
        let running = TestFixtures.timer(status: .running, elapsed: 5_000)
        let resume = TestFixtures.command(.resume, sequence: 2, elapsed: 10_000)
        let wrongTimerFinish = TestFixtures.command(.finish, sequence: 3, elapsed: 10_000, timerID: "timer-other0001")
        let clear = TestFixtures.command(.clear, sequence: 4, elapsed: 10_000)

        #expect(TimerReducer.apply(resume, to: running, history: []).0 == running)
        #expect(TimerReducer.apply(wrongTimerFinish, to: running, history: []).0 == running)
        #expect(TimerReducer.apply(clear, to: running, history: []).0 == running)
    }

    @Test func duplicateFinishDoesNotDuplicateHistory() {
        let running = TestFixtures.timer(status: .running, elapsed: 5_000)
        let finish = TestFixtures.command(.finish, sequence: 2, elapsed: 5_000)
        let firstResult = TimerReducer.apply(finish, to: running, history: [])

        let duplicateResult = TimerReducer.apply(finish, to: running, history: firstResult.1)

        #expect(duplicateResult.1.count == 1)
    }

    @Test func duplicateCancelDoesNotDuplicateHistory() {
        let running = TestFixtures.timer(status: .running, elapsed: 5_000)
        let cancel = TestFixtures.command(.cancel, sequence: 2, elapsed: 5_000)
        let firstResult = TimerReducer.apply(cancel, to: running, history: [])

        let duplicateResult = TimerReducer.apply(cancel, to: running, history: firstResult.1)

        #expect(duplicateResult.0?.status == .cancelled)
        #expect(duplicateResult.1.count == 1)
    }

    @Test func reducerRejectsPauseAndCancelFromInactiveStates() {
        let paused = TestFixtures.timer(status: .paused, elapsed: 5_000)
        let completed = TestFixtures.timer(status: .completed, elapsed: 60_000)
        let pause = TestFixtures.command(.pause, sequence: 2, elapsed: 10_000)
        let cancel = TestFixtures.command(.cancel, sequence: 3, elapsed: 10_000)

        #expect(TimerReducer.apply(pause, to: paused, history: []).0 == paused)
        #expect(TimerReducer.apply(cancel, to: completed, history: []).0 == completed)
    }

    @Test func parserIgnoresKeepaliveUnknownEventsAndMalformedData() {
        var parser = SSERevisionParser()

        #expect(parser.consume(line: ": keepalive") == nil)
        #expect(parser.consume(line: "event: unrelated") == nil)
        #expect(parser.consume(line: "data: 23") == nil)
        #expect(parser.consume(line: "") == nil)
        #expect(parser.consume(line: "data: not-a-revision") == nil)
        #expect(parser.consume(line: "") == nil)
    }

    @Test func currentOrOlderRevisionDoesNotTriggerSync() {
        var hints = RevisionHintCoalescer()

        #expect(hints.receive(9, localRevision: 10, isSyncing: false) == false)
        #expect(hints.receive(10, localRevision: 10, isSyncing: false) == false)
        #expect(hints.receive(11, localRevision: 10, isSyncing: false) == true)
    }

    @Test func suspendedStreamCannotBeReclaimedByStaleTask() throws {
        var lifecycle = RevisionStreamLifecycle()
        lifecycle.setActive(true)
        let startedStaleID = lifecycle.begin()
        let staleID = try #require(startedStaleID)

        lifecycle.setActive(false)

        #expect(lifecycle.owns(staleID) == false)
        #expect(lifecycle.begin() == nil)
        lifecycle.setActive(true)
        let startedCurrentID = lifecycle.begin()
        let currentID = try #require(startedCurrentID)
        #expect(currentID != staleID)
        #expect(lifecycle.owns(staleID) == false)
        #expect(lifecycle.owns(currentID))
    }

    @Test(
        arguments: [
            (204, "text/event-stream" as String?),
            (200, "application/json" as String?),
            (200, "application/text/event-stream+json" as String?),
            (200, "text/event-stream-invalid" as String?),
            (200, nil as String?)
        ]
    )
    func invalidStreamResponseIsRejected(statusCode: Int, contentType: String?) {
        #expect(!RevisionStreamResponse.isValid(statusCode: statusCode, contentType: contentType))
    }

    @Test func staleSyncCannotClearNewSessionOwnership() throws {
        var ownership = SyncOwnership()
        let startedOldSync = ownership.begin(generation: 1)
        let oldSync = try #require(startedOldSync)
        ownership.invalidate()
        let startedNewSync = ownership.begin(generation: 2)
        let newSync = try #require(startedNewSync)

        #expect(ownership.finish(oldSync, currentGeneration: 2) == nil)
        #expect(ownership.isOwned(by: newSync))
        #expect(ownership.begin(generation: 2) == nil)
        #expect(ownership.finish(newSync, currentGeneration: 2) == true)
    }

    @Test func sessionVerificationRejectsWrongAndInvalidatedGenerations() {
        var verification = SessionVerification()

        #expect(!verification.allows(generation: 1))
        verification.markVerified(generation: 1)
        #expect(!verification.allows(generation: 2))
        verification.invalidate()
        #expect(!verification.allows(generation: 1))
    }

    @Test func syncOwnershipSkipsFollowUpForDifferentRequestedGeneration() throws {
        var ownership = SyncOwnership()
        let startedOwner = ownership.begin(generation: 1)
        let owner = try #require(startedOwner)

        #expect(ownership.begin(generation: 3) == nil)
        #expect(ownership.finish(owner, currentGeneration: 2) == false)
    }

    @Test func decoderRejectsInvalidAPIDate() {
        let json = Data(#"{"challenge":"challenge","nonce":"nonce","expiresAt":"not-a-date"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(NativeChallenge.self, from: json)
        }
    }
}
