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

    enum HistoryResolutionState: Equatable {
        case none
        case preflighting
        case choosing
        case confirming(BootstrapResolutionStrategy)
        case submitting(BootstrapResolutionStrategy)
        case retryable(BootstrapResolutionStrategy?)
    }

    private let api: APIClient
    private let defaults: UserDefaults
    private let alarmScheduler: any TimerAlarmScheduling
    private let retryDelay: Duration
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
    @ObservationIgnored private var bootstrapSnapshot: BootstrapResponse?

    private(set) var sessionState: SessionState = .restoring
    private(set) var canonicalTimer: CanonicalTimer?
    private(set) var history: [HistoryItem] = []
    private(set) var tasks: [FocusTask] = []
    private(set) var isWorking = false
    private(set) var isSyncing = false
    private(set) var isOffline = false
    private(set) var conflictMessage: String?
    private(set) var historyResolutionState: HistoryResolutionState = .none
    private(set) var localHistoryResolutionCount = 0
    private(set) var remoteHistoryResolutionCount = 0
    private(set) var needsPermissionIntroduction = false
    var errorMessage: String?

    init(
        api: APIClient = APIClient(),
        defaults: UserDefaults = .standard,
        alarmScheduler: (any TimerAlarmScheduling)? = nil,
        retryDelay: Duration = .seconds(5)
    ) {
        self.api = api
        self.defaults = defaults
        self.alarmScheduler = alarmScheduler ?? TimerAlarmScheduler()
        self.retryDelay = retryDelay
        let storedData = defaults.data(forKey: Self.storageKey) ?? defaults.data(forKey: "timer-state")
        let migratedLegacyDurations: Bool
        let migratedLegacyAutoStartBreaks: Bool
        let migratedLegacyTimerOwnership: Bool
        if let data = storedData,
           let state = try? JSONDecoder.api.decode(PersistedTimerState.self, from: data) {
            timerState = state
            migratedLegacyDurations = !Self.hasPersistedDurationOperations(in: data)
            if migratedLegacyDurations {
                timerState.migrateLegacyDurationSettings()
            }
            migratedLegacyAutoStartBreaks = !Self.hasPersistedAutoStartOperations(in: data)
            if migratedLegacyAutoStartBreaks {
                timerState.migrateLegacyAutoStartBreaks(
                    explicitlySet: Self.hasExplicitLegacyAutoStartBreaks(in: data)
                )
            }
            migratedLegacyTimerOwnership = timerState.migrateLegacyTimerOwnership()
        } else {
            timerState = .fresh()
            migratedLegacyDurations = false
            migratedLegacyAutoStartBreaks = false
            migratedLegacyTimerOwnership = false
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
        if let request = timerState.pendingBootstrapResolution {
            historyResolutionState = .retryable(request.strategy)
        } else if timerState.bootstrapUser != nil {
            historyResolutionState = .retryable(nil)
        }
        if migratedLegacyTasks
            || migratedLegacyDurations
            || migratedLegacyAutoStartBreaks
            || migratedLegacyTimerOwnership {
            persist()
        }
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
            guard !isTimerActive, !isHistoryResolutionBlocking else { return }
            timerState.settings.selectedPhase = newValue
            persist()
        }
    }

    var selectedTaskID: UUID? {
        get { timerState.selectedTaskID }
        set {
            guard !isTimerActive, !isHistoryResolutionBlocking,
                  newValue == nil || tasks.contains(where: { $0.id == newValue }) else { return }
            timerState.selectedTaskID = newValue
            persist()
        }
    }

    var autoStartBreaks: Bool {
        get {
            AutoStartReducer.applying(
                timerState.pendingAutoStartOperations,
                to: timerState.autoStartBreaks
            )
        }
        set {
            guard !isHistoryResolutionBlocking, newValue != autoStartBreaks else { return }
            let now = Date.now
            timerState.advanceClock(at: now)
            timerState.pendingAutoStartOperations.append(AutoStartOperation(
                id: UUID(),
                deviceId: timerState.deviceId,
                enabled: newValue,
                occurredAt: now,
                hlcWallMs: timerState.hlcWallMs,
                hlcCounter: timerState.hlcCounter
            ))
            persist()
            Task { await sync() }
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
    var pendingAutoStartOperationCount: Int { timerState.pendingAutoStartOperations.count }
    var pendingChangeCount: Int {
        pendingCommandCount
            + timerState.pendingTaskOperations.count
            + pendingDurationOperationCount
            + pendingAutoStartOperationCount
    }
    var isHistoryResolutionBlocking: Bool {
        historyResolutionState != .none
            || timerState.bootstrapUser != nil
            || timerState.pendingBootstrapResolution != nil
    }
    var completedFocusCount: Int { history.count { $0.status == "completed" && $0.phase == .focus } }
    var deviceMark: String { String(timerState.deviceId.suffix(4)).uppercased() }

    var syncLabel: String {
        if !isSignedIn { return "On device" }
        if isHistoryResolutionBlocking {
            switch historyResolutionState {
            case .preflighting: return "Checking history"
            case .choosing, .confirming: return "Choose history"
            case .submitting: return "Resolving history"
            case .retryable: return "History retry needed"
            case .none: break
            }
        }
        if conflictMessage != nil { return "Review conflict" }
        if pendingChangeCount > 0 { return "\(pendingChangeCount) queued" }
        if isOffline { return "Offline" }
        if isSyncing { return "Syncing" }
        return "In sync"
    }

    func durationMinutes(for phase: TimerPhase) -> Int { timerState.settings.minutes(for: phase) }

    func selectPhase(_ phase: TimerPhase) {
        guard !isTimerActive, !isHistoryResolutionBlocking else { return }
        clearInactiveTimerForConfigurationChange()
        selectedPhase = phase
    }

    func setDurationMinutes(_ minutes: Int, for phase: TimerPhase) {
        guard !isHistoryResolutionBlocking else { return }
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
        guard !isHistoryResolutionBlocking else { return false }
        guard let task = FocusTask(title: title) else { return false }
        guard !tasks.contains(where: { $0.id == task.id }) else { return true }
        timerState.mergeKnownTasks([task])
        enqueueTaskOperation(.upsert, task: task)
        return true
    }

    func deleteTask(id: UUID) {
        guard !isHistoryResolutionBlocking else { return }
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
            guard let cachedUser = timerState.cachedUser ?? timerState.bootstrapUser else {
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
                sessionVerification.markVerified(generation: generation)
                sessionState = .signedIn(me.user)
                isOffline = false
                await completeAuthenticatedSession(user: me.user, generation: generation)
            } catch {
                guard generation == sessionGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func signOut() {
        guard !isWorking else { return }
        let preservesBootstrapResolution = timerState.cachedUser == nil && timerState.bootstrapUser != nil
        if !preservesBootstrapResolution, let timer = canonicalTimer {
            cancelAlarm(timerID: timer.id)
        }
        sessionGeneration += 1
        sessionState = .localOnly
        isOffline = false
        sessionVerification.invalidate()
        sessionVerificationOwner = nil
        syncOwnership.invalidate()
        isSyncing = false
        historyResolutionState = preservesBootstrapResolution
            ? .retryable(timerState.pendingBootstrapResolution?.strategy)
            : .none
        bootstrapSnapshot = nil
        localHistoryResolutionCount = 0
        remoteHistoryResolutionCount = 0
        revisionHints = RevisionHintCoalescer()
        isWorking = true
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        GoogleAuthService.signOut()
        if preservesBootstrapResolution {
            persist()
        } else {
            timerState = .fresh()
            rebuildOptimisticState()
            persist()
        }

        Task {
            defer { isWorking = false }
            do { try await api.logout() } catch { try? await api.clearTokens() }
        }
    }

    func start() {
        guard !isHistoryResolutionBlocking, !isTimerActive else { return }
        let timerID = "timer-\(UUID().uuidString.lowercased())"
        let phase = selectedPhase
        let duration = TimeInterval(timerState.settings.durationMs(for: phase)) / 1_000
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
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.schedule(timerID: timerID, phase: phase, duration: duration)
        }
    }

    func pause(at date: Date = .now) {
        guard !isHistoryResolutionBlocking else { return }
        guard let timer = canonicalTimer, timer.status == .running else { return }
        enqueue(.pause, timer: timer, elapsed: timer.elapsed(at: date))
        enqueueAlarmOperation { [alarmScheduler] in
            try alarmScheduler.pause(timerID: timer.id)
        }
    }

    func resume(at date: Date = .now) {
        guard !isHistoryResolutionBlocking else { return }
        guard let timer = canonicalTimer, timer.status == .paused else { return }
        let remainingDuration = max(1, timer.remaining(at: date))
        enqueue(.resume, timer: timer, elapsed: timer.elapsed(at: date))
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.resume(
                timerID: timer.id,
                phase: timer.phase,
                duration: remainingDuration
            )
        }
    }

    func finish(at date: Date = .now) {
        guard !isHistoryResolutionBlocking else { return }
        finish(at: date, cancelsAlarm: true)
    }

    private func finish(at date: Date, cancelsAlarm: Bool) {
        guard !isHistoryResolutionBlocking else { return }
        guard let timer = canonicalTimer,
              timer.status == .running || timer.status == .paused else { return }
        guard timer.phase == .focus, autoStartBreaks else {
            enqueue(.finish, timer: timer, elapsed: timer.elapsed(at: date))
            if cancelsAlarm {
                cancelAlarm(timerID: timer.id)
            }
            return
        }

        let finishCommand = appendCommand(.finish, timer: timer, elapsed: timer.elapsed(at: date))
        let projected = TimerReducer.applying(
            timerState.pendingCommands,
            to: timerState.canonicalTimer,
            history: timerState.history
        )
        let completedFocusCount = projected.history.count {
            $0.status == CanonicalTimer.Status.completed.rawValue && $0.phase == .focus
        }
        let breakPhase = TimerReducer.breakPhase(afterCompletedFocusCount: completedFocusCount)
        let breakTimerID = "timer-\(UUID().uuidString.lowercased())"
        let breakDuration = TimeInterval(timerState.settings.durationMs(for: breakPhase)) / 1_000
        timerState.settings.selectedPhase = breakPhase
        let startCommand = appendCommand(
            .start,
            timerID: breakTimerID,
            taskID: nil,
            phase: breakPhase,
            duration: breakDuration,
            elapsed: 0
        )
        timerState.provisionalBreaks.append(ProvisionalBreak(
            focusTimerId: timer.id,
            finishCommandId: finishCommand.id,
            breakTimerId: breakTimerID,
            startCommandId: startCommand.id
        ))
        commitCommands()
        if cancelsAlarm {
            cancelAlarm(timerID: timer.id)
        }
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.schedule(
                timerID: breakTimerID,
                phase: breakPhase,
                duration: breakDuration
            )
        }
    }

    func cancel(at date: Date = .now) {
        guard !isHistoryResolutionBlocking else { return }
        guard let timer = canonicalTimer,
              timer.status == .running || timer.status == .paused else { return }
        enqueue(.cancel, timer: timer, elapsed: timer.elapsed(at: date))
        cancelAlarm(timerID: timer.id)
    }

    func clear() {
        guard !isHistoryResolutionBlocking else { return }
        guard let timer = canonicalTimer, !isTimerActive else { return }
        enqueue(.clear, timer: timer, elapsed: timer.elapsed(at: .now))
        cancelAlarm(timerID: timer.id, reportsError: false)
    }

    func completeIfNeeded(timerID: String, at date: Date) {
        guard !isHistoryResolutionBlocking else { return }
        guard let timer = canonicalTimer,
              timer.id == timerID,
              timer.status == .running,
              timer.remaining(at: date) <= 0,
              ownsAutomaticCompletion(for: timer.id),
              completionQueuedFor != timer.id else { return }
        completionQueuedFor = timer.id
        finish(at: date, cancelsAlarm: false)
    }

    func waitForAlarmOperations() async {
        await alarmOperationTask?.value
    }

    func dismissConflict() { conflictMessage = nil }

    func requestHistoryResolution(_ strategy: BootstrapResolutionStrategy) {
        guard historyResolutionState == .choosing else { return }
        historyResolutionState = .confirming(strategy)
    }

    func cancelHistoryResolutionConfirmation() {
        guard case .confirming = historyResolutionState else { return }
        historyResolutionState = .choosing
    }

    func confirmHistoryResolution() async {
        guard case .confirming(let strategy) = historyResolutionState,
              let snapshot = bootstrapSnapshot else { return }
        await submitBootstrapResolution(strategy: strategy, snapshot: snapshot)
    }

    func retryHistoryResolution() async {
        guard case .retryable = historyResolutionState else { return }
        guard isSignedIn else {
            signIn()
            return
        }
        let generation = sessionGeneration
        guard sessionVerification.allows(generation: generation) else {
            await verifyRestoredSession(generation: generation)
            return
        }
        if let request = timerState.pendingBootstrapResolution {
            await submitPersistedBootstrapResolution(request, generation: generation)
        } else {
            await preflightBootstrapResolution(generation: generation)
        }
    }

    func sync(force: Bool = false, showsActivity: Bool = true) async {
        guard isSignedIn, !isHistoryResolutionBlocking else { return }
        let generation = sessionGeneration
        guard sessionVerification.allows(generation: generation) else {
            await verifyRestoredSession(generation: generation)
            return
        }
        guard timerState.cachedUser?.id == user?.id else { return }
        if !force,
           timerState.pendingCommands.isEmpty,
           timerState.pendingTaskOperations.isEmpty,
           timerState.pendingDurationOperations.isEmpty,
           timerState.pendingAutoStartOperations.isEmpty { return }
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
                let batch = uploadableCommands(limit: 256)
                let taskBatch = Array(timerState.pendingTaskOperations.prefix(256))
                let durationBatch = Array(timerState.pendingDurationOperations.prefix(256))
                let autoStartBatch = Array(timerState.pendingAutoStartOperations.prefix(256))
                guard !batch.isEmpty || timerState.pendingCommands.isEmpty else {
                    throw AppError.invalidResponse
                }
                guard durationBatch.allSatisfy(\.isValid),
                      autoStartBatch.allSatisfy({
                        $0.isValid && $0.deviceId == timerState.deviceId
                      }) else { throw AppError.invalidResponse }
                let previousTimer = activeTimer
                let response = try await api.sync(
                    SyncRequest(
                        deviceId: timerState.deviceId,
                        lastRevision: timerState.revision,
                        commands: batch,
                        taskOperations: taskBatch,
                        durationOperations: durationBatch,
                        autoStartOperations: autoStartBatch
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
                var syncedState = timerState
                try syncedState.applyDurationSync(
                    canonicalDurations: response.durationsMs,
                    sentOperations: durationBatch,
                    acknowledgements: response.durationAcknowledgements
                )
                try syncedState.applyAutoStartSync(
                    canonicalValue: response.autoStartBreaks,
                    sentOperations: autoStartBatch,
                    acknowledgements: response.autoStartAcknowledgements
                )
                resolveProvisionalBreaks(
                    in: &syncedState,
                    acknowledgements: response.acknowledgements,
                    canonicalHistory: response.history,
                    canonicalTimer: response.canonicalTimer
                )
                updateLocalTimerOwnership(
                    in: &syncedState,
                    sentCommands: batch,
                    acknowledgements: response.acknowledgements,
                    canonicalTimer: response.canonicalTimer,
                    canonicalHistory: response.history
                )
                let acknowledgedIDSet = Set(acknowledgedIDs)
                let acknowledgedTaskIDSet = Set(acknowledgedTaskIDs)
                syncedState.pendingCommands.removeAll { acknowledgedIDSet.contains($0.id) }
                syncedState.pendingTaskOperations.removeAll { acknowledgedTaskIDSet.contains($0.id) }
                if let conflict = response.acknowledgements.first(where: { $0.outcome != "applied" }) {
                    conflictMessage = conflict.reason.isEmpty ? "Server resolved a timer action as \(conflict.outcome)." : conflict.reason
                } else if let conflict = response.taskAcknowledgements.first(where: { $0.outcome != "applied" }) {
                    conflictMessage = conflict.reason.isEmpty ? "Server resolved a task change as \(conflict.outcome)." : conflict.reason
                } else if let conflict = response.durationAcknowledgements.first(where: { $0.outcome != "applied" }) {
                    conflictMessage = conflict.reason.isEmpty ? "Server resolved a duration change as \(conflict.outcome)." : conflict.reason
                } else if let conflict = response.autoStartAcknowledgements.first(where: { $0.outcome != .applied }) {
                    conflictMessage = conflict.reason.isEmpty
                        ? "Server resolved an auto-start change as \(conflict.outcome.rawValue)."
                        : conflict.reason
                }
                syncedState.revision = response.revision
                syncedState.canonicalTimer = response.canonicalTimer
                syncedState.migrateLegacyTimerOwnership()
                syncedState.history = response.history
                syncedState.tasks = response.tasks
                syncedState.mergeKnownTasks(response.tasks)
                timerState = syncedState
                mergeServerClock(response.serverHlcWallMs, response.serverHlcCounter)
                rebuildOptimisticState()
                pruneLocalTimerOwners()
                reconcileAlarm(from: previousTimer, to: activeTimer, at: response.serverTime)
                isOffline = false
                errorMessage = nil
                persist()
            } while !timerState.pendingCommands.isEmpty
                || !timerState.pendingTaskOperations.isEmpty
                || !timerState.pendingDurationOperations.isEmpty
                || !timerState.pendingAutoStartOperations.isEmpty
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
        if !isHistoryResolutionBlocking {
            startRevisionStream()
            startRemotePolling()
        }
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
        appendCommand(
            type,
            timerID: timerID,
            taskID: taskID,
            phase: phase,
            duration: duration,
            elapsed: elapsed
        )
        commitCommands()
    }

    @discardableResult
    private func appendCommand(_ type: CommandType, timer: CanonicalTimer, elapsed: TimeInterval) -> TimerCommand {
        appendCommand(
            type,
            timerID: timer.id,
            taskID: nil,
            phase: timer.phase,
            duration: timer.plannedDuration,
            elapsed: elapsed
        )
    }

    @discardableResult
    private func appendCommand(
        _ type: CommandType,
        timerID: String,
        taskID: String?,
        phase: TimerPhase,
        duration: TimeInterval,
        elapsed: TimeInterval
    ) -> TimerCommand {
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
        timerState.pendingCommands.append(command)
        if type == .start {
            timerState.localTimerOwners[timerID] = timerState.deviceId
        }
        timerState.nextSequence += 1
        return command
    }

    private func commitCommands() {
        rebuildOptimisticState()
        persist()
        Task { await sync() }
    }

    private func uploadableCommands(limit: Int? = nil) -> [TimerCommand] {
        let provisionalTimerIDs = Set(timerState.provisionalBreaks.map(\.breakTimerId))
        let commands = timerState.pendingCommands.prefix {
            !provisionalTimerIDs.contains($0.timerId)
        }
        guard let limit else { return Array(commands) }
        return Array(commands.prefix(limit))
    }

    private func ownsAutomaticCompletion(for timerID: String) -> Bool {
        timerState.localTimerOwners[timerID] == timerState.deviceId
            || timerState.pendingCommands.contains {
                $0.type == .start && $0.timerId == timerID
            }
    }

    private func pruneLocalTimerOwners() {
        var retainedTimerIDs = Set(timerState.pendingCommands.lazy.filter {
            $0.type == .start
        }.map(\.timerId))
        for provisional in timerState.provisionalBreaks {
            retainedTimerIDs.insert(provisional.focusTimerId)
            retainedTimerIDs.insert(provisional.breakTimerId)
        }
        if let activeTimer {
            retainedTimerIDs.insert(activeTimer.id)
        }
        timerState.localTimerOwners = timerState.localTimerOwners.filter {
            retainedTimerIDs.contains($0.key)
        }
    }

    private func resolveProvisionalBreaks(
        in state: inout PersistedTimerState,
        acknowledgements: [Acknowledgement],
        canonicalHistory: [HistoryItem],
        canonicalTimer: CanonicalTimer?
    ) {
        let acknowledgementsByID = Dictionary(uniqueKeysWithValues: acknowledgements.map { ($0.commandId, $0) })
        var unresolved: [ProvisionalBreak] = []

        for provisional in state.provisionalBreaks {
            guard let acknowledgement = acknowledgementsByID[provisional.finishCommandId] else {
                unresolved.append(provisional)
                continue
            }
            let canonicalFinish = canonicalHistory.contains {
                $0.status == CanonicalTimer.Status.completed.rawValue
                    && $0.phase == .focus
                    && $0.commandId == provisional.finishCommandId
            }
            let canonicalSupersedesBreak = canonicalTimer.map {
                ($0.status == .running || $0.status == .paused)
                    && $0.id != provisional.focusTimerId
                    && $0.id != provisional.breakTimerId
            } ?? false
            guard (acknowledgement.outcome == "applied" || canonicalFinish),
                  !canonicalSupersedesBreak else {
                if let startIndex = state.pendingCommands.firstIndex(where: {
                    $0.id == provisional.startCommandId
                }) {
                    let dependencyEnd = state.pendingCommands[(startIndex + 1)...].firstIndex {
                        $0.type == .start
                    } ?? state.pendingCommands.endIndex
                    state.pendingCommands.removeSubrange(startIndex..<dependencyEnd)
                    state.localTimerOwners.removeValue(forKey: provisional.breakTimerId)
                } else {
                    state.localTimerOwners.removeValue(forKey: provisional.breakTimerId)
                }
                continue
            }

            let breakPhase = Self.canonicalBreakPhase(
                for: provisional,
                history: canonicalHistory
            )
            let breakDurationMs = state.settings.durationMs(for: breakPhase)
            if let startIndex = state.pendingCommands.firstIndex(where: {
                $0.id == provisional.startCommandId
            }) {
                let start = state.pendingCommands[startIndex]
                state.pendingCommands[startIndex] = TimerCommand(
                    id: start.id,
                    deviceSequence: start.deviceSequence,
                    timerId: start.timerId,
                    taskId: start.taskId,
                    type: start.type,
                    phase: breakPhase,
                    plannedDurationMs: breakDurationMs,
                    occurredAt: start.occurredAt,
                    hlcWallMs: start.hlcWallMs,
                    hlcCounter: start.hlcCounter,
                    observedElapsedMs: start.observedElapsedMs
                )
                state.settings.selectedPhase = breakPhase
            }
        }

        let pendingCommandIDs = Set(state.pendingCommands.map(\.id))
        state.provisionalBreaks = unresolved.filter {
            pendingCommandIDs.contains($0.startCommandId)
        }
    }

    private static func canonicalBreakPhase(
        for provisional: ProvisionalBreak,
        history: [HistoryItem]
    ) -> TimerPhase {
        let completedFocuses = history.filter {
            $0.status == CanonicalTimer.Status.completed.rawValue && $0.phase == .focus
        }.sorted {
            let lhsDate = $0.completedAt ?? .distantPast
            let rhsDate = $1.completedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return ($0.commandId ?? "") < ($1.commandId ?? "")
        }
        let sourceIndex = completedFocuses.firstIndex {
            $0.commandId == provisional.finishCommandId || $0.timerId == provisional.focusTimerId
        }
        return TimerReducer.breakPhase(
            afterCompletedFocusCount: sourceIndex.map { $0 + 1 } ?? completedFocuses.count
        )
    }

    private func updateLocalTimerOwnership(
        in state: inout PersistedTimerState,
        sentCommands: [TimerCommand],
        acknowledgements: [Acknowledgement],
        canonicalTimer: CanonicalTimer?,
        canonicalHistory: [HistoryItem]
    ) {
        let acknowledgementsByID = Dictionary(uniqueKeysWithValues: acknowledgements.map { ($0.commandId, $0) })
        for command in sentCommands where command.type == .start {
            guard let acknowledgement = acknowledgementsByID[command.id] else { continue }
            let canonicallyAccepted = canonicalTimer?.id == command.timerId
                || canonicalHistory.contains { $0.timerId == command.timerId }
            if acknowledgement.outcome == "applied" || canonicallyAccepted {
                state.localTimerOwners[command.timerId] = state.deviceId
            } else {
                state.localTimerOwners.removeValue(forKey: command.timerId)
            }
        }
    }

    private func reconcileAlarm(
        from previousTimer: CanonicalTimer?,
        to currentTimer: CanonicalTimer?,
        at date: Date
    ) {
        guard let previousTimer else {
            guard let currentTimer,
                  currentTimer.status == .running,
                  ownsAutomaticCompletion(for: currentTimer.id) else { return }
            enqueueAlarmOperation { [alarmScheduler] in
                try await alarmScheduler.schedule(
                    timerID: currentTimer.id,
                    phase: currentTimer.phase,
                    duration: max(1, currentTimer.remaining(at: date))
                )
            }
            return
        }
        guard previousTimer.status == .running || previousTimer.status == .paused else { return }
        guard let currentTimer,
              currentTimer.id == previousTimer.id,
              currentTimer.status == .running || currentTimer.status == .paused else {
            cancelAlarm(timerID: previousTimer.id, reportsError: false)
            guard let currentTimer,
                  currentTimer.status == .running,
                  ownsAutomaticCompletion(for: currentTimer.id) else { return }
            enqueueAlarmOperation { [alarmScheduler] in
                try await alarmScheduler.schedule(
                    timerID: currentTimer.id,
                    phase: currentTimer.phase,
                    duration: max(1, currentTimer.remaining(at: date))
                )
            }
            return
        }
        guard currentTimer.phase != previousTimer.phase
                || currentTimer.plannedDurationMs != previousTimer.plannedDurationMs
                || currentTimer.anchorAt != previousTimer.anchorAt else { return }
        cancelAlarm(timerID: previousTimer.id, reportsError: false)
        guard currentTimer.status == .running else { return }
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.schedule(
                timerID: currentTimer.id,
                phase: currentTimer.phase,
                duration: max(1, currentTimer.remaining(at: date))
            )
        }
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

    private func completeAuthenticatedSession(user: User, generation: Int) async {
        guard generation == sessionGeneration, isSignedIn else { return }
        if timerState.cachedUser != nil {
            timerState.prepare(for: user)
            historyResolutionState = .none
            bootstrapSnapshot = nil
            localHistoryResolutionCount = 0
            remoteHistoryResolutionCount = 0
            rebuildOptimisticState()
            persist()
            await sync(force: true)
            return
        }

        if timerState.bootstrapUser?.id != user.id {
            timerState.pendingBootstrapResolution = nil
        }
        timerState.bootstrapUser = user
        persist()
        if let request = timerState.pendingBootstrapResolution {
            await submitPersistedBootstrapResolution(request, generation: generation)
        } else {
            await preflightBootstrapResolution(generation: generation)
        }
    }

    private func preflightBootstrapResolution(generation: Int, autoSubmits: Bool = true) async {
        guard generation == sessionGeneration,
              isSignedIn,
              sessionVerification.allows(generation: generation),
              timerState.cachedUser == nil,
              timerState.bootstrapUser?.id == user?.id else { return }
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        historyResolutionState = .preflighting
        isSyncing = false
        do {
            let response = try await api.bootstrap(SyncRequest(
                deviceId: timerState.deviceId,
                lastRevision: timerState.revision,
                commands: [],
                taskOperations: [],
                durationOperations: [],
                autoStartOperations: []
            ))
            guard generation == sessionGeneration,
                  isSignedIn,
                  timerState.cachedUser == nil else { return }
            bootstrapSnapshot = response
            localHistoryResolutionCount = Self.visibleCompletedHistoryCount(history)
            remoteHistoryResolutionCount = Self.visibleCompletedHistoryCount(response.history)
            isOffline = false
            errorMessage = nil

            if localHistoryResolutionCount > 0, remoteHistoryResolutionCount > 0 {
                historyResolutionState = .choosing
                return
            }

            guard autoSubmits else {
                historyResolutionState = .retryable(nil)
                return
            }

            let strategy: BootstrapResolutionStrategy
            if localHistoryResolutionCount > 0 {
                strategy = .replaceRemote
            } else if remoteHistoryResolutionCount > 0 {
                strategy = .keepRemote
            } else {
                strategy = hasLocalBootstrapState ? .merge : .keepRemote
            }
            await submitBootstrapResolution(strategy: strategy, snapshot: response)
        } catch AppError.unauthorized {
            await invalidateUnauthorizedSession(generation: generation)
        } catch AppError.invalidResponse {
            guard generation == sessionGeneration, isSignedIn else { return }
            historyResolutionState = .retryable(nil)
            isOffline = false
            errorMessage = "History setup paused because the server returned an invalid response. Local data remains on this device."
        } catch AppError.historyReplacementUnavailable {
            guard generation == sessionGeneration, isSignedIn else { return }
            historyResolutionState = .retryable(nil)
            isOffline = false
            errorMessage = AppError.historyReplacementUnavailable.localizedDescription
        } catch {
            guard generation == sessionGeneration, isSignedIn else { return }
            historyResolutionState = .retryable(nil)
            isOffline = true
            scheduleRetry()
        }
    }

    private var hasLocalBootstrapState: Bool {
        !timerState.pendingCommands.isEmpty
            || !timerState.pendingTaskOperations.isEmpty
            || !timerState.pendingDurationOperations.isEmpty
            || !timerState.pendingAutoStartOperations.isEmpty
            || timerState.canonicalTimer != nil
            || !timerState.history.isEmpty
            || !timerState.tasks.isEmpty
    }

    private static func visibleCompletedHistoryCount(_ history: [HistoryItem]) -> Int {
        history.count { $0.status == CanonicalTimer.Status.completed.rawValue }
    }

    private func submitBootstrapResolution(
        strategy: BootstrapResolutionStrategy,
        snapshot: BootstrapResponse
    ) async {
        guard timerState.pendingBootstrapResolution == nil else { return }
        let includesLocalOperations = strategy != .keepRemote
        let request = BootstrapResolveRequest(
            requestId: "bootstrap-resolution-\(UUID().uuidString.lowercased())",
            deviceId: timerState.deviceId,
            expectedRevision: snapshot.revision,
            strategy: strategy,
            commands: includesLocalOperations ? uploadableCommands() : [],
            taskOperations: includesLocalOperations ? timerState.pendingTaskOperations : [],
            durationOperations: includesLocalOperations ? timerState.pendingDurationOperations : [],
            autoStartOperations: includesLocalOperations
                ? Array(timerState.pendingAutoStartOperations.prefix(4_096))
                : []
        )
        timerState.pendingBootstrapResolution = request
        persist()
        await submitPersistedBootstrapResolution(request, generation: sessionGeneration)
    }

    private func submitPersistedBootstrapResolution(
        _ request: BootstrapResolveRequest,
        generation: Int
    ) async {
        guard generation == sessionGeneration,
              isSignedIn,
              sessionVerification.allows(generation: generation),
              timerState.cachedUser == nil,
              timerState.bootstrapUser?.id == user?.id,
              timerState.pendingBootstrapResolution == request else { return }
        retryTask?.cancel()
        retryTask = nil
        historyResolutionState = .submitting(request.strategy)
        do {
            guard request.deviceId == timerState.deviceId,
                  (request.autoStartOperations ?? []).allSatisfy({
                    $0.isValid && $0.deviceId == request.deviceId
                  }) else {
                throw AppError.invalidResponse
            }
            let response = try await api.resolveBootstrap(request)
            guard generation == sessionGeneration,
                  isSignedIn,
                  timerState.pendingBootstrapResolution == request,
                  let bootstrapUser = timerState.bootstrapUser else { return }
            let previousTimer = activeTimer
            try applyBootstrapResolution(response, request: request, user: bootstrapUser)
            reconcileAlarm(from: previousTimer, to: activeTimer, at: response.serverTime)
            await sync(force: true)
        } catch AppError.unauthorized {
            await invalidateUnauthorizedSession(generation: generation)
        } catch AppError.conflict {
            guard generation == sessionGeneration, isSignedIn else { return }
            timerState.pendingBootstrapResolution = nil
            bootstrapSnapshot = nil
            persist()
            await preflightBootstrapResolution(generation: generation, autoSubmits: false)
        } catch AppError.invalidResponse {
            guard generation == sessionGeneration, isSignedIn else { return }
            historyResolutionState = .retryable(request.strategy)
            isOffline = false
            errorMessage = "History setup paused because the server returned an invalid response. Your saved choice and local data were preserved."
        } catch AppError.historyReplacementUnavailable {
            guard generation == sessionGeneration, isSignedIn else { return }
            historyResolutionState = .retryable(request.strategy)
            isOffline = false
            errorMessage = AppError.historyReplacementUnavailable.localizedDescription
        } catch {
            guard generation == sessionGeneration, isSignedIn else { return }
            historyResolutionState = .retryable(request.strategy)
            isOffline = true
            scheduleRetry()
        }
    }

    private func applyBootstrapResolution(
        _ response: BootstrapResponse,
        request: BootstrapResolveRequest,
        user: User
    ) throws {
        guard response.durationsMs.isValid else { throw AppError.invalidResponse }
        let commandAcknowledgements = response.acknowledgements.map(\.commandId)
        let taskAcknowledgements = response.taskAcknowledgements.map(\.operationId)
        let durationAcknowledgements = response.durationAcknowledgements.map(\.operationId)
        let autoStartAcknowledgements = response.autoStartAcknowledgements.map(\.operationId)
        let requestedAutoStartOperations = request.autoStartOperations ?? []
        guard request.deviceId == timerState.deviceId,
              requestedAutoStartOperations.count <= 4_096,
              requestedAutoStartOperations.allSatisfy({
                $0.isValid && $0.deviceId == request.deviceId
              }),
              AcknowledgementSet.exactlyMatches(sent: request.commands.map(\.id), acknowledged: commandAcknowledgements),
              AcknowledgementSet.exactlyMatches(sent: request.taskOperations.map(\.id), acknowledged: taskAcknowledgements),
              AcknowledgementSet.exactlyMatches(sent: request.durationOperations.map(\.id), acknowledged: durationAcknowledgements),
              AcknowledgementSet.exactlyMatches(
                sent: requestedAutoStartOperations.map(\.id),
                acknowledged: autoStartAcknowledgements
              ) else {
            throw AppError.invalidResponse
        }
        var resolved = timerState
        if request.strategy == .keepRemote {
            resolved.pendingCommands = []
            resolved.pendingTaskOperations = []
            resolved.pendingDurationOperations = []
            if request.autoStartOperations != nil {
                resolved.pendingAutoStartOperations = []
            }
            resolved.localTimerOwners = [:]
            resolved.provisionalBreaks = []
            resolved.knownTasks = response.tasks
            resolved.selectedTaskID = nil
            resolved.legacyTaskAssignments = [:]
        } else {
            let commandIDs = Set(commandAcknowledgements)
            let taskIDs = Set(taskAcknowledgements)
            let durationIDs = Set(durationAcknowledgements)
            let autoStartIDs = Set(autoStartAcknowledgements)
            resolved.pendingCommands.removeAll { commandIDs.contains($0.id) }
            resolved.pendingTaskOperations.removeAll { taskIDs.contains($0.id) }
            resolved.pendingDurationOperations.removeAll { durationIDs.contains($0.id) }
            resolved.pendingAutoStartOperations.removeAll { autoStartIDs.contains($0.id) }
            resolved.settings.durationsMs = DurationReducer.applying(
                resolved.pendingDurationOperations,
                to: response.durationsMs
            )
            resolveProvisionalBreaks(
                in: &resolved,
                acknowledgements: response.acknowledgements,
                canonicalHistory: response.history,
                canonicalTimer: response.canonicalTimer
            )
            updateLocalTimerOwnership(
                in: &resolved,
                sentCommands: request.commands,
                acknowledgements: response.acknowledgements,
                canonicalTimer: response.canonicalTimer,
                canonicalHistory: response.history
            )
            resolved.mergeKnownTasks(response.tasks)
        }

        resolved.revision = response.revision
        resolved.canonicalTimer = response.canonicalTimer
        resolved.migrateLegacyTimerOwnership()
        resolved.history = response.history
        resolved.tasks = response.tasks
        resolved.autoStartBreaks = response.autoStartBreaks
        resolved.settings.durationsMs = DurationReducer.applying(
            resolved.pendingDurationOperations,
            to: response.durationsMs
        )
        resolved.cachedUser = user
        resolved.bootstrapUser = nil
        resolved.pendingBootstrapResolution = nil
        timerState = resolved
        mergeServerClock(response.serverHlcWallMs, response.serverHlcCounter)
        bootstrapSnapshot = nil
        historyResolutionState = .none
        localHistoryResolutionCount = 0
        remoteHistoryResolutionCount = 0
        isOffline = false
        errorMessage = nil
        rebuildOptimisticState()
        pruneLocalTimerOwners()
        persist()
    }

    private func verifyRestoredSession(generation: Int) async {
        guard generation == sessionGeneration,
              isSignedIn,
              !sessionVerification.allows(generation: generation),
              timerState.cachedUser != nil || timerState.bootstrapUser != nil,
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
            sessionVerification.markVerified(generation: generation)
            sessionState = .signedIn(response.user)
            isOffline = false
            await completeAuthenticatedSession(user: response.user, generation: generation)
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
        isWorking = false
        isSyncing = false
        revisionHints = RevisionHintCoalescer()
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        sessionState = .localOnly
        let preservesBootstrapResolution = timerState.cachedUser == nil && timerState.bootstrapUser != nil
        historyResolutionState = preservesBootstrapResolution
            ? .retryable(timerState.pendingBootstrapResolution?.strategy)
            : .none
        bootstrapSnapshot = nil
        localHistoryResolutionCount = 0
        remoteHistoryResolutionCount = 0
        isOffline = false
        errorMessage = AppError.unauthorized.localizedDescription
        try? await api.clearTokens()
    }

    private func scheduleRetry() {
        guard retryTask == nil || retryTask?.isCancelled == true else { return }
        let retryDelay = retryDelay
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            if self.isHistoryResolutionBlocking {
                await self.retryHistoryResolution()
            } else {
                await self.sync(force: true)
            }
        }
    }

    private func startRemotePolling() {
        guard isSignedIn,
              !isHistoryResolutionBlocking,
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
              !isHistoryResolutionBlocking,
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

    private static func hasPersistedAutoStartOperations(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object.keys.contains("pendingAutoStartOperations")
    }

    private static func hasExplicitLegacyAutoStartBreaks(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = object["settings"] as? [String: Any] else { return false }
        return settings["autoStartBreaksExplicitlySet"] as? Bool == true
    }

    private static var platform: String {
#if os(iOS)
        "ios"
#else
        "macos"
#endif
    }
}
