import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum SessionState: Equatable {
        case restoring
        case localOnly
        case signedIn(User)
    }

    private let api: APIClient
    private let defaults: UserDefaults
    private let alarmScheduler: any TimerAlarmScheduling
    private var timerState: PersistedTimerState
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var alarmOperationTask: Task<Void, Never>?
    @ObservationIgnored private var syncOwnership = SyncOwnership()
    @ObservationIgnored private var sessionVerification = SessionVerification()
    @ObservationIgnored private var sessionVerificationOwner: UUID?
    @ObservationIgnored private var revisionStreamTask: Task<Void, Never>?
    @ObservationIgnored private var remotePollingTask: Task<Void, Never>?
    @ObservationIgnored private var revisionLifecycle = RevisionStreamLifecycle()
    @ObservationIgnored private var revisionHints = RevisionHintCoalescer()
    @ObservationIgnored private var completionQueuedFor: String?
    @ObservationIgnored private var sessionGeneration = 0

    private(set) var sessionState: SessionState = .restoring
    private(set) var canonicalTimer: CanonicalTimer?
    private(set) var history: [HistoryItem] = []
    private(set) var tasks: [FocusTask] = []
    private(set) var isWorking = false
    private(set) var isSyncing = false
    private(set) var isOffline = false
    private(set) var conflictMessage: String?
    private(set) var needsPermissionIntroduction = false
    var errorMessage: String?

    init(
        api: APIClient = APIClient(),
        defaults: UserDefaults = .standard,
        alarmScheduler: (any TimerAlarmScheduling)? = nil
    ) {
        self.api = api
        self.defaults = defaults
        self.alarmScheduler = alarmScheduler ?? TimerAlarmScheduler()
        let storedData = defaults.data(forKey: Self.storageKey) ?? defaults.data(forKey: "timer-state")
        let migratedLegacyDurations: Bool
        if let data = storedData,
           let state = try? JSONDecoder.api.decode(PersistedTimerState.self, from: data) {
            timerState = state
            migratedLegacyDurations = !Self.hasPersistedDurationOperations(in: data)
            if migratedLegacyDurations {
                timerState.migrateLegacyDurationSettings()
            }
        } else {
            timerState = .fresh()
            migratedLegacyDurations = false
        }
        let migratedLegacyTasks: Bool
        if let data = defaults.data(forKey: Self.localTaskStorageKey),
           let state = try? JSONDecoder.api.decode(LocalTaskState.self, from: data) {
            timerState.migrateLegacyTasks(state)
            defaults.removeObject(forKey: Self.localTaskStorageKey)
            migratedLegacyTasks = true
        } else {
            migratedLegacyTasks = false
        }
#if os(iOS)
        needsPermissionIntroduction = !defaults.bool(forKey: Self.permissionIntroductionKey)
#endif
        rebuildOptimisticState()
        if migratedLegacyTasks || migratedLegacyDurations { persist() }
    }

    deinit {
        retryTask?.cancel()
        alarmOperationTask?.cancel()
        revisionStreamTask?.cancel()
        remotePollingTask?.cancel()
    }

    var isSignedIn: Bool {
        if case .signedIn = sessionState { true } else { false }
    }

    var user: User? {
        if case .signedIn(let user) = sessionState { user } else { nil }
    }

    var selectedPhase: TimerPhase {
        get { timerState.settings.selectedPhase }
        set {
            guard !isTimerActive else { return }
            timerState.settings.selectedPhase = newValue
            persist()
        }
    }

    var selectedTaskID: UUID? {
        get { timerState.selectedTaskID }
        set {
            guard !isTimerActive,
                  newValue == nil || tasks.contains(where: { $0.id == newValue }) else { return }
            timerState.selectedTaskID = newValue
            persist()
        }
    }

    var autoStartBreaks: Bool {
        get { timerState.settings.autoStartBreaks }
        set {
            timerState.settings.autoStartBreaks = newValue
            persist()
        }
    }

    var isTimerActive: Bool {
        canonicalTimer?.status == .running || canonicalTimer?.status == .paused
    }

    var activeTimer: CanonicalTimer? {
        isTimerActive ? canonicalTimer : nil
    }

    var pendingCommandCount: Int { timerState.pendingCommands.count }
    var pendingDurationOperationCount: Int { timerState.pendingDurationOperations.count }
    var pendingChangeCount: Int {
        pendingCommandCount + timerState.pendingTaskOperations.count + pendingDurationOperationCount
    }
    var completedFocusCount: Int { history.count { $0.status == "completed" && $0.phase == .focus } }
    var deviceMark: String { String(timerState.deviceId.suffix(4)).uppercased() }

    var syncLabel: String {
        if !isSignedIn { return "On device" }
        if conflictMessage != nil { return "Review conflict" }
        if pendingChangeCount > 0 { return "\(pendingChangeCount) queued" }
        if isOffline { return "Offline" }
        if isSyncing { return "Syncing" }
        return "In sync"
    }

    func durationMinutes(for phase: TimerPhase) -> Int { timerState.settings.minutes(for: phase) }

    func selectPhase(_ phase: TimerPhase) {
        guard !isTimerActive else { return }
        clearInactiveTimerForConfigurationChange()
        selectedPhase = phase
    }

    func setDurationMinutes(_ minutes: Int, for phase: TimerPhase) {
        let clamped = min(180, max(1, minutes))
        let durationMs = Int64(clamped) * 60_000
        guard timerState.settings.durationMs(for: phase) != durationMs else { return }
        clearInactiveTimerForConfigurationChange()
        let now = Date.now
        timerState.advanceClock(at: now)
        timerState.pendingDurationOperations.removeAll { $0.phase == phase }
        timerState.pendingDurationOperations.append(DurationOperation(
            id: "duration-operation-\(UUID().uuidString.lowercased())",
            phase: phase,
            durationMs: durationMs,
            occurredAt: now,
            hlcWallMs: timerState.hlcWallMs,
            hlcCounter: timerState.hlcCounter
        ))
        timerState.settings.setMinutes(clamped, for: phase)
        persist()
        Task { await sync() }
    }

    @discardableResult
    func addTask(_ title: String) -> Bool {
        guard let task = FocusTask(title: title) else { return false }
        guard !tasks.contains(where: { $0.id == task.id }) else { return true }
        timerState.mergeKnownTasks([task])
        enqueueTaskOperation(.upsert, task: task)
        return true
    }

    func deleteTask(id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if timerState.selectedTaskID == id { timerState.selectedTaskID = nil }
        enqueueTaskOperation(.delete, task: task)
    }

    func task(forTimerID timerID: String) -> FocusTask? {
        let taskID = canonicalTimer.flatMap { $0.id == timerID ? $0.taskId : nil }
            ?? history.first(where: { $0.timerId == timerID })?.taskId
            ?? timerState.pendingCommands.first(where: { $0.timerId == timerID && $0.type == .start })?.taskId
        let uuid = taskID.flatMap(UUID.init(uuidString:)) ?? timerState.legacyTaskAssignments[timerID]
        guard let uuid else { return nil }
        return tasks.first(where: { $0.id == uuid })
            ?? timerState.knownTasks.first(where: { $0.id == uuid })
    }

    func taskSummaries(for date: Date = .now, calendar: Calendar = .current) -> [TaskDailySummary] {
        var totals: [UUID: (finished: Int, timeMs: Int64)] = [:]
        for item in history {
            guard item.phase == .focus,
                  item.status == "completed",
                  let completedAt = item.completedAt,
                  calendar.isDate(completedAt, inSameDayAs: date),
                  let uuid = item.taskId.flatMap(UUID.init(uuidString:))
                    ?? timerState.legacyTaskAssignments[item.timerId] else { continue }
            let current = totals[uuid] ?? (0, 0)
            totals[uuid] = (current.finished + 1, current.timeMs + item.plannedDurationMs)
        }
        return tasks.map { task in
            let total = totals[task.id] ?? (0, 0)
            return TaskDailySummary(
                task: task,
                finishedPomodoros: total.finished,
                timeSpentMs: total.timeMs
            )
        }
    }

    func restore() async {
        guard sessionState == .restoring else { return }
        let generation = sessionGeneration
        do {
            guard try await api.restoreTokens() else {
                guard generation == sessionGeneration else { return }
                sessionState = .localOnly
                return
            }
            guard generation == sessionGeneration else { return }
            guard let cachedUser = timerState.cachedUser else {
                sessionGeneration += 1
                sessionVerification.invalidate()
                syncOwnership.invalidate()
                sessionState = .localOnly
                try? await api.clearTokens()
                return
            }
            sessionState = .signedIn(cachedUser)
            await verifyRestoredSession(generation: generation)
        } catch AppError.unauthorized {
            await invalidateUnauthorizedSession(generation: generation)
        } catch {
            guard generation == sessionGeneration else { return }
            sessionState = .localOnly
        }
    }

    func allowTimerAlerts() async {
        try? await alarmScheduler.requestAuthorization()
        completePermissionIntroduction()
    }

    func skipTimerAlertPermissions() {
        completePermissionIntroduction()
    }

    func signIn() {
        guard !isWorking else { return }
        sessionGeneration += 1
        let generation = sessionGeneration
        sessionVerification.invalidate()
        sessionVerificationOwner = nil
        syncOwnership.invalidate()
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        isWorking = true
        errorMessage = nil
        Task {
            defer {
                if generation == sessionGeneration { isWorking = false }
            }
            do {
                let challenge = try await api.challenge()
                let idToken = try await GoogleAuthService.identityToken(nonce: challenge.nonce)
                let me = try await api.exchange(
                    NativeExchangeRequest(
                        idToken: idToken,
                        challenge: challenge.challenge,
                        deviceId: timerState.deviceId,
                        platform: Self.platform
                    )
                )
                guard generation == sessionGeneration else { return }
                timerState.prepare(for: me.user)
                rebuildOptimisticState()
                sessionVerification.markVerified(generation: generation)
                sessionState = .signedIn(me.user)
                isOffline = false
                persist()
                await sync(force: true)
            } catch {
                guard generation == sessionGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func signOut() {
        guard !isWorking else { return }
        if let timer = canonicalTimer {
            cancelAlarm(timerID: timer.id)
        }
        sessionGeneration += 1
        sessionState = .localOnly
        isOffline = false
        sessionVerification.invalidate()
        sessionVerificationOwner = nil
        syncOwnership.invalidate()
        isSyncing = false
        revisionHints = RevisionHintCoalescer()
        isWorking = true
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        GoogleAuthService.signOut()
        timerState = .fresh()
        rebuildOptimisticState()
        persist()

        Task {
            defer { isWorking = false }
            do { try await api.logout() } catch { try? await api.clearTokens() }
        }
    }

    func start() {
        let timerID = "timer-\(UUID().uuidString.lowercased())"
        let phase = selectedPhase
        let duration = TimeInterval(timerState.settings.durationMs(for: phase)) / 1_000
        let shouldScheduleAlarm = !isTimerActive
        let taskID = phase == .focus
            ? timerState.selectedTaskID.flatMap { selected in
                tasks.first(where: { $0.id == selected })?.id.uuidString.lowercased()
            }
            : nil
        enqueue(
            .start,
            timerID: timerID,
            taskID: taskID,
            phase: phase,
            duration: duration,
            elapsed: 0
        )
        guard shouldScheduleAlarm else { return }
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.schedule(timerID: timerID, phase: phase, duration: duration)
        }
    }

    func pause(at date: Date = .now) {
        guard let timer = canonicalTimer else { return }
        enqueue(.pause, timer: timer, elapsed: timer.elapsed(at: date))
        guard timer.status == .running else { return }
        enqueueAlarmOperation { [alarmScheduler] in
            try alarmScheduler.pause(timerID: timer.id)
        }
    }

    func resume(at date: Date = .now) {
        guard let timer = canonicalTimer else { return }
        let remainingDuration = max(1, timer.remaining(at: date))
        enqueue(.resume, timer: timer, elapsed: timer.elapsed(at: date))
        guard timer.status == .paused else { return }
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.resume(
                timerID: timer.id,
                phase: timer.phase,
                duration: remainingDuration
            )
        }
    }

    func finish(at date: Date = .now) {
        finish(at: date, cancelsAlarm: true)
    }

    private func finish(at date: Date, cancelsAlarm: Bool) {
        guard let timer = canonicalTimer else { return }
        let finishedPhase = timer.phase
        enqueue(.finish, timer: timer, elapsed: timer.elapsed(at: date))
        if cancelsAlarm, timer.status == .running || timer.status == .paused {
            cancelAlarm(timerID: timer.id)
        }
        guard finishedPhase == .focus, autoStartBreaks else { return }
        selectedPhase = nextBreakPhase()
        start()
    }

    func cancel(at date: Date = .now) {
        guard let timer = canonicalTimer else { return }
        enqueue(.cancel, timer: timer, elapsed: timer.elapsed(at: date))
        if timer.status == .running || timer.status == .paused {
            cancelAlarm(timerID: timer.id)
        }
    }

    func clear() {
        guard let timer = canonicalTimer, !isTimerActive else { return }
        enqueue(.clear, timer: timer, elapsed: timer.elapsed(at: .now))
        cancelAlarm(timerID: timer.id, reportsError: false)
    }

    func completeIfNeeded(timerID: String, at date: Date) {
        guard let timer = canonicalTimer,
              timer.id == timerID,
              timer.status == .running,
              timer.remaining(at: date) <= 0,
              completionQueuedFor != timer.id else { return }
        completionQueuedFor = timer.id
        finish(at: date, cancelsAlarm: false)
    }

    func waitForAlarmOperations() async {
        await alarmOperationTask?.value
    }

    func dismissConflict() { conflictMessage = nil }

    func sync(force: Bool = false, showsActivity: Bool = true) async {
        guard isSignedIn else { return }
        let generation = sessionGeneration
        guard sessionVerification.allows(generation: generation) else {
            await verifyRestoredSession(generation: generation)
            return
        }
        if !force,
           timerState.pendingCommands.isEmpty,
           timerState.pendingTaskOperations.isEmpty,
           timerState.pendingDurationOperations.isEmpty { return }
        guard let syncID = syncOwnership.begin(generation: generation) else { return }
        var allowsFollowUpSync = true
        retryTask?.cancel()
        if showsActivity { isSyncing = true }
        defer {
            if let requestedFollowUp = syncOwnership.finish(syncID, currentGeneration: sessionGeneration) {
                if showsActivity { isSyncing = false }
                let hintedFollowUp = revisionHints.consumeFollowUp(localRevision: timerState.revision)
                if allowsFollowUpSync,
                   isSignedIn,
                   (requestedFollowUp || (generation == sessionGeneration && hintedFollowUp)) {
                    Task { [weak self] in await self?.sync(force: true) }
                }
            }
        }
        do {
            repeat {
                let batch = Array(timerState.pendingCommands.prefix(256))
                let taskBatch = Array(timerState.pendingTaskOperations.prefix(256))
                let durationBatch = Array(timerState.pendingDurationOperations.prefix(256))
                guard durationBatch.allSatisfy(\.isValid) else { throw AppError.invalidResponse }
                let response = try await api.sync(
                    SyncRequest(
                        deviceId: timerState.deviceId,
                        lastRevision: timerState.revision,
                        commands: batch,
                        taskOperations: taskBatch,
                        durationOperations: durationBatch
                    )
                )
                guard generation == sessionGeneration, isSignedIn else { return }

                let sentIDs = batch.map(\.id)
                let acknowledgedIDs = response.acknowledgements.map(\.commandId)
                guard AcknowledgementSet.exactlyMatches(sent: sentIDs, acknowledged: acknowledgedIDs) else {
                    throw AppError.invalidResponse
                }
                let sentTaskIDs = taskBatch.map(\.id)
                let acknowledgedTaskIDs = response.taskAcknowledgements.map(\.operationId)
                guard AcknowledgementSet.exactlyMatches(sent: sentTaskIDs, acknowledged: acknowledgedTaskIDs) else {
                    throw AppError.invalidResponse
                }
                try timerState.applyDurationSync(
                    canonicalDurations: response.durationsMs,
                    sentOperations: durationBatch,
                    acknowledgements: response.durationAcknowledgements
                )
                let acknowledgedIDSet = Set(acknowledgedIDs)
                let acknowledgedTaskIDSet = Set(acknowledgedTaskIDs)
                timerState.pendingCommands.removeAll { acknowledgedIDSet.contains($0.id) }
                timerState.pendingTaskOperations.removeAll { acknowledgedTaskIDSet.contains($0.id) }
                if let conflict = response.acknowledgements.first(where: { $0.outcome != "applied" }) {
                    conflictMessage = conflict.reason.isEmpty ? "Server resolved a timer action as \(conflict.outcome)." : conflict.reason
                } else if let conflict = response.taskAcknowledgements.first(where: { $0.outcome != "applied" }) {
                    conflictMessage = conflict.reason.isEmpty ? "Server resolved a task change as \(conflict.outcome)." : conflict.reason
                } else if let conflict = response.durationAcknowledgements.first(where: { $0.outcome != "applied" }) {
                    conflictMessage = conflict.reason.isEmpty ? "Server resolved a duration change as \(conflict.outcome)." : conflict.reason
                }
                timerState.revision = response.revision
                timerState.canonicalTimer = response.canonicalTimer
                timerState.history = response.history
                timerState.tasks = response.tasks
                timerState.mergeKnownTasks(response.tasks)
                mergeServerClock(response.serverHlcWallMs, response.serverHlcCounter)
                rebuildOptimisticState()
                isOffline = false
                errorMessage = nil
                persist()
            } while !timerState.pendingCommands.isEmpty
                || !timerState.pendingTaskOperations.isEmpty
                || !timerState.pendingDurationOperations.isEmpty
            startRevisionStream()
            startRemotePolling()
        } catch AppError.unauthorized {
            await invalidateUnauthorizedSession(generation: generation)
        } catch AppError.invalidResponse {
            guard generation == sessionGeneration, isSignedIn else { return }
            allowsFollowUpSync = false
            isOffline = false
            errorMessage = "Sync paused because the server response did not match queued changes. \(pendingChangeCount) queued changes remain on this device."
            cancelRevisionStream()
        } catch {
            guard generation == sessionGeneration, isSignedIn else { return }
            isOffline = true
            scheduleRetry()
        }
    }

    func refreshAfterForeground() async {
        guard isSignedIn else { return }
        completionQueuedFor = nil
        startRevisionStream()
        startRemotePolling()
        await sync(force: true)
    }

    func setSceneActive(_ active: Bool) {
        revisionLifecycle.setActive(active)
        if !active {
            revisionStreamTask?.cancel()
            revisionStreamTask = nil
            remotePollingTask?.cancel()
            remotePollingTask = nil
        }
    }

    private func cancelRevisionStream() {
        revisionLifecycle.cancelCurrent()
        revisionStreamTask?.cancel()
        revisionStreamTask = nil
        remotePollingTask?.cancel()
        remotePollingTask = nil
    }

    func nextBreakPhase() -> TimerPhase {
        TimerReducer.breakPhase(afterCompletedFocusCount: completedFocusCount)
    }

    private func enqueue(_ type: CommandType, timer: CanonicalTimer, elapsed: TimeInterval) {
        enqueue(
            type,
            timerID: timer.id,
            taskID: nil,
            phase: timer.phase,
            duration: timer.plannedDuration,
            elapsed: elapsed
        )
    }

    private func enqueue(
        _ type: CommandType,
        timerID: String,
        taskID: String?,
        phase: TimerPhase,
        duration: TimeInterval,
        elapsed: TimeInterval
    ) {
        let now = Date.now
        timerState.advanceClock(at: now)
        let command = TimerCommand(
            id: "command-\(UUID().uuidString.lowercased())",
            deviceSequence: timerState.nextSequence,
            timerId: timerID,
            taskId: type == .start ? taskID : nil,
            type: type,
            phase: phase,
            plannedDurationMs: Int64(duration * 1_000),
            occurredAt: now,
            hlcWallMs: timerState.hlcWallMs,
            hlcCounter: timerState.hlcCounter,
            observedElapsedMs: Int64(max(0, elapsed) * 1_000)
        )
        timerState.nextSequence += 1
        timerState.pendingCommands.append(command)
        rebuildOptimisticState()
        persist()
        Task { await sync() }
    }

    private func enqueueTaskOperation(_ type: TaskOperationType, task: FocusTask) {
        let now = Date.now
        timerState.advanceClock(at: now)
        timerState.pendingTaskOperations.append(TaskOperation(
            id: "task-operation-\(UUID().uuidString.lowercased())",
            taskId: task.id.uuidString.lowercased(),
            type: type,
            title: type == .upsert ? task.title : nil,
            occurredAt: now,
            hlcWallMs: timerState.hlcWallMs,
            hlcCounter: timerState.hlcCounter
        ))
        rebuildOptimisticState()
        persist()
        Task { await sync() }
    }

    private func cancelAlarm(timerID: String, reportsError: Bool = true) {
        enqueueAlarmOperation(reportsError: reportsError) { [alarmScheduler] in
            try alarmScheduler.cancel(timerID: timerID)
        }
    }

    private func clearInactiveTimerForConfigurationChange() {
        guard canonicalTimer != nil, !isTimerActive else { return }
        clear()
    }

    private func completePermissionIntroduction() {
        defaults.set(true, forKey: Self.permissionIntroductionKey)
        needsPermissionIntroduction = false
    }

    private func enqueueAlarmOperation(
        reportsError: Bool = true,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        let previousOperation = alarmOperationTask
        alarmOperationTask = Task { [weak self] in
            await previousOperation?.value
            guard !Task.isCancelled else { return }
            do {
                try await operation()
            } catch {
                if reportsError {
                    self?.errorMessage = "Timer continues in Pomodorough, but its system alarm could not be updated. \(error.localizedDescription)"
                }
            }
        }
    }

    private func rebuildOptimisticState() {
        let result = TimerReducer.applying(
            timerState.pendingCommands,
            to: timerState.canonicalTimer,
            history: timerState.history
        )
        canonicalTimer = result.timer
        history = result.history
        for operation in timerState.pendingTaskOperations where operation.type == .upsert {
            if let title = operation.title, let task = FocusTask(title: title) {
                timerState.mergeKnownTasks([task])
            }
        }
        tasks = TaskReducer.applying(timerState.pendingTaskOperations, to: timerState.tasks)
        timerState.settings.durationsMs = DurationReducer.applying(
            timerState.pendingDurationOperations,
            to: timerState.settings.durationsMs
        )
        if let selected = timerState.selectedTaskID,
           !tasks.contains(where: { $0.id == selected }) {
            timerState.selectedTaskID = nil
        }
        if canonicalTimer?.status != .running { completionQueuedFor = nil }
    }

    private func mergeServerClock(_ serverWallMs: Int64, _ serverCounter: Int64) {
        let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
        let candidates = [
            (wallMs: nowMs, counter: Int64(0)),
            (wallMs: timerState.hlcWallMs, counter: timerState.hlcCounter),
            (wallMs: serverWallMs, counter: serverCounter)
        ]
        let merged = candidates.max {
            $0.wallMs != $1.wallMs ? $0.wallMs < $1.wallMs : $0.counter < $1.counter
        }!
        timerState.hlcWallMs = merged.wallMs
        timerState.hlcCounter = merged.counter
    }

    private func verifyRestoredSession(generation: Int) async {
        guard generation == sessionGeneration,
              isSignedIn,
              !sessionVerification.allows(generation: generation),
              timerState.cachedUser != nil,
              sessionVerificationOwner == nil else { return }
        let owner = UUID()
        sessionVerificationOwner = owner
        defer {
            if sessionVerificationOwner == owner { sessionVerificationOwner = nil }
        }
        do {
            let response = try await api.me()
            guard generation == sessionGeneration,
                  isSignedIn,
                  sessionVerificationOwner == owner else { return }
            timerState.prepare(for: response.user)
            rebuildOptimisticState()
            sessionVerification.markVerified(generation: generation)
            sessionState = .signedIn(response.user)
            isOffline = false
            persist()
            await sync(force: true)
        } catch AppError.unauthorized {
            await invalidateUnauthorizedSession(generation: generation)
        } catch {
            guard generation == sessionGeneration,
                  isSignedIn,
                  sessionVerificationOwner == owner else { return }
            isOffline = true
            scheduleRetry()
        }
    }

    private func invalidateUnauthorizedSession(generation: Int) async {
        guard generation == sessionGeneration else { return }
        sessionGeneration += 1
        sessionVerification.invalidate()
        sessionVerificationOwner = nil
        syncOwnership.invalidate()
        isSyncing = false
        revisionHints = RevisionHintCoalescer()
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        sessionState = .localOnly
        isOffline = false
        errorMessage = AppError.unauthorized.localizedDescription
        try? await api.clearTokens()
    }

    private func scheduleRetry() {
        guard retryTask == nil || retryTask?.isCancelled == true else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            await self.sync(force: true)
        }
    }

    private func startRemotePolling() {
        guard isSignedIn,
              sessionVerification.allows(generation: sessionGeneration),
              revisionLifecycle.isActive,
              remotePollingTask == nil else { return }
        let generation = sessionGeneration
        remotePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      generation == self.sessionGeneration,
                      self.isSignedIn,
                      self.revisionLifecycle.isActive else { return }
                let interval = RemotePolling.interval(isTimerActive: self.isTimerActive)
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      generation == self.sessionGeneration,
                      self.isSignedIn,
                      self.revisionLifecycle.isActive else { return }
                await self.sync(force: true, showsActivity: false)
            }
        }
    }

    private func startRevisionStream() {
        guard isSignedIn,
              sessionVerification.allows(generation: sessionGeneration),
              let streamID = revisionLifecycle.begin() else { return }
        let generation = sessionGeneration
        revisionStreamTask = Task { [weak self] in
            var retryDelay = 1.0
            while !Task.isCancelled {
                guard let self,
                      generation == self.sessionGeneration,
                      self.isSignedIn,
                      self.revisionLifecycle.owns(streamID) else { return }
                do {
                    let events = try await self.api.revisionEvents()
                    for try await revision in events {
                        guard !Task.isCancelled,
                              generation == self.sessionGeneration,
                              self.isSignedIn,
                              self.revisionLifecycle.owns(streamID) else { return }
                        retryDelay = 1
                        await self.receiveRevisionHint(revision)
                    }
                } catch is CancellationError {
                    return
                } catch AppError.unauthorized {
                    guard !Task.isCancelled,
                          generation == self.sessionGeneration,
                          self.isSignedIn,
                          self.revisionLifecycle.owns(streamID) else { return }
                    await self.invalidateUnauthorizedSession(generation: generation)
                    return
                } catch {
                    guard !Task.isCancelled, self.revisionLifecycle.owns(streamID) else { return }
                    // The stream is advisory. Its initial event catches up missed revisions after reconnecting.
                }

                do {
                    try await Task.sleep(for: .seconds(retryDelay))
                } catch {
                    return
                }
                retryDelay = min(retryDelay * 2, 30)
            }
        }
    }

    private func receiveRevisionHint(_ revision: Int64) async {
        if revisionHints.receive(revision, localRevision: timerState.revision, isSyncing: isSyncing) {
            await sync(force: true)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder.api.encode(timerState) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static let storageKey = "timer-state-v2"
    private static let localTaskStorageKey = "local-tasks-v1"
    private static let permissionIntroductionKey = "permission-introduction-completed-v1"

    private static func hasPersistedDurationOperations(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object.keys.contains("pendingDurationOperations")
    }

    private static var platform: String {
#if os(iOS)
        "ios"
#else
        "macos"
#endif
    }
}
