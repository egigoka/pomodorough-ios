import Foundation

actor APIClient {
    private let baseURL = URL(string: "https://pomodorough.egigoka.me")!
    private let session: URLSession
    private let keychain: any TokenStoring
    private var tokens: TokenPair?
    private var refreshTask: Task<TokenPair, Error>?
    private var tokenGeneration = 0

    init(session: URLSession = .shared, keychain: any TokenStoring = KeychainStore()) {
        self.session = session
        self.keychain = keychain
    }

    func restoreTokens() throws -> Bool {
        tokens = try keychain.load()
        tokenGeneration += 1
        return tokens != nil
    }

    func challenge() async throws -> NativeChallenge {
        try await send("/api/v1/auth/google/challenge", method: "POST", authenticated: false)
    }

    func exchange(_ request: NativeExchangeRequest) async throws -> MeResponse {
        let pair: TokenPair = try await send(
            "/api/v1/auth/google/exchange",
            method: "POST",
            body: request,
            authenticated: false
        )
        tokenGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        try keychain.save(pair)
        tokens = pair
        return try await me()
    }

    func me() async throws -> MeResponse {
        try await send("/api/v1/me", authenticated: true)
    }

    func sync(_ request: SyncRequest) async throws -> SyncResponse {
        do {
            return try await send("/api/v1/sync", method: "POST", body: request, authenticated: true)
        } catch is DecodingError {
            throw AppError.invalidResponse
        }
    }

    func bootstrap(_: SyncRequest) async throws -> BootstrapResponse {
        do {
            let response: BootstrapResponse = try await send(
                "/api/v1/bootstrap",
                authenticated: true,
                reportsMissingRoute: true
            )
            return try response.validatingEmptyAcknowledgements()
        } catch is MissingRouteError {
            throw AppError.historyReplacementUnavailable
        } catch is DecodingError {
            throw AppError.invalidResponse
        }
    }

    func resolveBootstrap(_ request: BootstrapResolveRequest) async throws -> BootstrapResponse {
        do {
            return try await send(
                "/api/v1/bootstrap/resolve",
                method: "POST",
                body: request,
                authenticated: true,
                reportsMissingRoute: true
            )
        } catch is MissingRouteError {
            throw AppError.historyReplacementUnavailable
        } catch is DecodingError {
            throw AppError.invalidResponse
        }
    }

    func revisionEvents() async throws -> AsyncThrowingStream<Int64, Error> {
        var request = URLRequest(url: baseURL.appending(path: "/api/v1/stream"))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let streamRequest = request
        let session = self.session

        return AsyncThrowingStream<Int64, Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: streamRequest)
                    guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
                    if http.statusCode == 401 { throw AppError.unauthorized }
                    guard RevisionStreamResponse.isValid(
                        statusCode: http.statusCode,
                        contentType: http.value(forHTTPHeaderField: "Content-Type")
                    ) else {
                        throw AppError.server("Invalid revision stream response (\(http.statusCode)).")
                    }

                    var parser = SSERevisionParser()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let revision = parser.consume(line: line) {
                            continuation.yield(revision)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func logout() async throws {
        _ = try await perform(
            "/api/v1/auth/logout",
            method: "POST",
            body: Optional<String>.none,
            authenticated: true
        )
        try clearTokens()
    }

    func clearTokens() throws {
        tokenGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        try keychain.delete()
    }

    private func validAccessToken() async throws -> String {
        guard let tokens else { throw AppError.unauthorized }
        if tokens.accessTokenExpiresAt.timeIntervalSinceNow > 30 {
            return tokens.accessToken
        }
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }

        let generation = tokenGeneration
        let task = Task { try await refresh(tokens.refreshToken, generation: generation) }
        refreshTask = task
        defer {
            if generation == tokenGeneration { refreshTask = nil }
        }
        return try await task.value.accessToken
    }

    private func refresh(_ refreshToken: String, generation: Int) async throws -> TokenPair {
        let pair: TokenPair = try await send(
            "/api/v1/auth/refresh",
            method: "POST",
            body: RefreshRequest(refreshToken: refreshToken),
            authenticated: false
        )
        try Task.checkCancellation()
        guard generation == tokenGeneration else { throw AppError.unauthorized }
        try keychain.save(pair)
        tokens = pair
        return pair
    }

    private func send<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        authenticated: Bool,
        reportsMissingRoute: Bool = false
    ) async throws -> Response {
        try await send(
            path,
            method: method,
            body: Optional<String>.none,
            authenticated: authenticated,
            reportsMissingRoute: reportsMissingRoute
        )
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Body?,
        authenticated: Bool,
        reportsMissingRoute: Bool = false
    ) async throws -> Response {
        let data = try await perform(
            path,
            method: method,
            body: body,
            authenticated: authenticated,
            reportsMissingRoute: reportsMissingRoute
        )
        return try JSONDecoder.api.decode(Response.self, from: data)
    }

    private func perform<Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?,
        authenticated: Bool,
        reportsMissingRoute: Bool = false
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder.api.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AppError.unauthorized }
            if http.statusCode == 404, reportsMissingRoute { throw MissingRouteError() }
            let message = (try? JSONDecoder.api.decode(APIError.self, from: data).error) ?? "Request failed (\(http.statusCode))."
            if http.statusCode == 409 { throw AppError.conflict(message) }
            throw AppError.server(message)
        }
        return data
    }
}

private struct APIError: Decodable { let error: String }
private struct MissingRouteError: Error {}

private extension BootstrapResponse {
    func validatingEmptyAcknowledgements() throws -> Self {
        guard acknowledgements.isEmpty,
              taskAcknowledgements.isEmpty,
              durationAcknowledgements.isEmpty,
              autoStartAcknowledgements.isEmpty else {
            throw AppError.invalidResponse
        }
        return self
    }
}

extension JSONDecoder {
    static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return decoder
    }
}

extension JSONEncoder {
    static var api: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            let standard = Date.ISO8601FormatStyle()
            if let date = try? fractional.parse(value) {
                return date
            }
            if let date = try? standard.parse(value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid RFC 3339 date")
        }
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
    }
}
