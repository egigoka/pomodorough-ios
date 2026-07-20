import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum SessionState: Equatable {
        case restoring
        case signedOut
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
    private(set) var isWorking = false
    private(set) var isSyncing = false
    private(set) var isOffline = false
    private(set) var conflictMessage: String?
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
        if let data = storedData,
           let state = try? JSONDecoder.api.decode(PersistedTimerState.self, from: data) {
            timerState = state
        } else {
            timerState = .fresh()
        }
        rebuildOptimisticState()
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

    var pendingCommandCount: Int { timerState.pendingCommands.count }
    var completedFocusCount: Int { history.count { $0.status == "completed" && $0.phase == .focus } }
    var deviceMark: String { String(timerState.deviceId.suffix(4)).uppercased() }

    var syncLabel: String {
        if conflictMessage != nil { return "Review conflict" }
        if pendingCommandCount > 0 { return "\(pendingCommandCount) queued" }
        if isOffline { return "Offline" }
        if isSyncing { return "Syncing" }
        return "In sync"
    }

    func durationMinutes(for phase: TimerPhase) -> Int { timerState.settings.minutes(for: phase) }

    func setDurationMinutes(_ minutes: Int, for phase: TimerPhase) {
        guard !isTimerActive else { return }
        timerState.settings.setMinutes(minutes, for: phase)
        persist()
    }

    func restore() async {
        guard sessionState == .restoring else { return }
        let generation = sessionGeneration
        do {
            guard try await api.restoreTokens() else {
                guard generation == sessionGeneration else { return }
                timerState.discardUnownedAccountData()
                rebuildOptimisticState()
                persist()
                sessionState = .signedOut
                return
            }
            guard generation == sessionGeneration else { return }
            guard let cachedUser = timerState.cachedUser else {
                sessionGeneration += 1
                sessionVerification.invalidate()
                syncOwnership.invalidate()
                sessionState = .signedOut
                timerState.discardUnownedAccountData()
                rebuildOptimisticState()
                persist()
                try? await api.clearTokens()
                return
            }
            sessionState = .signedIn(cachedUser)
            await verifyRestoredSession(generation: generation)
        } catch AppError.unauthorized {
            await invalidateUnauthorizedSession(generation: generation)
        } catch {
            guard generation == sessionGeneration else { return }
            timerState.discardUnownedAccountData()
            rebuildOptimisticState()
            persist()
            sessionState = .signedOut
            isOffline = true
        }
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
        sessionState = .signedOut
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
        let minutes = durationMinutes(for: selectedPhase)
        let timerID = "timer-\(UUID().uuidString.lowercased())"
        let phase = selectedPhase
        let duration = TimeInterval(minutes * 60)
        let shouldScheduleAlarm = !isTimerActive
        enqueue(
            .start,
            timerID: timerID,
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
        enqueue(.resume, timer: timer, elapsed: timer.elapsed(at: date))
        guard timer.status == .paused else { return }
        enqueueAlarmOperation { [alarmScheduler] in
            try alarmScheduler.resume(timerID: timer.id)
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
        cancelAlarm(timerID: timer.id)
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
        if !force, timerState.pendingCommands.isEmpty { return }
        guard let syncID = syncOwnership.begin(generation: generation) else { return }
        retryTask?.cancel()
        if showsActivity { isSyncing = true }
        defer {
            if let requestedFollowUp = syncOwnership.finish(syncID, currentGeneration: sessionGeneration) {
                if showsActivity { isSyncing = false }
                let hintedFollowUp = revisionHints.consumeFollowUp(localRevision: timerState.revision)
                if isSignedIn,
                   (requestedFollowUp || (generation == sessionGeneration && hintedFollowUp)) {
                    Task { [weak self] in await self?.sync(force: true) }
                }
            }
        }
        do {
            repeat {
                let batch = Array(timerState.pendingCommands.prefix(256))
                let response = try await api.sync(
                    SyncRequest(
                        deviceId: timerState.deviceId,
                        lastRevision: timerState.revision,
                        commands: batch
                    )
                )
                guard generation == sessionGeneration, isSignedIn else { return }

                let sentIDs = Set(batch.map(\.id))
                let acknowledgedIDs = Set(response.acknowledgements.map(\.commandId))
                guard sentIDs == acknowledgedIDs else { throw AppError.invalidResponse }
                timerState.pendingCommands.removeAll { acknowledgedIDs.contains($0.id) }
                if let conflict = response.acknowledgements.first(where: { $0.outcome != "applied" }) {
                    conflictMessage = conflict.reason.isEmpty ? "Server resolved a timer action as \(conflict.outcome)." : conflict.reason
                }
                timerState.revision = response.revision
                timerState.canonicalTimer = response.canonicalTimer
                timerState.history = response.history
                mergeServerClock(response.serverHlcWallMs)
                rebuildOptimisticState()
                isOffline = false
                errorMessage = nil
                persist()
            } while !timerState.pendingCommands.isEmpty
            startRevisionStream()
            startRemotePolling()
        } catch AppError.unauthorized {
            await invalidateUnauthorizedSession(generation: generation)
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
            phase: timer.phase,
            duration: timer.plannedDuration,
            elapsed: elapsed
        )
    }

    private func enqueue(
        _ type: CommandType,
        timerID: String,
        phase: TimerPhase,
        duration: TimeInterval,
        elapsed: TimeInterval
    ) {
        let now = Date.now
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        if nowMs > timerState.hlcWallMs {
            timerState.hlcWallMs = nowMs
            timerState.hlcCounter = 0
        } else {
            timerState.hlcCounter += 1
        }
        let command = TimerCommand(
            id: "command-\(UUID().uuidString.lowercased())",
            deviceSequence: timerState.nextSequence,
            timerId: timerID,
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

    private func cancelAlarm(timerID: String) {
        enqueueAlarmOperation { [alarmScheduler] in
            try alarmScheduler.cancel(timerID: timerID)
        }
    }

    private func enqueueAlarmOperation(
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        let previousOperation = alarmOperationTask
        alarmOperationTask = Task { [weak self] in
            await previousOperation?.value
            guard !Task.isCancelled else { return }
            do {
                try await operation()
            } catch {
                self?.errorMessage = "Timer continues in Pomodorough, but its system alarm could not be updated. \(error.localizedDescription)"
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
        if canonicalTimer?.status != .running { completionQueuedFor = nil }
    }

    private func mergeServerClock(_ serverWallMs: Int64) {
        let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
        let merged = max(nowMs, serverWallMs, timerState.hlcWallMs)
        timerState.hlcCounter = merged == timerState.hlcWallMs ? timerState.hlcCounter : 0
        timerState.hlcWallMs = merged
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
        sessionState = .signedOut
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

    private static var platform: String {
#if os(iOS)
        "ios"
#else
        "macos"
#endif
    }
}
