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

    static func session(for scenario: String, resetsRecorder: Bool = true) -> URLSession {
        if resetsRecorder { StubRequestRecorder.shared.reset(scenario: scenario) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Pomodorough-Test-Scenario": scenario]
        return URLSession(configuration: configuration)
    }

    static func recordedRequests(for scenario: String) -> [RecordedRequest] {
        StubRequestRecorder.shared.requests(for: scenario)
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

struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let body: Data?
}

final class StubRequestRecorder: @unchecked Sendable {
    static let shared = StubRequestRecorder()

    private let lock = NSLock()
    private var storage: [String: [RecordedRequest]] = [:]

    func reset(scenario: String) {
        lock.withLock { storage[scenario] = [] }
    }

    func record(_ request: URLRequest, body: Data?, scenario: String) -> Int {
        lock.withLock {
            let recorded = RecordedRequest(
                method: request.httpMethod ?? "GET",
                path: request.url?.path ?? "",
                body: body
            )
            storage[scenario, default: []].append(recorded)
            return storage[scenario, default: []].count { $0.path == recorded.path }
        }
    }

    func requests(for scenario: String) -> [RecordedRequest] {
        lock.withLock { storage[scenario] ?? [] }
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
        let requestBody = Self.bodyData(request)
        let pathAttempt = scenario.map {
            StubRequestRecorder.shared.record(request, body: requestBody, scenario: $0)
        } ?? 0
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
        let path = request.url?.path

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
        case "bootstrap-delayed-me" where path == "/api/v1/me":
            Thread.sleep(forTimeInterval: 0.5)
            statusCode = 200
            body = Self.meBody
        case "bootstrap-reauth-different-user" where path == "/api/v1/me":
            Thread.sleep(forTimeInterval: 0.5)
            statusCode = 200
            body = Self.differentUserMeBody
        case _ where Self.usesBootstrapStub(scenario) && path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case "bootstrap-get-404"
            where request.httpMethod == "GET"
                && path == "/api/v1/bootstrap":
            statusCode = 404
            body = Data(#"{"error":"Not found"}"#.utf8)
        case _ where Self.usesBootstrapStub(scenario)
            && request.httpMethod == "GET"
            && path == "/api/v1/bootstrap":
            statusCode = 200
            let history = Self.bootstrapHistory(for: scenario)
            body = Self.syncResponse(
                revision: history.isEmpty ? 5 : 8,
                history: history
            )
        case "bootstrap-network-retry"
            where request.httpMethod == "POST"
                && path == "/api/v1/bootstrap/resolve"
                && pathAttempt == 1:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        case "bootstrap-cas-conflict"
            where request.httpMethod == "POST"
                && path == "/api/v1/bootstrap/resolve":
            statusCode = 409
            body = Data(#"{"error":"revision conflict"}"#.utf8)
        case "bootstrap-resolve-unauthorized"
            where request.httpMethod == "POST"
                && path == "/api/v1/bootstrap/resolve"
                && pathAttempt == 1:
            statusCode = 401
            body = Data(#"{"error":"Unauthorized"}"#.utf8)
        case _ where (scenario == "bootstrap-resolve-404" || scenario == "bootstrap-resolve-race-404")
            && request.httpMethod == "POST"
            && path == "/api/v1/bootstrap/resolve":
            statusCode = 404
            body = Data(#"{"error":"Not found"}"#.utf8)
        case _ where Self.usesBootstrapStub(scenario)
            && request.httpMethod == "POST"
            && path == "/api/v1/bootstrap/resolve":
            statusCode = 200
            let requestObject = Self.requestObject(requestBody)
            let strategy = requestObject?["strategy"] as? String
            body = Self.bootstrapResolveResponse(
                scenario: scenario,
                strategy: strategy,
                request: requestObject
            )
        case "bootstrap-resolve-race-404"
            where request.httpMethod == "POST"
                && path == "/api/v1/sync":
            statusCode = 200
            body = Self.syncResponse(revision: 8, history: [Self.remoteHistory])
        case _ where Self.usesBootstrapStub(scenario)
            && request.httpMethod == "POST"
            && path == "/api/v1/sync":
            statusCode = 200
            let requestObject = Self.requestObject(requestBody)
            let resolutionRequest = Self.resolutionRequestObject(for: scenario)
            body = Self.syncResponse(
                revision: 10,
                history: Self.resolvedHistory(
                    for: resolutionRequest?["strategy"] as? String,
                    scenario: scenario
                ),
                acknowledgements: Self.acknowledgements(from: requestObject, key: "commands", idKey: "commandId"),
                taskAcknowledgements: Self.acknowledgements(from: requestObject, key: "taskOperations", idKey: "operationId"),
                durationAcknowledgements: Self.acknowledgements(from: requestObject, key: "durationOperations", idKey: "operationId"),
                tasks: Self.tasks(from: resolutionRequest)
            )
        case _ where scenario?.hasPrefix("task-sync") == true && path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case _ where scenario?.hasPrefix("task-sync") == true
            && request.httpMethod == "POST"
            && path == "/api/v1/sync":
            statusCode = 200
            body = Self.taskSyncResponse(
                scenario: scenario,
                pathAttempt: pathAttempt,
                request: Self.requestObject(requestBody)
            )
        case "task-missing-ack" where path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case "task-missing-ack" where request.httpMethod == "POST" && path == "/api/v1/sync":
            statusCode = 200
            body = Self.syncResponse(revision: 12, history: [], tasks: [Self.remoteTask])
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

    private static let meBody = Data(
        #"{"user":{"id":"user-duration-sync","email":"sync@example.com","name":"Sync","avatarUrl":""},"csrfToken":"csrf"}"#.utf8
    )

    private static let differentUserMeBody = Data(
        #"{"user":{"id":"different-bootstrap-user","email":"different@example.com","name":"Different","avatarUrl":""},"csrfToken":"csrf"}"#.utf8
    )

    private static var localHistory: [String: Any] {
        [
            "id": "local-history",
            "timerId": "local-timer",
            "commandId": "command-test2",
            "phase": "focus",
            "status": "completed",
            "plannedDurationMs": 60_000,
            "completedAt": "2026-07-21T08:00:00.000Z"
        ]
    }

    private static var remoteHistory: [String: Any] {
        [
            "id": "remote-history",
            "timerId": "remote-timer",
            "commandId": "remote-command",
            "phase": "focus",
            "status": "completed",
            "plannedDurationMs": 1_500_000,
            "completedAt": "2026-07-20T08:00:00.000Z"
        ]
    }

    private static func remoteEndedHistory(id: String, status: String) -> [String: Any] {
        [
            "id": id,
            "timerId": "timer-\(id)",
            "commandId": "command-\(id)",
            "phase": "focus",
            "status": status,
            "plannedDurationMs": 1_500_000,
            "endedAt": "2026-07-20T08:00:00.000Z"
        ]
    }

    private static var remoteTask: [String: Any] {
        [
            "id": "00000000-0000-8000-8000-000000000001",
            "title": "Remote task"
        ]
    }

    private static var associatedTimer: [String: Any] {
        [
            "id": "remote-associated-timer",
            "taskId": remoteTask["id"]!,
            "phase": "focus",
            "status": "running",
            "plannedDurationMs": 1_500_000,
            "elapsedAtAnchorMs": 120_000,
            "anchorAt": "2026-07-21T08:00:00.000Z",
            "lastIntent": NSNull()
        ]
    }

    private static var associatedHistory: [String: Any] {
        [
            "id": "remote-associated-history",
            "timerId": "remote-associated-history-timer",
            "commandId": "remote-associated-command",
            "taskId": remoteTask["id"]!,
            "phase": "focus",
            "status": "completed",
            "plannedDurationMs": 1_500_000,
            "completedAt": "2026-07-21T07:00:00.000Z"
        ]
    }

    private static func usesBootstrapStub(_ scenario: String?) -> Bool {
        scenario?.hasPrefix("bootstrap-") == true
    }

    private static func hasRemoteBootstrapHistory(_ scenario: String?) -> Bool {
        scenario != "bootstrap-local-only"
            && scenario != "bootstrap-resolve-race-404"
            && scenario?.hasPrefix("bootstrap-empty-") != true
    }

    private static func bootstrapHistory(for scenario: String?) -> [[String: Any]] {
        if scenario == "bootstrap-history-counts" {
            return [
                remoteHistory,
                remoteEndedHistory(id: "remote-cancelled", status: "cancelled"),
                remoteEndedHistory(id: "remote-superseded", status: "superseded")
            ]
        }
        return hasRemoteBootstrapHistory(scenario) ? [remoteHistory] : []
    }

    private static func requestObject(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func resolutionRequestObject(for scenario: String?) -> [String: Any]? {
        guard let scenario,
              let body = StubRequestRecorder.shared.requests(for: scenario).last(where: {
                  $0.path == "/api/v1/bootstrap/resolve"
              })?.body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private static func acknowledgements(
        from request: [String: Any]?,
        key: String,
        idKey: String
    ) -> [[String: Any]] {
        (request?[key] as? [[String: Any]] ?? []).compactMap { operation in
            guard let id = operation["id"] as? String else { return nil }
            return [idKey: id, "outcome": "applied", "reason": ""]
        }
    }

    private static func tasks(from request: [String: Any]?) -> [[String: Any]] {
        (request?["taskOperations"] as? [[String: Any]] ?? []).compactMap { operation in
            guard operation["type"] as? String == "upsert",
                  let id = operation["taskId"] as? String,
                  let title = operation["title"] as? String else { return nil }
            return ["id": id, "title": title]
        }
    }

    private static func taskSyncResponse(
        scenario: String?,
        pathAttempt: Int,
        request: [String: Any]?
    ) -> Data {
        let taskAcknowledgements = acknowledgements(
            from: request,
            key: "taskOperations",
            idKey: "operationId"
        )
        switch scenario {
        case "task-sync-delete-wire":
            return syncResponse(
                revision: 12,
                history: [],
                taskAcknowledgements: taskAcknowledgements,
                tasks: []
            )
        case "task-sync-remote-lifecycle":
            return syncResponse(
                revision: 11 + pathAttempt,
                history: [],
                taskAcknowledgements: taskAcknowledgements,
                tasks: pathAttempt == 1 ? [remoteTask] : []
            )
        case "task-sync-in-flight-rebase":
            if pathAttempt == 1 { Thread.sleep(forTimeInterval: 0.5) }
            return syncResponse(
                revision: 11 + pathAttempt,
                history: [],
                taskAcknowledgements: taskAcknowledgements,
                tasks: [remoteTask] + cumulativeTasks(for: scenario)
            )
        case "task-sync-batching":
            return syncResponse(
                revision: 11 + pathAttempt,
                history: [],
                taskAcknowledgements: taskAcknowledgements,
                tasks: cumulativeTasks(for: scenario)
            )
        case "task-sync-associations":
            return syncResponse(
                revision: 12,
                history: [associatedHistory],
                taskAcknowledgements: taskAcknowledgements,
                tasks: [remoteTask],
                canonicalTimer: associatedTimer
            )
        default:
            return syncResponse(
                revision: 12,
                history: [remoteHistory],
                taskAcknowledgements: taskAcknowledgements,
                tasks: [remoteTask]
            )
        }
    }

    private static func cumulativeTasks(for scenario: String?) -> [[String: Any]] {
        guard let scenario else { return [] }
        var tasksByID: [String: [String: Any]] = [:]
        for request in StubRequestRecorder.shared.requests(for: scenario) where request.path == "/api/v1/sync" {
            let operations = requestObject(request.body)?["taskOperations"] as? [[String: Any]] ?? []
            for operation in operations {
                guard let id = operation["taskId"] as? String else { continue }
                if operation["type"] as? String == "delete" {
                    tasksByID.removeValue(forKey: id)
                } else if let title = operation["title"] as? String {
                    tasksByID[id] = ["id": id, "title": title]
                }
            }
        }
        return tasksByID.values.sorted {
            ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
        }
    }

    private static func resolvedHistory(for strategy: String?, scenario: String?) -> [[String: Any]] {
        if scenario?.hasPrefix("bootstrap-empty-") == true { return [] }
        return switch strategy {
        case "replace_remote": [localHistory]
        case "merge": [localHistory, remoteHistory]
        default: [remoteHistory]
        }
    }

    private static func bootstrapResolveResponse(
        scenario: String?,
        strategy: String?,
        request: [String: Any]?
    ) -> Data {
        var response = syncResponseObject(
            revision: 9,
            history: resolvedHistory(for: strategy, scenario: scenario),
            acknowledgements: acknowledgements(from: request, key: "commands", idKey: "commandId"),
            taskAcknowledgements: acknowledgements(from: request, key: "taskOperations", idKey: "operationId"),
            durationAcknowledgements: acknowledgements(from: request, key: "durationOperations", idKey: "operationId"),
            tasks: tasks(from: request)
        )
        switch scenario {
        case "bootstrap-response-missing-tasks":
            response.removeValue(forKey: "tasks")
        case "bootstrap-response-task-ack-malformed":
            response["taskAcknowledgements"] = "invalid"
        case "bootstrap-response-task-ack-missing":
            response["taskAcknowledgements"] = []
        case "bootstrap-response-task-ack-duplicate":
            if let acknowledgement = (response["taskAcknowledgements"] as? [[String: Any]])?.first {
                response["taskAcknowledgements"] = [acknowledgement, acknowledgement]
            }
        case "bootstrap-response-task-ack-extra":
            var taskAcknowledgements = response["taskAcknowledgements"] as? [[String: Any]] ?? []
            taskAcknowledgements.append([
                "operationId": "task-operation-extra",
                "outcome": "applied",
                "reason": ""
            ])
            response["taskAcknowledgements"] = taskAcknowledgements
        case "bootstrap-response-task-ack-absent":
            response.removeValue(forKey: "taskAcknowledgements")
        case "bootstrap-response-timer-ack-malformed":
            response["acknowledgements"] = "invalid"
        case "bootstrap-response-timer-ack-missing":
            response["acknowledgements"] = []
        case "bootstrap-response-timer-ack-duplicate":
            if let acknowledgement = (response["acknowledgements"] as? [[String: Any]])?.first {
                response["acknowledgements"] = [acknowledgement, acknowledgement]
            }
        case "bootstrap-response-timer-ack-extra":
            var acknowledgements = response["acknowledgements"] as? [[String: Any]] ?? []
            acknowledgements.append([
                "commandId": "command-extra",
                "outcome": "applied",
                "reason": ""
            ])
            response["acknowledgements"] = acknowledgements
        case "bootstrap-response-timer-ack-absent":
            response.removeValue(forKey: "acknowledgements")
        case "bootstrap-response-duration-ack-malformed":
            response["durationAcknowledgements"] = "invalid"
        case "bootstrap-response-duration-ack-missing":
            response["durationAcknowledgements"] = []
        case "bootstrap-response-duration-ack-duplicate":
            if let acknowledgement = (response["durationAcknowledgements"] as? [[String: Any]])?.first {
                response["durationAcknowledgements"] = [acknowledgement, acknowledgement]
            }
        case "bootstrap-response-duration-ack-extra":
            var durationAcknowledgements = response["durationAcknowledgements"] as? [[String: Any]] ?? []
            durationAcknowledgements.append([
                "operationId": "duration-operation-extra",
                "outcome": "applied",
                "reason": ""
            ])
            response["durationAcknowledgements"] = durationAcknowledgements
        case "bootstrap-response-duration-ack-absent":
            response.removeValue(forKey: "durationAcknowledgements")
        default:
            break
        }
        return try! JSONSerialization.data(withJSONObject: response)
    }

    private static func syncResponse(
        revision: Int,
        history: [[String: Any]],
        acknowledgements: [[String: Any]] = [],
        taskAcknowledgements: [[String: Any]] = [],
        durationAcknowledgements: [[String: Any]] = [],
        tasks: [[String: Any]] = [],
        canonicalTimer: Any = NSNull()
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: syncResponseObject(
            revision: revision,
            history: history,
            acknowledgements: acknowledgements,
            taskAcknowledgements: taskAcknowledgements,
            durationAcknowledgements: durationAcknowledgements,
            tasks: tasks,
            canonicalTimer: canonicalTimer
        ))
    }

    private static func syncResponseObject(
        revision: Int,
        history: [[String: Any]],
        acknowledgements: [[String: Any]],
        taskAcknowledgements: [[String: Any]],
        durationAcknowledgements: [[String: Any]],
        tasks: [[String: Any]],
        canonicalTimer: Any = NSNull()
    ) -> [String: Any] {
        [
            "acknowledgements": acknowledgements,
            "taskAcknowledgements": taskAcknowledgements,
            "durationAcknowledgements": durationAcknowledgements,
            "durationsMs": [
                "focus": 1_500_000,
                "short_break": 300_000,
                "long_break": 900_000
            ],
            "revision": revision,
            "canonicalTimer": canonicalTimer,
            "history": history,
            "tasks": tasks,
            "serverTime": "2026-07-21T08:00:00.000Z",
            "serverHlcWallMs": 1_784_620_800_000,
            "serverHlcCounter": 4
        ]
    }
}
