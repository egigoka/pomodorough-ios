import GoogleSignInSwift
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.sessionState {
            case .restoring:
                LaunchView()
            case .localOnly:
                destination
            case .signedIn:
                destination
            }
        }
        .frame(minWidth: 320, minHeight: 420)
        .tint(PomodoroughTheme.signal)
        .alert("Pomodorough", isPresented: errorPresented) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    @ViewBuilder
    private var destination: some View {
#if os(iOS)
        if model.needsPermissionIntroduction {
            PermissionIntroductionView(model: model)
        } else {
            MainContainer(model: model)
        }
#else
        MainContainer(model: model)
#endif
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            PomodoroughTheme.platform.ignoresSafeArea()
            VStack(spacing: 18) {
                RouteClockMark()
                ProgressView()
                    .tint(PomodoroughTheme.ticket)
                Text("CHECKING LINE")
                    .font(.caption.monospaced().bold())
                    .tracking(2)
                    .foregroundStyle(PomodoroughTheme.sky)
            }
        }
    }
}

#if os(iOS)
private struct PermissionIntroductionView: View {
    let model: AppModel
    @State private var isRequesting = false

    var body: some View {
        ZStack {
            RailwayBackdrop()
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 14) {
                        RouteClockMark()
                        Text("BEFORE DEPARTURE")
                            .font(.caption.monospaced().bold())
                            .tracking(2)
                            .foregroundStyle(PomodoroughTheme.ticket)
                        Text("Hear when time is up")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(PomodoroughTheme.porcelain)
                        Text("Pomodorough can alert you when a focus run or break ends, even when you leave the app.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(PomodoroughTheme.sky)
                    }

                    VStack(spacing: 12) {
                        PermissionIntroductionCard(
                            icon: "bell.badge.fill",
                            title: "Notifications",
                            detail: "Sends a backup alert when an interval ends. Used on older iOS versions or when alarms are unavailable.",
                            color: PomodoroughTheme.sky
                        )
                        if #available(iOS 26.0, *) {
                            PermissionIntroductionCard(
                                icon: "alarm.fill",
                                title: "Alarms",
                                detail: "Plays a system timer alarm at the end, including while Pomodorough is not open.",
                                color: PomodoroughTheme.signal
                            )
                        }
                    }

                    VStack(spacing: 12) {
                        Button {
                            isRequesting = true
                            Task {
                                await model.allowTimerAlerts()
                                isRequesting = false
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if isRequesting {
                                    ProgressView().tint(PomodoroughTheme.platform)
                                }
                                Text("Allow timer alerts")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PomodoroughTheme.platform)
                        .background(PomodoroughTheme.ticket, in: .rect(cornerRadius: 14))
                        .disabled(isRequesting)

                        Button("Not now") {
                            model.skipTimerAlertPermissions()
                        }
                        .font(.headline)
                        .foregroundStyle(PomodoroughTheme.porcelain)
                        .frame(minHeight: 44)
                        .disabled(isRequesting)

                        Text("Permissions are optional. The timer still works while Pomodorough is open.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(PomodoroughTheme.steel)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct PermissionIntroductionCard: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(PomodoroughTheme.platform)
                .frame(width: 46, height: 46)
                .background(color, in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(PomodoroughTheme.porcelain)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(PomodoroughTheme.sky)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(PomodoroughTheme.platform.opacity(0.9), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PomodoroughTheme.porcelain.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif

private struct MainContainer: View {
    let model: AppModel

    var body: some View {
#if os(iOS)
        if #available(iOS 18, *) {
            ModernTabs(model: model)
        } else {
            LegacyTabs(model: model)
        }
#else
        TabView {
            TimerScreen(model: model)
                .tabItem { Label("Timer", systemImage: "timer") }
            TasksScreen(model: model)
                .tabItem { Label("Tasks", systemImage: "checklist") }
            ServicePatternScreen(model: model)
                .tabItem { Label("Pattern", systemImage: "slider.horizontal.3") }
            HistoryScreen(model: model)
                .tabItem { Label("Arrivals", systemImage: "clock.arrow.circlepath") }
        }
#endif
    }
}

#if os(iOS)
@available(iOS 18, *)
private struct ModernTabs: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("Timer", systemImage: "timer") {
                NavigationStack { TimerScreen(model: model) }
            }
            Tab("Tasks", systemImage: "checklist") {
                NavigationStack { TasksScreen(model: model) }
            }
            Tab("Pattern", systemImage: "slider.horizontal.3") {
                NavigationStack { ServicePatternScreen(model: model) }
            }
            Tab("Arrivals", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                NavigationStack { HistoryScreen(model: model) }
            }
        }
    }
}

private struct LegacyTabs: View {
    let model: AppModel

    var body: some View {
        TabView {
            NavigationStack { TimerScreen(model: model) }
                .tabItem { Label("Timer", systemImage: "timer") }
            NavigationStack { TasksScreen(model: model) }
                .tabItem { Label("Tasks", systemImage: "checklist") }
            NavigationStack { ServicePatternScreen(model: model) }
                .tabItem { Label("Pattern", systemImage: "slider.horizontal.3") }
            NavigationStack { HistoryScreen(model: model) }
                .tabItem { Label("Arrivals", systemImage: "clock.arrow.circlepath") }
        }
    }
}
#endif

private struct TimerScreen: View {
    @Bindable var model: AppModel
    @State private var showsAccount = false

    var body: some View {
        GeometryReader { geometry in
            let layout = TimerLayout(size: geometry.size)

            Group {
                if layout == .landscape {
                    VStack(spacing: 10) {
                        if let conflict = model.conflictMessage {
                            ConflictBanner(message: conflict, dismiss: model.dismissConflict)
                        }
                        TimerMachineCard(model: model, layout: layout)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .timerChromeHidden(true)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            if let conflict = model.conflictMessage {
                                ConflictBanner(message: conflict, dismiss: model.dismissConflict)
                            }
                            TimerMachineCard(model: model, layout: layout)
                        }
                        .padding()
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .timerChromeHidden(false)
                }
            }
        }
        .background(TimerBackdrop())
        .navigationTitle("Pomodorough")
        .inlineNavigationTitleIfSupported()
        .refreshable { await model.sync(force: true) }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SyncToolbarStatus(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Account", systemImage: "person.crop.circle") { showsAccount = true }
            }
        }
        .sheet(isPresented: $showsAccount) { AccountView(model: model) }
    }
}

private enum TimerLayout {
    case portrait
    case landscape

    init(size: CGSize) {
#if os(iOS)
        self = size.width > size.height ? .landscape : .portrait
#else
        self = .portrait
#endif
    }
}

private struct SyncToolbarStatus: View {
    let model: AppModel

    var body: some View {
        Button {
            Task { await model.sync(force: true) }
        } label: {
            HStack(spacing: 6) {
                if model.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.conflictMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.conflictMessage == nil ? PomodoroughTheme.platform : PomodoroughTheme.signal)
                        .accessibilityHidden(true)
                }
                Text(model.syncLabel.uppercased())
                    .font(.caption2.monospaced().bold())
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Sync status, \(model.syncLabel)")
        .accessibilityHint(model.isSignedIn ? "Sync now" : "Sign in to sync across devices")
        .disabled(!model.isSignedIn || model.isSyncing)
    }
}

private struct ServicePatternScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            ServicePatternCard(model: model)
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(PomodoroughTheme.sky.gradient)
        .navigationTitle("Service pattern")
        .inlineNavigationTitleIfSupported()
    }
}

private struct ConflictBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Timer continued elsewhere").font(.headline)
                Text(message).font(.subheadline)
            }
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
        }
        .padding()
        .foregroundStyle(.white)
        .background(PomodoroughTheme.danger, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

private struct ServicePatternCard: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(kicker: "ROUTE", title: "Service pattern", subtitle: "Choose a mode and duration")
            ForEach(TimerPhase.allCases) { phase in
                DurationRow(
                    phase: phase,
                    minutes: model.durationMinutes(for: phase),
                    selected: model.selectedPhase == phase,
                    disabled: model.isTimerActive,
                    select: { model.selectPhase(phase) },
                    changeMinutes: { model.setDurationMinutes($0, for: phase) }
                )
            }
            Divider().overlay(PomodoroughTheme.steel)
            Toggle("Auto-start breaks", isOn: $model.autoStartBreaks)
                .font(.headline)
                .disabled(model.isTimerActive)
            Text("Short after focus. Long every fourth completed focus.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(PomodoroughTheme.porcelain, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).stroke(PomodoroughTheme.track, lineWidth: 2)
        }
    }
}

private struct DurationRow: View {
    let phase: TimerPhase
    let minutes: Int
    let selected: Bool
    let disabled: Bool
    let select: () -> Void
    let changeMinutes: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(selected ? PomodoroughTheme.signal : PomodoroughTheme.steel)
                        .frame(width: 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.routeLabel.uppercased())
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(selected ? PomodoroughTheme.ticket : .secondary)
                        Text(phase.title)
                            .font(.headline)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 54)
                .foregroundStyle(selected ? PomodoroughTheme.porcelain : PomodoroughTheme.track)
                .background(selected ? PomodoroughTheme.platform : .clear, in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityAddTraits(selected ? .isSelected : [])

            HStack(spacing: 0) {
                StepButton(title: "Reduce \(phase.title) duration", symbol: "minus") { changeMinutes(minutes - 1) }
                Text("\(minutes) min")
                    .font(.callout.monospaced().bold())
                    .frame(minWidth: 66)
                    .accessibilityHidden(true)
                StepButton(title: "Increase \(phase.title) duration", symbol: "plus") { changeMinutes(minutes + 1) }
            }
            .background(PomodoroughTheme.sky, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(PomodoroughTheme.track, lineWidth: 1.5) }
            .disabled(disabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(phase.title) duration, \(minutes) minutes")
        }
    }
}

private struct StepButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}

private struct TimerMachineCard: View {
    let model: AppModel
    let layout: TimerLayout

    var body: some View {
        VStack(spacing: layout == .landscape ? 10 : 18) {
            HStack {
                Text("CURRENT SERVICE")
                Spacer()
                Text((model.activeTimer?.status.rawValue ?? "idle").uppercased())
                    .foregroundStyle(PomodoroughTheme.ticket)
            }
            .font(.caption.monospaced().bold())
            .tracking(1)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Divider().overlay(.white.opacity(0.35)) }

            if let timer = model.activeTimer {
                TimerDial(timer: timer, model: model, layout: layout)
            } else {
                IdleTimerDial(
                    phase: model.selectedPhase,
                    minutes: model.durationMinutes(for: model.selectedPhase),
                    layout: layout
                )
            }
            TimerTaskPicker(model: model, layout: layout)
            TimerControls(model: model, layout: layout)
        }
        .padding(layout == .landscape ? 14 : 18)
        .frame(maxWidth: .infinity, maxHeight: layout == .landscape ? .infinity : nil)
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(PomodoroughTheme.platform.opacity(0.9))
                .shadow(color: PomodoroughTheme.signal.opacity(0.9), radius: 0, x: 7, y: 7)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct TimerTaskPicker: View {
    @Bindable var model: AppModel
    let layout: TimerLayout

    var body: some View {
        HStack(spacing: 12) {
            Label("FOCUS TASK", systemImage: "checklist")
                .font(.caption.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.sky)
                .labelStyle(.titleAndIcon)
            if model.isTimerActive, let timer = model.canonicalTimer {
                Text(model.task(forTimerID: timer.id)?.title ?? "No task")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(PomodoroughTheme.ticket)
            } else {
                Picker("Focus task", selection: $model.selectedTaskID) {
                    Text("No task").tag(UUID?.none)
                    ForEach(model.tasks) { task in
                        Text(task.title).tag(Optional(task.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(PomodoroughTheme.ticket)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: layout == .landscape ? 40 : 48)
        .background(PomodoroughTheme.track.opacity(0.58), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: model.isTimerActive ? .combine : .contain)
    }
}

private struct IdleTimerDial: View {
    let phase: TimerPhase
    let minutes: Int
    let layout: TimerLayout

    var body: some View {
        DialFace(
            progress: 0,
            phase: phase,
            status: "Idle",
            timeText: String(format: "%02d:00", minutes),
            layout: layout
        )
    }
}

private struct TimerDial: View {
    let timer: CanonicalTimer
    let model: AppModel
    let layout: TimerLayout

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = timer.elapsed(at: context.date)
            let remaining = timer.remaining(at: context.date)
            let progress = timer.plannedDuration > 0 ? elapsed / timer.plannedDuration : 0
            DialFace(
                progress: progress,
                phase: timer.phase,
                status: timer.status.rawValue.capitalized,
                timeText: Self.timeText(remaining),
                layout: layout
            )
            .onChange(of: remaining <= 0, initial: true) {
                if remaining <= 0 { model.completeIfNeeded(timerID: timer.id, at: context.date) }
            }
        }
    }

    private static func timeText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(duration)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct DialFace: View {
    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String
    let layout: TimerLayout

    @ViewBuilder
    var body: some View {
        if layout == .landscape {
            LandscapeDialFace(progress: progress, phase: phase, status: status, timeText: timeText)
        } else {
            PortraitDialFace(progress: progress, phase: phase, status: status, timeText: timeText)
        }
    }
}

private struct PortraitDialFace: View {
    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String

    var body: some View {
        ZStack {
            Circle().fill(PomodoroughTheme.sky)
            Circle().stroke(PomodoroughTheme.porcelain, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(PomodoroughTheme.signal, style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .padding(16)
            TickMarks().stroke(PomodoroughTheme.track, lineWidth: 1)
            VStack(spacing: 7) {
                Text("NOW TIMING")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(PomodoroughTheme.steel)
                Text(phase.title.uppercased())
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(PomodoroughTheme.signal)
                Text(timeText)
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.48)
                    .lineLimit(1)
                    .foregroundStyle(PomodoroughTheme.ticket)
                Text(status.uppercased())
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(PomodoroughTheme.sky)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .digitalReadoutPanel(cornerRadius: 18)
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(PomodoroughTheme.porcelain.opacity(0.8), lineWidth: 2) }
            .padding(42)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 500)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phase.title) timer")
        .accessibilityValue("\(timeText) remaining, \(status)")
    }
}

private struct LandscapeDialFace: View {
    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(phase.routeLabel.uppercased())
                Text(phase.title.uppercased())
                    .foregroundStyle(PomodoroughTheme.signal)
                Spacer()
                Text(status.uppercased())
                    .foregroundStyle(PomodoroughTheme.sky)
            }
            .font(.caption.monospaced().bold())
            .tracking(1.5)

            Text(timeText)
                .font(.system(size: 156, weight: .black, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .foregroundStyle(PomodoroughTheme.ticket)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ProgressView(value: max(0, min(1, progress)))
                .progressViewStyle(.linear)
                .tint(PomodoroughTheme.signal)
                .background(PomodoroughTheme.porcelain.opacity(0.18), in: .capsule)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .digitalReadoutPanel(cornerRadius: 24)
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(PomodoroughTheme.porcelain.opacity(0.55), lineWidth: 1.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phase.title) timer")
        .accessibilityValue("\(timeText) remaining, \(status)")
    }
}

private struct TickMarks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) * 0.48
        for index in 0..<60 {
            let angle = Double(index) * .pi * 2 / 60 - .pi / 2
            let inner = outer - (index.isMultiple(of: 5) ? 12 : 6)
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        return path
    }
}

private struct TimerControls: View {
    private enum GlassControlID: Hashable {
        case primary
        case finish
        case clear
        case cancel
    }

    private enum ControlState: Hashable {
        case idle
        case running
        case paused
        case clearable
    }

    let model: AppModel
    let layout: TimerLayout
    @Namespace private var glassNamespace

    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: 14) {
                controls(glass: true)
            }
            .animation(.smooth(duration: 0.4), value: controlState)
        } else {
            controls(glass: false)
        }
    }

    @ViewBuilder
    private func controls(glass: Bool) -> some View {
        if usesHorizontalControls {
            HStack(spacing: 14) {
                primaryButton(glass: glass)
                if model.isTimerActive {
                    controlButton("Finish", symbol: "checkmark", glassID: .finish, prominent: false, glass: glass) { model.finish() }
                    controlButton("Cancel", symbol: "xmark", glassID: .cancel, prominent: false, glass: glass) { model.cancel() }
                } else if hasClearableTimer {
                    controlButton("Clear", symbol: "trash", glassID: .clear, prominent: false, glass: glass, action: model.clear)
                }
            }
        } else {
            VStack(spacing: 14) {
                primaryButton(glass: glass)
                if model.isTimerActive {
                    HStack(spacing: 14) {
                        controlButton("Finish", symbol: "checkmark", glassID: .finish, prominent: false, glass: glass) { model.finish() }
                        controlButton("Cancel", symbol: "xmark", glassID: .cancel, prominent: false, glass: glass) { model.cancel() }
                    }
                }
                if hasClearableTimer {
                    controlButton("Clear timer", symbol: "trash", glassID: .clear, prominent: false, glass: glass, action: model.clear)
                }
            }
        }
    }

    @ViewBuilder
    private func primaryButton(glass: Bool) -> some View {
        if model.canonicalTimer?.status == .running {
            controlButton("Pause", symbol: "pause.fill", glassID: .primary, prominent: true, glass: glass) { model.pause() }
        } else if model.canonicalTimer?.status == .paused {
            controlButton("Resume", symbol: "play.fill", glassID: .primary, prominent: true, glass: glass) { model.resume() }
        } else {
            controlButton(
                "Start \(model.selectedPhase.title)",
                symbol: "play.fill",
                glassID: .primary,
                prominent: true,
                glass: glass,
                action: model.start
            )
        }
    }

    private var hasClearableTimer: Bool {
        guard let timer = model.canonicalTimer else { return false }
        guard timer.status != .running && timer.status != .paused else { return false }
#if os(iOS)
        return timer.status != .cancelled
#else
        return true
#endif
    }

    private var usesHorizontalControls: Bool {
#if os(iOS)
        layout == .landscape
#else
        true
#endif
    }

    private var controlState: ControlState {
        if model.canonicalTimer?.status == .running {
            return .running
        }
        if model.canonicalTimer?.status == .paused {
            return .paused
        }
        return hasClearableTimer ? .clearable : .idle
    }

    @ViewBuilder
    private func controlButton(
        _ title: String,
        symbol: String,
        glassID: GlassControlID,
        prominent: Bool,
        glass: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: layout == .landscape ? 54 : 58)
            .buttonBorderShape(.capsule)
        if #available(iOS 26, macOS 26, *), glass {
            if prominent {
                button
                    .buttonStyle(.glassProminent)
                    .tint(PomodoroughTheme.signal)
                    .controlSize(.extraLarge)
                    .glassEffectID(glassID, in: glassNamespace)
                    .glassEffectTransition(glassID == .primary ? .matchedGeometry : .materialize)
            } else {
                button
                    .buttonStyle(.glass)
                    .tint(PomodoroughTheme.porcelain.opacity(0.16))
                    .controlSize(.extraLarge)
                    .glassEffectID(glassID, in: glassNamespace)
                    .glassEffectTransition(glassID == .primary ? .matchedGeometry : .materialize)
            }
        } else {
            button
                .buttonStyle(.borderedProminent)
                .tint(prominent ? PomodoroughTheme.ticket : PomodoroughTheme.sky)
                .foregroundStyle(PomodoroughTheme.track)
                .controlSize(.large)
        }
    }
}

private struct TimerBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PomodoroughTheme.sky, PomodoroughTheme.mint.opacity(0.82), PomodoroughTheme.sky],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(PomodoroughTheme.ticket.opacity(0.3))
                .frame(width: 280, height: 280)
                .blur(radius: 18)
                .offset(x: -150, y: -220)
            RoundedRectangle(cornerRadius: 80)
                .fill(PomodoroughTheme.signal.opacity(0.2))
                .frame(width: 360, height: 150)
                .rotationEffect(.degrees(-14))
                .blur(radius: 20)
                .offset(x: 170, y: 260)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct HistoryScreen: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No arrivals yet",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Your first completed or cancelled run appears here.")
                )
            } else {
                List(model.history) { item in
                    HistoryRow(item: item)
                }
                .listStyle(.plain)
                .refreshable { await model.sync(force: true) }
            }
        }
        .navigationTitle("Recent arrivals")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text(String(format: "%03d", model.history.count))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(PomodoroughTheme.ticket)
                    .padding(.horizontal, 9)
                    .background(PomodoroughTheme.platform, in: .rect(cornerRadius: 7))
                    .accessibilityLabel("\(model.history.count) history entries")
            }
        }
    }
}

private struct TasksScreen: View {
    @Bindable var model: AppModel
    @State private var newTaskTitle = ""
    @FocusState private var taskFieldFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                TaskBoardHero(
                    finishedPomodoros: summaries.reduce(0) { $0 + $1.finishedPomodoros },
                    timeSpentMs: summaries.reduce(0) { $0 + $1.timeSpentMs }
                )
                TaskComposer(
                    title: $newTaskTitle,
                    focused: $taskFieldFocused,
                    canAdd: canAddTask,
                    add: addTask
                )
                VStack(spacing: 0) {
                    TaskBoardHeader()
                    if summaries.isEmpty {
                        TaskBoardEmptyState()
                    } else {
                        ForEach(summaries) { summary in
                            Divider().overlay(PomodoroughTheme.steel.opacity(0.45))
                            TaskSummaryRow(summary: summary) {
                                model.deleteTask(id: summary.id)
                            }
                            .contextMenu {
                                Button("Delete task", systemImage: "trash", role: .destructive) {
                                    model.deleteTask(id: summary.id)
                                }
                            }
                        }
                    }
                }
                .background(PomodoroughTheme.porcelain, in: .rect(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(PomodoroughTheme.track, lineWidth: 2)
                }
                .clipShape(.rect(cornerRadius: 20))
                .animation(.smooth(duration: 0.3), value: summaries.map(\.id))
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(TimerBackdrop())
        .navigationTitle("Tasks")
        .inlineNavigationTitleIfSupported()
    }

    private var summaries: [TaskDailySummary] {
        model.taskSummaries()
    }

    private var canAddTask: Bool {
        FocusTask(title: newTaskTitle) != nil
    }

    private func addTask() {
        if model.addTask(newTaskTitle) {
            newTaskTitle = ""
            taskFieldFocused = false
        }
    }
}

private struct TaskBoardHero: View {
    let finishedPomodoros: Int
    let timeSpentMs: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                RouteClockMark(compact: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TODAY'S ROUTES")
                        .font(.caption.monospaced().bold())
                        .tracking(1.4)
                        .foregroundStyle(PomodoroughTheme.ticket)
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                        .font(.title3.weight(.bold))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                TaskBoardMetric(label: "FINISHED", value: "\(finishedPomodoros)")
                Divider()
                    .overlay(PomodoroughTheme.steel.opacity(0.5))
                    .padding(.horizontal, 18)
                TaskBoardMetric(label: "FOCUS TIME", value: TaskTimeText.compact(timeSpentMs))
            }
        }
        .padding(18)
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(PomodoroughTheme.platform)
                .shadow(color: PomodoroughTheme.signal.opacity(0.9), radius: 0, x: 6, y: 6)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TaskBoardMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.sky)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .black))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TaskComposer: View {
    @Binding var title: String
    var focused: FocusState<Bool>.Binding
    let canAdd: Bool
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADD A ROUTE")
                .font(.caption2.monospaced().bold())
                .tracking(1.2)
                .foregroundStyle(PomodoroughTheme.platform)
            HStack(spacing: 10) {
                TextField("What are you focusing on?", text: $title)
                    .focused(focused)
                    .submitLabel(.done)
                    .onSubmit(add)
                Button("Add", systemImage: "plus", action: add)
                    .buttonStyle(.borderedProminent)
                    .tint(PomodoroughTheme.signal)
                    .disabled(!canAdd)
            }
        }
        .padding(16)
        .background(PomodoroughTheme.porcelain, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PomodoroughTheme.track, lineWidth: 2)
        }
    }
}

private struct TaskBoardHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("TASK")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("DONE")
                .frame(width: 48, alignment: .trailing)
            Text("TIME")
                .frame(width: 70, alignment: .trailing)
            Color.clear.frame(width: 32, height: 1)
        }
        .font(.caption2.monospaced().bold())
        .foregroundStyle(PomodoroughTheme.sky)
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .background(PomodoroughTheme.track)
        .accessibilityHidden(true)
    }
}

private struct TaskBoardEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "signpost.right.and.left")
                .font(.title2)
                .foregroundStyle(PomodoroughTheme.signal)
                .accessibilityHidden(true)
            Text("No routes posted")
                .font(.headline)
            Text("Add a task, then assign it before starting focus.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
        .accessibilityElement(children: .combine)
    }
}

private struct TaskSummaryRow: View {
    let summary: TaskDailySummary
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(summary.task.title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(summary.finishedPomodoros)")
                .frame(width: 48, alignment: .trailing)
            Text(TaskTimeText.compact(summary.timeSpentMs))
                .frame(width: 70, alignment: .trailing)
            Button("Delete \(summary.task.title)", systemImage: "trash", role: .destructive, action: delete)
                .labelStyle(.iconOnly)
                .foregroundStyle(PomodoroughTheme.danger)
                .frame(width: 32, height: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .monospacedDigit()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(summary.task.title), \(summary.finishedPomodoros) finished pomodoros today, \(TaskTimeText.spoken(summary.timeSpentMs)) spent")
    }
}

private enum TaskTimeText {
    static func compact(_ milliseconds: Int64) -> String {
        let minutes = Int(milliseconds / 60_000)
        guard minutes >= 60 else { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }

    static func spoken(_ milliseconds: Int64) -> String {
        let minutes = Int(milliseconds / 60_000)
        guard minutes >= 60 else { return "\(minutes) minutes" }
        let remainder = minutes % 60
        return remainder == 0
            ? "\(minutes / 60) hours"
            : "\(minutes / 60) hours \(remainder) minutes"
    }
}

private struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(spacing: 14) {
            Text(item.phase.abbreviation)
                .font(.caption.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.porcelain)
                .frame(width: 44, height: 44)
                .background(PomodoroughTheme.platform, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.phase.title).font(.headline)
                HStack {
                    Text(item.status.capitalized)
                    if let date = item.date { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(item.minutes) MIN")
                .font(.caption.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.porcelain)
                .padding(8)
                .background(PomodoroughTheme.platform, in: .rect(cornerRadius: 7))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.phase.title), \(item.status), \(item.minutes) minutes")
        .accessibilityValue(item.date?.formatted(date: .abbreviated, time: .shortened) ?? "Time not recorded")
    }
}

private struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSignOut = false
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let user = model.user {
                    Section {
                        HStack(spacing: 14) {
                            AsyncImage(url: URL(string: user.avatarUrl)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.crop.circle.fill").resizable()
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(.circle)
                            VStack(alignment: .leading) {
                                Text(user.name).font(.headline)
                                Text(user.email).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    Section {
                        Label("Timer works without internet", systemImage: "iphone")
                        GoogleSignInButton(action: model.signIn)
                            .frame(maxWidth: 280)
                            .disabled(model.isWorking)
                            .accessibilityHint("Signs in to sync your timer across devices")
                        if model.isWorking {
                            ProgressView("Opening Google")
                        }
                    } header: {
                        Text("On-device mode")
                    } footer: {
                        Text("Sign in only if you want to sync this timer and its history across devices.")
                    }
                }
                Section("Line status") {
                    LabeledContent("Sync", value: model.syncLabel)
                    LabeledContent("Device", value: model.deviceMark)
                    LabeledContent("Completed focus runs", value: "\(model.completedFocusCount)")
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.sync(force: true) }
                    }
                    .disabled(!model.isSignedIn || model.isSyncing)
                }
                if model.isSignedIn {
                    Section {
                        Button("Sign out", role: .destructive) { confirmsSignOut = true }
                            .disabled(model.isWorking)
                    } footer: {
                        Text("Pending changes are stored on this device until they can sync.")
                    }
                }
            }
            .navigationTitle("Account")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of Pomodorough?", isPresented: $confirmsSignOut) {
                Button("Sign out", role: .destructive, action: model.signOut)
                Button("Cancel", role: .cancel) { }
            } message: {
                if model.pendingChangeCount > 0 {
                    Text("This will discard \(model.pendingChangeCount) changes still waiting to sync.")
                } else {
                    Text("Local account and timer data will be removed from this device.")
                }
            }
        }
    }
}

private struct SectionHeading: View {
    let kicker: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Text(kicker)
                .font(.caption2.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.porcelain)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(PomodoroughTheme.platform, in: .capsule)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RouteClockMark: View {
    var compact = false

    var body: some View {
        ZStack {
            Circle().fill(PomodoroughTheme.ticket)
            Circle().stroke(PomodoroughTheme.porcelain, lineWidth: compact ? 2 : 4)
            Circle().stroke(PomodoroughTheme.platform, lineWidth: compact ? 4 : 8).padding(compact ? 5 : 8)
            Text("P")
                .font(.system(size: compact ? 20 : 42, weight: .black, design: .rounded))
                .foregroundStyle(PomodoroughTheme.platform)
        }
        .frame(width: compact ? 44 : 88, height: compact ? 44 : 88)
        .accessibilityHidden(true)
    }
}

private struct RailwayBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [PomodoroughTheme.platformDeep, PomodoroughTheme.platform], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                let color = PomodoroughTheme.porcelain.opacity(0.08)
                for x in stride(from: 0.0, through: size.width, by: 48) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(color), lineWidth: 1)
                }
                for y in stride(from: 0.0, through: size.height, by: 48) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(color), lineWidth: 1)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private enum PomodoroughTheme {
    static let platform = Color(red: 20 / 255, green: 44 / 255, blue: 92 / 255)
    static let platformDeep = Color(red: 12 / 255, green: 27 / 255, blue: 57 / 255)
    static let signal = Color(red: 255 / 255, green: 96 / 255, blue: 79 / 255)
    static let ticket = Color(red: 245 / 255, green: 208 / 255, blue: 91 / 255)
    static let sky = Color(red: 220 / 255, green: 234 / 255, blue: 241 / 255)
    static let porcelain = Color(red: 247 / 255, green: 248 / 255, blue: 242 / 255)
    static let track = Color(red: 17 / 255, green: 25 / 255, blue: 35 / 255)
    static let steel = Color(red: 143 / 255, green: 168 / 255, blue: 184 / 255)
    static let mint = Color(red: 168 / 255, green: 217 / 255, blue: 203 / 255)
    static let danger = Color(red: 195 / 255, green: 61 / 255, blue: 56 / 255)
}

private extension View {
    @ViewBuilder
    func timerChromeHidden(_ hidden: Bool) -> some View {
#if os(iOS)
        toolbar(hidden ? .hidden : .visible, for: .navigationBar)
            .toolbar(hidden ? .hidden : .visible, for: .tabBar)
#else
        self
#endif
    }

    @ViewBuilder
    func inlineNavigationTitleIfSupported() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    func glassPanel() -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.tint(PomodoroughTheme.platform.opacity(0.58)), in: .rect(cornerRadius: 28))
        } else {
            background(PomodoroughTheme.platform.opacity(0.88), in: .rect(cornerRadius: 28))
        }
    }

    @ViewBuilder
    func digitalReadoutPanel(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(
                .regular.tint(PomodoroughTheme.track.opacity(0.66)),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            background(PomodoroughTheme.track, in: .rect(cornerRadius: cornerRadius))
        }
    }
}
