import Foundation
@testable import Pomodorough

enum TestFixtures {
    static let anchor = Date(timeIntervalSince1970: 1_000)
    static let user = User(id: "user-duration-sync", email: "sync@example.com", name: "Sync", avatarUrl: "")

    static func timer(
        status: CanonicalTimer.Status,
        elapsed: Int64,
        phase: TimerPhase = .focus,
        timerID: String = "timer-test0001",
        taskID: String? = nil
    ) -> CanonicalTimer {
        CanonicalTimer(
            id: timerID,
            taskId: taskID,
            phase: phase,
            status: status,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: elapsed,
            anchorAt: anchor,
            lastIntent: nil
        )
    }

    static func command(
        _ type: CommandType,
        sequence: Int64,
        elapsed: Int64,
        timerID: String = "timer-test0001",
        taskID: String? = nil
    ) -> TimerCommand {
        TimerCommand(
            id: "command-test\(sequence)",
            deviceSequence: sequence,
            timerId: timerID,
            taskId: taskID,
            type: type,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: anchor.addingTimeInterval(Double(sequence)),
            hlcWallMs: Int64(anchor.timeIntervalSince1970 * 1_000) + sequence,
            hlcCounter: 0,
            observedElapsedMs: elapsed
        )
    }

    static func history(
        id: String,
        phase: TimerPhase = .focus,
        status: String = "completed",
        durationMs: Int64,
        date: Date,
        taskID: String? = nil
    ) -> HistoryItem {
        HistoryItem(
            id: id,
            timerId: id,
            commandId: "command-\(id)",
            taskId: taskID,
            phase: phase,
            status: status,
            plannedDurationMs: durationMs,
            completedAt: status == "completed" ? date : nil,
            endedAt: status == "completed" ? nil : date
        )
    }

    static func durationOperation(
        id: String,
        phase: TimerPhase,
        durationMs: Int64,
        wallMs: Int64,
        counter: Int64 = 0
    ) -> DurationOperation {
        DurationOperation(
            id: id,
            phase: phase,
            durationMs: durationMs,
            occurredAt: anchor,
            hlcWallMs: wallMs,
            hlcCounter: counter
        )
    }

    static func session(for scenario: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Pomodorough-Test-Scenario": scenario]
        return URLSession(configuration: configuration)
    }
}

struct EmptyTokenStore: TokenStoring {
    func load() throws -> TokenPair? { nil }
    func save(_ tokens: TokenPair) throws {}
    func delete() throws {}
}

struct StaticTokenStore: TokenStoring {
    let tokens = TokenPair(
        accessToken: "access-token",
        accessTokenExpiresAt: Date.distantFuture,
        refreshToken: "refresh-token",
        refreshTokenExpiresAt: Date.distantFuture
    )

    func load() throws -> TokenPair? { tokens }
    func save(_ tokens: TokenPair) throws {}
    func delete() throws {}
}

enum RecordedAlarmOperation: Equatable {
    case requestAuthorization
    case schedule(timerID: String, phase: TimerPhase, duration: TimeInterval)
    case pause(timerID: String)
    case resume(timerID: String, phase: TimerPhase, duration: TimeInterval)
    case cancel(timerID: String)
}

@MainActor
final class RecordingAlarmScheduler: TimerAlarmScheduling {
    var operations: [RecordedAlarmOperation] = []
    var authorizationError: Error?
    var schedulingError: Error?
    var cancellationError: Error?

    func requestAuthorization() async throws {
        operations.append(.requestAuthorization)
        if let authorizationError { throw authorizationError }
    }

    func schedule(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
        operations.append(.schedule(timerID: timerID, phase: phase, duration: duration))
        if let schedulingError { throw schedulingError }
    }

    func pause(timerID: String) throws {
        operations.append(.pause(timerID: timerID))
    }

    func resume(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
        operations.append(.resume(timerID: timerID, phase: phase, duration: duration))
    }

    func cancel(timerID: String) throws {
        operations.append(.cancel(timerID: timerID))
        if let cancellationError { throw cancellationError }
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "X-Pomodorough-Test-Scenario") != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Pomodorough-Test-Scenario")
        if scenario == "non-http-response" {
            let response = URLResponse(
                url: request.url!,
                mimeType: "application/json",
                expectedContentLength: 0,
                textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let statusCode: Int
        let body: Data

        switch scenario {
        case "challenge-success"
            where request.httpMethod == "POST"
                && request.url?.path == "/api/v1/auth/google/challenge"
                && request.value(forHTTPHeaderField: "Accept") == "application/json":
            statusCode = 200
            body = Data(#"{"challenge":"challenge-123","nonce":"nonce-456","expiresAt":"2026-07-20T12:34:56.789Z"}"#.utf8)
        case "server-error":
            statusCode = 422
            body = Data(#"{"error":"Challenge expired."}"#.utf8)
        case "fallback-server-error":
            statusCode = 503
            body = Data("not-json".utf8)
        case "malformed-success":
            statusCode = 200
            body = Data("{".utf8)
        case "standard-date":
            statusCode = 200
            body = Data(#"{"challenge":"challenge-123","nonce":"nonce-456","expiresAt":"2026-07-20T12:34:56Z"}"#.utf8)
        case "duration-sync" where request.url?.path == "/api/v1/me":
            statusCode = 200
            body = Data(#"{"user":{"id":"user-duration-sync","email":"sync@example.com","name":"Sync","avatarUrl":""},"csrfToken":"csrf"}"#.utf8)
        case "duration-invalid-ack" where request.url?.path == "/api/v1/me":
            statusCode = 200
            body = Data(#"{"user":{"id":"user-duration-sync","email":"sync@example.com","name":"Sync","avatarUrl":""},"csrfToken":"csrf"}"#.utf8)
        case "duration-sync"
            where request.httpMethod == "POST"
                && request.url?.path == "/api/v1/sync":
            statusCode = 200
            body = Data(#"{"acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[],"durationsMs":{"focus":2400000,"short_break":360000,"long_break":1200000},"revision":7,"canonicalTimer":null,"history":[],"tasks":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":4}"#.utf8)
        case "duration-invalid-ack"
            where request.httpMethod == "POST"
                && request.url?.path == "/api/v1/sync":
            statusCode = 200
            body = Data(#"{"acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[{"operationId":"duration-operation-unexpected","outcome":"applied","reason":""}],"durationsMs":{"focus":1800000,"short_break":300000,"long_break":900000},"revision":7,"canonicalTimer":null,"history":[],"tasks":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":4}"#.utf8)
        case "unauthorized":
            statusCode = 401
            body = Data(#"{"error":"Unauthorized"}"#.utf8)
        default:
            statusCode = 400
            body = Data(#"{"error":"Unexpected test request."}"#.utf8)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
