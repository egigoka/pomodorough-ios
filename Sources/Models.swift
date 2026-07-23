import CryptoKit
import Foundation

struct SSERevisionParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(line: String) -> Int64? {
        if line.isEmpty {
            defer {
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
            }
            guard eventName == nil || eventName == "message" || eventName == "revision" else { return nil }
            let data = dataLines.joined(separator: "\n")
            guard !data.isEmpty else { return nil }
            if let raw = Int64(data.trimmingCharacters(in: .whitespacesAndNewlines)) { return raw }
            return (try? JSONDecoder().decode(RevisionEnvelope.self, from: Data(data.utf8)))?.revision
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            eventName = Self.fieldValue(line, prefixLength: 6)
        } else if line.hasPrefix("data:") {
            dataLines.append(Self.fieldValue(line, prefixLength: 5))
        }
        return nil
    }

    private static func fieldValue(_ line: String, prefixLength: Int) -> String {
        var value = String(line.dropFirst(prefixLength))
        if value.first == " " { value.removeFirst() }
        return value
    }
}

struct RevisionHintCoalescer: Sendable {
    private var latestPendingRevision: Int64?

    mutating func receive(_ revision: Int64, localRevision: Int64, isSyncing: Bool) -> Bool {
        guard revision > localRevision else { return false }
        guard isSyncing else { return true }
        latestPendingRevision = max(latestPendingRevision ?? revision, revision)
        return false
    }

    mutating func consumeFollowUp(localRevision: Int64) -> Bool {
        defer { latestPendingRevision = nil }
        return latestPendingRevision.map { $0 > localRevision } ?? false
    }
}

struct RevisionStreamLifecycle: Sendable {
    private(set) var isActive = false
    private var currentID: UUID?

    mutating func setActive(_ active: Bool) {
        isActive = active
        if !active { currentID = nil }
    }

    mutating func begin() -> UUID? {
        guard isActive, currentID == nil else { return nil }
        let id = UUID()
        currentID = id
        return id
    }

    func owns(_ id: UUID?) -> Bool {
        isActive && id != nil && currentID == id
    }

    mutating func end(_ id: UUID) {
        if currentID == id { currentID = nil }
    }

    mutating func cancelCurrent() {
        currentID = nil
    }
}

struct SessionVerification: Sendable {
    private var generation: Int?

    mutating func markVerified(generation: Int) {
        self.generation = generation
    }

    mutating func invalidate() {
        generation = nil
    }

    func allows(generation: Int) -> Bool {
        self.generation == generation
    }
}

struct SyncOwnership: Sendable {
    private var ownerID: UUID?
    private var requestedGeneration: Int?

    mutating func begin(generation: Int) -> UUID? {
        guard ownerID == nil else {
            requestedGeneration = max(requestedGeneration ?? generation, generation)
            return nil
        }
        let id = UUID()
        ownerID = id
        return id
    }

    mutating func invalidate() {
        ownerID = nil
        requestedGeneration = nil
    }

    mutating func finish(_ id: UUID, currentGeneration: Int) -> Bool? {
        guard ownerID == id else { return nil }
        ownerID = nil
        defer { requestedGeneration = nil }
        return requestedGeneration == currentGeneration
    }

    func isOwned(by id: UUID?) -> Bool {
        id != nil && ownerID == id
    }
}

enum RemotePolling {
    static func interval(isTimerActive: Bool) -> TimeInterval {
        isTimerActive ? 2 : 5
    }
}

enum RevisionStreamResponse {
    static func isValid(statusCode: Int, contentType: String?) -> Bool {
        guard statusCode == 200, let contentType else { return false }
        let mediaType = contentType.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return mediaType.caseInsensitiveCompare("text/event-stream") == .orderedSame
    }
}

private struct RevisionEnvelope: Decodable {
    let revision: Int64
}

struct User: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let email: String
    let name: String
    let avatarUrl: String
}

struct MeResponse: Codable, Sendable {
    let user: User
    let csrfToken: String
}

struct NativeChallenge: Codable, Sendable {
    let challenge: String
    let nonce: String
    let expiresAt: Date
}

struct TokenPair: Codable, Sendable {
    let accessToken: String
    let accessTokenExpiresAt: Date
    let refreshToken: String
    let refreshTokenExpiresAt: Date
}

struct NativeExchangeRequest: Encodable, Sendable {
    let idToken: String
    let challenge: String
    let deviceId: String
    let platform: String
}

struct RefreshRequest: Encodable, Sendable { let refreshToken: String }

enum TimerPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case focus
    case shortBreak = "short_break"
    case longBreak = "long_break"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    var routeLabel: String {
        switch self {
        case .focus: "Work"
        case .shortBreak: "Reset"
        case .longBreak: "Recover"
        }
    }

    var abbreviation: String {
        switch self {
        case .focus: "F"
        case .shortBreak: "SB"
        case .longBreak: "LB"
        }
    }

    var defaultMinutes: Int {
        switch self {
        case .focus: 25
        case .shortBreak: 5
        case .longBreak: 15
        }
    }
}

struct DurationValues: Codable, Equatable, Sendable {
    static let wireUnitMs: Int64 = 60_000
    static let validRange: ClosedRange<Int64> = 60_000...10_800_000
    static let defaults = Self(
        focus: Int64(TimerPhase.focus.defaultMinutes) * 60_000,
        shortBreak: Int64(TimerPhase.shortBreak.defaultMinutes) * 60_000,
        longBreak: Int64(TimerPhase.longBreak.defaultMinutes) * 60_000
    )

    var focus: Int64
    var shortBreak: Int64
    var longBreak: Int64

    var isValid: Bool {
        Self.isValidWireDuration(focus)
            && Self.isValidWireDuration(shortBreak)
            && Self.isValidWireDuration(longBreak)
    }

    static func isValidWireDuration(_ durationMs: Int64) -> Bool {
        validRange.contains(durationMs) && durationMs.isMultiple(of: wireUnitMs)
    }

    func durationMs(for phase: TimerPhase) -> Int64 {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }

    mutating func setDurationMs(_ durationMs: Int64, for phase: TimerPhase) {
        switch phase {
        case .focus: focus = durationMs
        case .shortBreak: shortBreak = durationMs
        case .longBreak: longBreak = durationMs
        }
    }

    private enum CodingKeys: String, CodingKey {
        case focus
        case shortBreak = "short_break"
        case longBreak = "long_break"
    }
}

struct TimerSettings: Codable, Equatable, Sendable {
    var selectedPhase: TimerPhase = .focus
    var autoStartBreaks = false
    private var focusDurationMs = DurationValues.defaults.focus
    private var shortBreakDurationMs = DurationValues.defaults.shortBreak
    private var longBreakDurationMs = DurationValues.defaults.longBreak

    var focusMinutes: Int {
        get { minutes(for: .focus) }
        set { setMinutes(newValue, for: .focus) }
    }

    var shortBreakMinutes: Int {
        get { minutes(for: .shortBreak) }
        set { setMinutes(newValue, for: .shortBreak) }
    }

    var longBreakMinutes: Int {
        get { minutes(for: .longBreak) }
        set { setMinutes(newValue, for: .longBreak) }
    }

    init() {}

    func minutes(for phase: TimerPhase) -> Int {
        Int(durationMs(for: phase) / DurationValues.wireUnitMs)
    }

    func durationMs(for phase: TimerPhase) -> Int64 {
        durationsMs.durationMs(for: phase)
    }

    mutating func setMinutes(_ minutes: Int, for phase: TimerPhase) {
        let clamped = min(180, max(1, minutes))
        var durations = durationsMs
        durations.setDurationMs(Int64(clamped) * 60_000, for: phase)
        durationsMs = durations
    }

    var durationsMs: DurationValues {
        get {
            DurationValues(
                focus: focusDurationMs,
                shortBreak: shortBreakDurationMs,
                longBreak: longBreakDurationMs
            )
        }
        set {
            focusDurationMs = Self.normalizedDuration(newValue.focus)
            shortBreakDurationMs = Self.normalizedDuration(newValue.shortBreak)
            longBreakDurationMs = Self.normalizedDuration(newValue.longBreak)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case selectedPhase, autoStartBreaks
        case focusDurationMs, shortBreakDurationMs, longBreakDurationMs
        case focusMinutes, shortBreakMinutes, longBreakMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedPhase = try values.decodeIfPresent(TimerPhase.self, forKey: .selectedPhase) ?? .focus
        autoStartBreaks = try values.decodeIfPresent(Bool.self, forKey: .autoStartBreaks) ?? false
        focusDurationMs = Self.decodedDuration(
            from: values,
            durationKey: .focusDurationMs,
            legacyMinutesKey: .focusMinutes,
            defaultValue: DurationValues.defaults.focus
        )
        shortBreakDurationMs = Self.decodedDuration(
            from: values,
            durationKey: .shortBreakDurationMs,
            legacyMinutesKey: .shortBreakMinutes,
            defaultValue: DurationValues.defaults.shortBreak
        )
        longBreakDurationMs = Self.decodedDuration(
            from: values,
            durationKey: .longBreakDurationMs,
            legacyMinutesKey: .longBreakMinutes,
            defaultValue: DurationValues.defaults.longBreak
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(selectedPhase, forKey: .selectedPhase)
        try values.encode(autoStartBreaks, forKey: .autoStartBreaks)
        try values.encode(focusDurationMs, forKey: .focusDurationMs)
        try values.encode(shortBreakDurationMs, forKey: .shortBreakDurationMs)
        try values.encode(longBreakDurationMs, forKey: .longBreakDurationMs)
    }

    private static func decodedDuration(
        from values: KeyedDecodingContainer<CodingKeys>,
        durationKey: CodingKeys,
        legacyMinutesKey: CodingKeys,
        defaultValue: Int64
    ) -> Int64 {
        let duration = (try? values.decodeIfPresent(Int64.self, forKey: durationKey)) ?? nil
        let legacyMinutes = (try? values.decodeIfPresent(Int.self, forKey: legacyMinutesKey)) ?? nil
        if let duration {
            return normalizedDuration(duration)
        }
        if let legacyMinutes {
            return Int64(min(180, max(1, legacyMinutes))) * DurationValues.wireUnitMs
        }
        return defaultValue
    }

    private static func normalizedDuration(_ durationMs: Int64) -> Int64 {
        let clamped = min(DurationValues.validRange.upperBound, max(DurationValues.validRange.lowerBound, durationMs))
        return ((clamped + DurationValues.wireUnitMs / 2) / DurationValues.wireUnitMs) * DurationValues.wireUnitMs
    }
}

enum CommandType: String, Codable, Sendable {
    case start, pause, resume, finish, cancel, clear
}

struct TimerCommand: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let deviceSequence: Int64
    let timerId: String
    let taskId: String?
    let type: CommandType
    let phase: TimerPhase
    let plannedDurationMs: Int64
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64
    let observedElapsedMs: Int64
}

struct SyncRequest: Encodable, Sendable {
    let deviceId: String
    let lastRevision: Int64
    let commands: [TimerCommand]
    let taskOperations: [TaskOperation]
    let durationOperations: [DurationOperation]
    let autoStartOperations: [AutoStartOperation]?
}

enum BootstrapResolutionStrategy: String, Codable, Equatable, Sendable {
    case keepRemote = "keep_remote"
    case replaceRemote = "replace_remote"
    case merge

    var title: String {
        switch self {
        case .keepRemote: "Keep Remote"
        case .replaceRemote: "Keep Local"
        case .merge: "Keep Both"
        }
    }
}

struct BootstrapResolveRequest: Codable, Equatable, Sendable {
    let requestId: String
    let deviceId: String
    let expectedRevision: Int64
    let strategy: BootstrapResolutionStrategy
    let commands: [TimerCommand]
    let taskOperations: [TaskOperation]
    let durationOperations: [DurationOperation]
    let autoStartOperations: [AutoStartOperation]?
}

struct Acknowledgement: Codable, Equatable, Sendable {
    let commandId: String
    let outcome: String
    let reason: String
}

enum TaskOperationType: String, Codable, Sendable {
    case upsert, delete
}

struct TaskOperation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let taskId: String
    let type: TaskOperationType
    let title: String?
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64
}

struct TaskAcknowledgement: Codable, Equatable, Sendable {
    let operationId: String
    let outcome: String
    let reason: String
}

struct DurationOperation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let phase: TimerPhase
    let durationMs: Int64
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        DurationValues.isValidWireDuration(durationMs)
            && hlcCounter >= 0
            && ((hlcWallMs == 0 && hlcCounter == 0) || hlcWallMs > 0)
    }
}

struct DurationAcknowledgement: Codable, Equatable, Sendable {
    let operationId: String
    let outcome: String
    let reason: String
}

struct AutoStartOperation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let deviceId: String
    let enabled: Bool
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        !deviceId.isEmpty
            && hlcCounter >= 0
            && hlcWallMs > 0
    }
}

enum AcknowledgementOutcome: String, Codable, Equatable, Sendable {
    case applied, ignored, rejected
}

struct AutoStartAcknowledgement: Codable, Equatable, Sendable {
    let operationId: UUID
    let outcome: AcknowledgementOutcome
    let reason: String
}

struct ProvisionalBreak: Codable, Equatable, Sendable {
    let focusTimerId: String
    let finishCommandId: String
    let breakTimerId: String
    let startCommandId: String
}

enum AcknowledgementSet {
    static func exactlyMatches<ID: Hashable>(sent: [ID], acknowledged: [ID]) -> Bool {
        guard sent.count == acknowledged.count else { return false }
        let sentSet = Set(sent)
        let acknowledgedSet = Set(acknowledged)
        return sentSet.count == sent.count
            && acknowledgedSet.count == acknowledged.count
            && sentSet == acknowledgedSet
    }
}

struct TimerIntent: Codable, Equatable, Sendable {
    let type: CommandType
    let commandId: String
    let occurredAt: Date
    let deviceId: String?
}

struct CanonicalTimer: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case running, paused, completed, cancelled, superseded
    }

    let id: String
    let taskId: String?
    let phase: TimerPhase
    let status: Status
    let plannedDurationMs: Int64
    let elapsedAtAnchorMs: Int64
    let anchorAt: Date
    let lastIntent: TimerIntent?

    var plannedDuration: TimeInterval { TimeInterval(plannedDurationMs) / 1_000 }

    func elapsed(at date: Date) -> TimeInterval {
        let anchored = TimeInterval(elapsedAtAnchorMs) / 1_000
        guard status == .running else { return min(plannedDuration, anchored) }
        return min(plannedDuration, anchored + max(0, date.timeIntervalSince(anchorAt)))
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, plannedDuration - elapsed(at: date))
    }
}

struct HistoryItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let timerId: String
    let commandId: String?
    let taskId: String?
    let phase: TimerPhase
    let status: String
    let plannedDurationMs: Int64
    let completedAt: Date?
    let endedAt: Date?

    var date: Date? { completedAt ?? endedAt }
    var minutes: Int { max(1, Int((plannedDurationMs + 59_999) / 60_000)) }
}

struct FocusTask: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let title: String

    init?(title rawTitle: String) {
        let title = Self.normalizedTitle(rawTitle)
        guard !title.isEmpty, Data(title.utf8).count <= 512 else { return nil }
        self.id = Self.deterministicID(for: title)
        self.title = title
    }

    static func normalizedTitle(_ title: String) -> String {
        let scalars = Array(title.precomposedStringWithCanonicalMapping.unicodeScalars)
        var lowerBound = 0
        var upperBound = scalars.count
        while lowerBound < upperBound, !isPrintable(scalars[lowerBound]) {
            lowerBound += 1
        }
        while upperBound > lowerBound, !isPrintable(scalars[upperBound - 1]) {
            upperBound -= 1
        }
        return scalars[lowerBound..<upperBound].reduce(into: "") { result, scalar in
            result.unicodeScalars.append(scalar)
        }
    }

    private static func deterministicID(for title: String) -> UUID {
        let digest = SHA256.hash(data: Data("pomodorough.task.v1\0\(title)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }
}

struct LocalTaskState: Codable, Equatable, Sendable {
    var tasks: [FocusTask]
    var selectedTaskID: UUID?
    var assignments: [String: FocusTask]

    static let empty = Self(tasks: [], selectedTaskID: nil, assignments: [:])
}

struct TaskDailySummary: Identifiable, Equatable, Sendable {
    let task: FocusTask
    let finishedPomodoros: Int
    let timeSpentMs: Int64

    var id: UUID { task.id }
}

struct SyncResponse: Decodable, Sendable {
    let acknowledgements: [Acknowledgement]
    let taskAcknowledgements: [TaskAcknowledgement]
    let durationAcknowledgements: [DurationAcknowledgement]
    let autoStartAcknowledgements: [AutoStartAcknowledgement]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let revision: Int64
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let serverTime: Date
    let serverHlcWallMs: Int64
    let serverHlcCounter: Int64

    private enum CodingKeys: String, CodingKey {
        case acknowledgements, taskAcknowledgements, durationAcknowledgements, autoStartAcknowledgements
        case durationsMs, autoStartBreaks
        case revision, canonicalTimer
        case history, tasks, serverTime, serverHlcWallMs, serverHlcCounter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        acknowledgements = try values.decode([Acknowledgement].self, forKey: .acknowledgements)
        taskAcknowledgements = try values.decodeIfPresent([TaskAcknowledgement].self, forKey: .taskAcknowledgements) ?? []
        durationAcknowledgements = try values.decode([DurationAcknowledgement].self, forKey: .durationAcknowledgements)
        autoStartAcknowledgements = try values.decode([AutoStartAcknowledgement].self, forKey: .autoStartAcknowledgements)
        durationsMs = try values.decode(DurationValues.self, forKey: .durationsMs)
        autoStartBreaks = try values.decode(Bool.self, forKey: .autoStartBreaks)
        revision = try values.decode(Int64.self, forKey: .revision)
        canonicalTimer = try values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer)
        history = try values.decode([HistoryItem].self, forKey: .history)
        tasks = try values.decodeIfPresent([FocusTask].self, forKey: .tasks) ?? []
        serverTime = try values.decode(Date.self, forKey: .serverTime)
        serverHlcWallMs = try values.decode(Int64.self, forKey: .serverHlcWallMs)
        serverHlcCounter = try values.decode(Int64.self, forKey: .serverHlcCounter)
    }
}

struct BootstrapResponse: Decodable, Sendable {
    let acknowledgements: [Acknowledgement]
    let taskAcknowledgements: [TaskAcknowledgement]
    let durationAcknowledgements: [DurationAcknowledgement]
    let autoStartAcknowledgements: [AutoStartAcknowledgement]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let revision: Int64
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let serverTime: Date
    let serverHlcWallMs: Int64
    let serverHlcCounter: Int64

    private enum CodingKeys: String, CodingKey {
        case acknowledgements, taskAcknowledgements, durationAcknowledgements, autoStartAcknowledgements
        case durationsMs, autoStartBreaks
        case revision, canonicalTimer
        case history, tasks, serverTime, serverHlcWallMs, serverHlcCounter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.canonicalTimer) else {
            throw DecodingError.keyNotFound(
                CodingKeys.canonicalTimer,
                DecodingError.Context(
                    codingPath: values.codingPath,
                    debugDescription: "Bootstrap response must include canonicalTimer."
                )
            )
        }
        acknowledgements = try values.decode([Acknowledgement].self, forKey: .acknowledgements)
        taskAcknowledgements = try values.decode([TaskAcknowledgement].self, forKey: .taskAcknowledgements)
        durationAcknowledgements = try values.decode([DurationAcknowledgement].self, forKey: .durationAcknowledgements)
        autoStartAcknowledgements = try values.decode([AutoStartAcknowledgement].self, forKey: .autoStartAcknowledgements)
        durationsMs = try values.decode(DurationValues.self, forKey: .durationsMs)
        autoStartBreaks = try values.decode(Bool.self, forKey: .autoStartBreaks)
        revision = try values.decode(Int64.self, forKey: .revision)
        canonicalTimer = try values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer)
        history = try values.decode([HistoryItem].self, forKey: .history)
        tasks = try values.decode([FocusTask].self, forKey: .tasks)
        serverTime = try values.decode(Date.self, forKey: .serverTime)
        serverHlcWallMs = try values.decode(Int64.self, forKey: .serverHlcWallMs)
        serverHlcCounter = try values.decode(Int64.self, forKey: .serverHlcCounter)
    }
}

struct HistoryResponse: Decodable, Sendable { let history: [HistoryItem] }

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

struct PersistedTimerState: Codable, Equatable, Sendable {
    var deviceId: String
    var nextSequence: Int64
    var revision: Int64
    var hlcWallMs: Int64
    var hlcCounter: Int64
    var pendingCommands: [TimerCommand]
    var pendingTaskOperations: [TaskOperation]
    var pendingDurationOperations: [DurationOperation]
    var pendingAutoStartOperations: [AutoStartOperation]
    var autoStartBreaks: Bool
    var localTimerOwners: [String: String]
    var provisionalBreaks: [ProvisionalBreak]
    var canonicalTimer: CanonicalTimer?
    var history: [HistoryItem]
    var tasks: [FocusTask]
    var knownTasks: [FocusTask]
    var selectedTaskID: UUID?
    var legacyTaskAssignments: [String: UUID]
    var settings: TimerSettings
    var cachedUser: User?
    var bootstrapUser: User?
    var pendingBootstrapResolution: BootstrapResolveRequest?

    static func fresh() -> Self {
        Self(
            deviceId: "device-\(UUID().uuidString.lowercased())",
            nextSequence: 1,
            revision: 0,
            hlcWallMs: 0,
            hlcCounter: 0,
            pendingCommands: [],
            pendingTaskOperations: [],
            pendingDurationOperations: [],
            pendingAutoStartOperations: [],
            autoStartBreaks: false,
            localTimerOwners: [:],
            provisionalBreaks: [],
            canonicalTimer: nil,
            history: [],
            tasks: [],
            knownTasks: [],
            selectedTaskID: nil,
            legacyTaskAssignments: [:],
            settings: TimerSettings(),
            cachedUser: nil,
            bootstrapUser: nil,
            pendingBootstrapResolution: nil
        )
    }

    mutating func prepare(for authenticatedUser: User) {
        if let previousUser = cachedUser, previousUser.id != authenticatedUser.id {
            let existingDeviceID = deviceId
            let existingSelectedPhase = settings.selectedPhase
            self = .fresh()
            deviceId = existingDeviceID
            settings.selectedPhase = existingSelectedPhase
        }
        cachedUser = authenticatedUser
        bootstrapUser = nil
        pendingBootstrapResolution = nil
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, nextSequence, revision, hlcWallMs, hlcCounter
        case pendingCommands, pendingTaskOperations, pendingDurationOperations, pendingAutoStartOperations
        case autoStartBreaks, localTimerOwners, provisionalBreaks, canonicalTimer, history
        case tasks, knownTasks, selectedTaskID, legacyTaskAssignments, settings, cachedUser
        case bootstrapUser, pendingBootstrapResolution
    }

    init(
        deviceId: String,
        nextSequence: Int64,
        revision: Int64,
        hlcWallMs: Int64,
        hlcCounter: Int64,
        pendingCommands: [TimerCommand],
        pendingTaskOperations: [TaskOperation],
        pendingDurationOperations: [DurationOperation],
        pendingAutoStartOperations: [AutoStartOperation],
        autoStartBreaks: Bool,
        localTimerOwners: [String: String],
        provisionalBreaks: [ProvisionalBreak],
        canonicalTimer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        knownTasks: [FocusTask],
        selectedTaskID: UUID?,
        legacyTaskAssignments: [String: UUID],
        settings: TimerSettings,
        cachedUser: User?,
        bootstrapUser: User?,
        pendingBootstrapResolution: BootstrapResolveRequest?
    ) {
        self.deviceId = deviceId
        self.nextSequence = nextSequence
        self.revision = revision
        self.hlcWallMs = hlcWallMs
        self.hlcCounter = hlcCounter
        self.pendingCommands = pendingCommands
        self.pendingTaskOperations = pendingTaskOperations
        self.pendingDurationOperations = pendingDurationOperations
        self.pendingAutoStartOperations = pendingAutoStartOperations
        self.autoStartBreaks = autoStartBreaks
        self.localTimerOwners = localTimerOwners
        self.provisionalBreaks = provisionalBreaks
        self.canonicalTimer = canonicalTimer
        self.history = history
        self.tasks = tasks
        self.knownTasks = knownTasks
        self.selectedTaskID = selectedTaskID
        self.legacyTaskAssignments = legacyTaskAssignments
        self.settings = settings
        self.cachedUser = cachedUser
        self.bootstrapUser = bootstrapUser
        self.pendingBootstrapResolution = pendingBootstrapResolution
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        nextSequence = try values.decode(Int64.self, forKey: .nextSequence)
        revision = try values.decode(Int64.self, forKey: .revision)
        hlcWallMs = try values.decodeIfPresent(Int64.self, forKey: .hlcWallMs) ?? 0
        hlcCounter = try values.decodeIfPresent(Int64.self, forKey: .hlcCounter) ?? 0
        pendingCommands = try values.decode([TimerCommand].self, forKey: .pendingCommands)
        pendingTaskOperations = try values.decodeIfPresent([TaskOperation].self, forKey: .pendingTaskOperations) ?? []
        pendingDurationOperations = try values.decodeIfPresent([DurationOperation].self, forKey: .pendingDurationOperations) ?? []
        guard pendingDurationOperations.allSatisfy(\.isValid) else {
            throw DecodingError.dataCorruptedError(
                forKey: .pendingDurationOperations,
                in: values,
                debugDescription: "Pending duration operations must use minute durations and valid HLC values."
            )
        }
        let decodedAutoStartOperations = try values.decodeIfPresent(
            [LossyDecodable<AutoStartOperation>].self,
            forKey: .pendingAutoStartOperations
        )?.compactMap(\.value) ?? []
        let persistedDeviceId = deviceId
        var seenAutoStartOperationIDs = Set<UUID>()
        var validAutoStartOperations: [AutoStartOperation] = []
        for operation in decodedAutoStartOperations where operation.isValid
            && operation.deviceId == persistedDeviceId
            && seenAutoStartOperationIDs.insert(operation.id).inserted {
            validAutoStartOperations.append(operation)
        }
        pendingAutoStartOperations = validAutoStartOperations
        autoStartBreaks = try values.decodeIfPresent(Bool.self, forKey: .autoStartBreaks) ?? false
        localTimerOwners = try values.decodeIfPresent([String: String].self, forKey: .localTimerOwners) ?? [:]
        provisionalBreaks = try values.decodeIfPresent(
            [ProvisionalBreak].self,
            forKey: .provisionalBreaks
        ) ?? []
        canonicalTimer = try values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer)
        history = try values.decode([HistoryItem].self, forKey: .history)
        tasks = try values.decodeIfPresent([FocusTask].self, forKey: .tasks) ?? []
        knownTasks = try values.decodeIfPresent([FocusTask].self, forKey: .knownTasks) ?? tasks
        selectedTaskID = try values.decodeIfPresent(UUID.self, forKey: .selectedTaskID)
        legacyTaskAssignments = try values.decodeIfPresent([String: UUID].self, forKey: .legacyTaskAssignments) ?? [:]
        settings = try values.decodeIfPresent(TimerSettings.self, forKey: .settings) ?? TimerSettings()
        cachedUser = try values.decodeIfPresent(User.self, forKey: .cachedUser)
        bootstrapUser = try values.decodeIfPresent(User.self, forKey: .bootstrapUser)
        pendingBootstrapResolution = try values.decodeIfPresent(
            BootstrapResolveRequest.self,
            forKey: .pendingBootstrapResolution
        )
    }

    mutating func migrateLegacyTasks(_ legacy: LocalTaskState, at date: Date = .now) {
        mergeKnownTasks(legacy.tasks + Array(legacy.assignments.values))
        legacyTaskAssignments.merge(legacy.assignments.mapValues(\.id)) { _, migrated in migrated }
        for task in legacy.tasks where !tasks.contains(where: { $0.id == task.id }) {
            tasks.append(task)
        }
        if let selected = legacy.selectedTaskID,
           tasks.contains(where: { $0.id == selected }) {
            selectedTaskID = selected
        }

        pendingCommands = pendingCommands.map { command in
            guard command.taskId == nil,
                  command.type == .start,
                  let task = legacy.assignments[command.timerId] else { return command }
            return TimerCommand(
                id: command.id,
                deviceSequence: command.deviceSequence,
                timerId: command.timerId,
                taskId: task.id.uuidString.lowercased(),
                type: command.type,
                phase: command.phase,
                plannedDurationMs: command.plannedDurationMs,
                occurredAt: command.occurredAt,
                hlcWallMs: command.hlcWallMs,
                hlcCounter: command.hlcCounter,
                observedElapsedMs: command.observedElapsedMs
            )
        }
        if let timer = canonicalTimer,
           timer.taskId == nil,
           let task = legacy.assignments[timer.id] {
            canonicalTimer = CanonicalTimer(
                id: timer.id,
                taskId: task.id.uuidString.lowercased(),
                phase: timer.phase,
                status: timer.status,
                plannedDurationMs: timer.plannedDurationMs,
                elapsedAtAnchorMs: timer.elapsedAtAnchorMs,
                anchorAt: timer.anchorAt,
                lastIntent: timer.lastIntent
            )
        }
        history = history.map { item in
            guard item.taskId == nil,
                  let task = legacy.assignments[item.timerId] else { return item }
            return HistoryItem(
                id: item.id,
                timerId: item.timerId,
                commandId: item.commandId,
                taskId: task.id.uuidString.lowercased(),
                phase: item.phase,
                status: item.status,
                plannedDurationMs: item.plannedDurationMs,
                completedAt: item.completedAt,
                endedAt: item.endedAt
            )
        }

        for task in legacy.tasks where !pendingTaskOperations.contains(where: {
            $0.type == .upsert && UUID(uuidString: $0.taskId) == task.id
        }) {
            advanceClock(at: date)
            pendingTaskOperations.append(TaskOperation(
                id: "task-operation-\(UUID().uuidString.lowercased())",
                taskId: task.id.uuidString.lowercased(),
                type: .upsert,
                title: task.title,
                occurredAt: date,
                hlcWallMs: hlcWallMs,
                hlcCounter: hlcCounter
            ))
        }
    }

    mutating func migrateLegacyDurationSettings(at date: Date = .now) {
        for phase in TimerPhase.allCases {
            let durationMs = settings.durationMs(for: phase)
            guard durationMs != DurationValues.defaults.durationMs(for: phase) else { continue }
            pendingDurationOperations.append(DurationOperation(
                id: "duration-operation-\(UUID().uuidString.lowercased())",
                phase: phase,
                durationMs: durationMs,
                occurredAt: date,
                hlcWallMs: 0,
                hlcCounter: 0
            ))
        }
    }

    @discardableResult
    mutating func migrateLegacyAutoStartBreaks(
        explicitlySet: Bool = false,
        at date: Date = .now
    ) -> Bool {
        guard settings.autoStartBreaks || explicitlySet else { return false }
        advanceClock(at: date)
        pendingAutoStartOperations.append(AutoStartOperation(
            id: UUID(),
            deviceId: deviceId,
            enabled: settings.autoStartBreaks,
            occurredAt: date,
            hlcWallMs: hlcWallMs,
            hlcCounter: hlcCounter
        ))
        return true
    }

    @discardableResult
    mutating func migrateLegacyTimerOwnership() -> Bool {
        guard let timer = canonicalTimer,
              timer.status == .running || timer.status == .paused,
              localTimerOwners[timer.id] == nil,
              !pendingCommands.contains(where: {
                $0.type == .start && $0.timerId == timer.id
              }),
              let intent = timer.lastIntent,
              intent.type == .start,
              intent.deviceId == deviceId else { return false }
        localTimerOwners[timer.id] = deviceId
        return true
    }

    mutating func applyDurationSync(
        canonicalDurations: DurationValues,
        sentOperations: [DurationOperation],
        acknowledgements: [DurationAcknowledgement]
    ) throws {
        let sentOperationIDs = sentOperations.map(\.id)
        let acknowledgedOperationIDs = acknowledgements.map(\.operationId)
        guard canonicalDurations.isValid,
              sentOperations.allSatisfy(\.isValid),
              AcknowledgementSet.exactlyMatches(
                sent: sentOperationIDs,
                acknowledged: acknowledgedOperationIDs
              ) else {
            throw AppError.invalidResponse
        }
        let sentIDSet = Set(sentOperationIDs)
        let acknowledgedIDSet = Set(acknowledgedOperationIDs)
        pendingDurationOperations.removeAll {
            sentIDSet.contains($0.id) && acknowledgedIDSet.contains($0.id)
        }
        settings.durationsMs = DurationReducer.applying(
            pendingDurationOperations,
            to: canonicalDurations
        )
    }

    mutating func applyAutoStartSync(
        canonicalValue: Bool,
        sentOperations: [AutoStartOperation],
        acknowledgements: [AutoStartAcknowledgement]
    ) throws {
        let sentOperationIDs = sentOperations.map(\.id)
        let acknowledgedOperationIDs = acknowledgements.map(\.operationId)
        guard sentOperations.allSatisfy({ $0.isValid && $0.deviceId == deviceId }),
              AcknowledgementSet.exactlyMatches(
                sent: sentOperationIDs,
                acknowledged: acknowledgedOperationIDs
              ) else {
            throw AppError.invalidResponse
        }
        let acknowledgedIDSet = Set(acknowledgedOperationIDs)
        pendingAutoStartOperations.removeAll { acknowledgedIDSet.contains($0.id) }
        autoStartBreaks = canonicalValue
    }

    mutating func advanceClock(at date: Date) {
        let nowMs = Int64(date.timeIntervalSince1970 * 1_000)
        if nowMs > hlcWallMs {
            hlcWallMs = nowMs
            hlcCounter = 0
        } else {
            hlcCounter += 1
        }
    }

    mutating func mergeKnownTasks(_ newTasks: [FocusTask]) {
        for task in newTasks {
            if let index = knownTasks.firstIndex(where: { $0.id == task.id }) {
                knownTasks[index] = task
            } else {
                knownTasks.append(task)
            }
        }
    }
}

enum TaskReducer {
    static func applying(_ operations: [TaskOperation], to baseTasks: [FocusTask]) -> [FocusTask] {
        operations.sorted(by: precedes).reduce(into: baseTasks) { tasks, operation in
            guard let taskID = UUID(uuidString: operation.taskId) else { return }
            tasks.removeAll { $0.id == taskID }
            guard operation.type == .upsert,
                  let title = operation.title,
                  let task = FocusTask(title: title),
                  task.id == taskID else { return }
            tasks.append(task)
        }
    }

    private static func precedes(_ lhs: TaskOperation, _ rhs: TaskOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id < rhs.id
    }
}

enum DurationReducer {
    static func applying(_ operations: [DurationOperation], to base: DurationValues) -> DurationValues {
        operations.sorted(by: precedes).reduce(into: base) { durations, operation in
            guard operation.isValid else { return }
            durations.setDurationMs(operation.durationMs, for: operation.phase)
        }
    }

    private static func precedes(_ lhs: DurationOperation, _ rhs: DurationOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id < rhs.id
    }
}

enum AutoStartReducer {
    static func applying(_ operations: [AutoStartOperation], to base: Bool) -> Bool {
        operations.sorted(by: precedes).reduce(base) { enabled, operation in
            operation.isValid ? operation.enabled : enabled
        }
    }

    private static func precedes(_ lhs: AutoStartOperation, _ rhs: AutoStartOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        if lhs.deviceId != rhs.deviceId { return lhs.deviceId < rhs.deviceId }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum TimerReducer {
    static func breakPhase(afterCompletedFocusCount count: Int) -> TimerPhase {
        count > 0 && count.isMultiple(of: 4) ? .longBreak : .shortBreak
    }

    static func applying(
        _ commands: [TimerCommand],
        to canonical: CanonicalTimer?,
        history canonicalHistory: [HistoryItem]
    ) -> (timer: CanonicalTimer?, history: [HistoryItem]) {
        commands.sorted { $0.deviceSequence < $1.deviceSequence }.reduce(into: (canonical, canonicalHistory)) { result, command in
            result = apply(command, to: result.0, history: result.1)
        }
    }

    static func apply(
        _ command: TimerCommand,
        to timer: CanonicalTimer?,
        history: [HistoryItem]
    ) -> (CanonicalTimer?, [HistoryItem]) {
        let intent = TimerIntent(
            type: command.type,
            commandId: command.id,
            occurredAt: command.occurredAt,
            deviceId: nil
        )
        switch command.type {
        case .start:
            return (
                CanonicalTimer(
                    id: command.timerId,
                    taskId: command.taskId,
                    phase: command.phase,
                    status: .running,
                    plannedDurationMs: command.plannedDurationMs,
                    elapsedAtAnchorMs: 0,
                    anchorAt: command.occurredAt,
                    lastIntent: intent
                ),
                history
            )
        case .pause:
            guard let timer, timer.id == command.timerId, timer.status == .running else { return (timer, history) }
            return (updated(timer, status: .paused, elapsed: command.observedElapsedMs, at: command.occurredAt, intent: intent), history)
        case .resume:
            guard let timer, timer.id == command.timerId, timer.status == .paused else { return (timer, history) }
            return (updated(timer, status: .running, elapsed: command.observedElapsedMs, at: command.occurredAt, intent: intent), history)
        case .finish:
            guard let timer, timer.id == command.timerId, timer.status == .running || timer.status == .paused else { return (timer, history) }
            let finished = updated(timer, status: .completed, elapsed: timer.plannedDurationMs, at: command.occurredAt, intent: intent)
            guard !history.contains(where: { $0.commandId == command.id }) else { return (finished, history) }
            let item = HistoryItem(
                id: command.timerId,
                timerId: command.timerId,
                commandId: command.id,
                taskId: timer.taskId,
                phase: command.phase,
                status: "completed",
                plannedDurationMs: command.plannedDurationMs,
                completedAt: command.occurredAt,
                endedAt: nil
            )
            return (finished, [item] + history)
        case .cancel:
            guard let timer, timer.id == command.timerId, timer.status == .running || timer.status == .paused else { return (timer, history) }
            let cancelled = updated(timer, status: .cancelled, elapsed: command.observedElapsedMs, at: command.occurredAt, intent: intent)
            guard !history.contains(where: { $0.commandId == command.id }) else { return (cancelled, history) }
            let item = HistoryItem(
                id: command.timerId,
                timerId: command.timerId,
                commandId: command.id,
                taskId: timer.taskId,
                phase: command.phase,
                status: "cancelled",
                plannedDurationMs: command.plannedDurationMs,
                completedAt: nil,
                endedAt: command.occurredAt
            )
            return (cancelled, [item] + history)
        case .clear:
            guard let timer, timer.id == command.timerId, timer.status != .running, timer.status != .paused else { return (timer, history) }
            return (nil, history)
        }
    }

    private static func updated(
        _ timer: CanonicalTimer,
        status: CanonicalTimer.Status,
        elapsed: Int64,
        at date: Date,
        intent: TimerIntent
    ) -> CanonicalTimer {
        CanonicalTimer(
            id: timer.id,
            taskId: timer.taskId,
            phase: timer.phase,
            status: status,
            plannedDurationMs: timer.plannedDurationMs,
            elapsedAtAnchorMs: min(timer.plannedDurationMs, max(0, elapsed)),
            anchorAt: date,
            lastIntent: intent
        )
    }
}

enum AppError: LocalizedError {
    case configuration
    case missingPresentationAnchor
    case missingIDToken
    case unauthorized
    case conflict(String)
    case server(String)
    case historyReplacementUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .configuration: "Google Sign-In is not configured for this build."
        case .missingPresentationAnchor: "No window is available for Google Sign-In."
        case .missingIDToken: "Google did not return an identity token."
        case .unauthorized: "Session expired. Sign in again."
        case .conflict(let message): message
        case .server(let message): message
        case .historyReplacementUnavailable:
            "Keeping local history requires a server update. Your saved choice and local data remain on this device."
        case .invalidResponse: "Server returned an invalid response."
        }
    }
}
