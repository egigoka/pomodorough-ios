import Foundation

#if os(iOS)
import AlarmKit
import SwiftUI
#endif

@MainActor
protocol TimerAlarmScheduling: AnyObject {
    func schedule(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws
    func pause(timerID: String) throws
    func resume(timerID: String) throws
    func cancel(timerID: String) throws
}

enum TimerAlarmError: LocalizedError {
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Allow alarms in Settings to receive timer alerts when Pomodorough is not open."
        }
    }
}

@MainActor
final class TimerAlarmScheduler: TimerAlarmScheduling {
    func schedule(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
#if os(iOS)
        guard #available(iOS 26.0, *), let alarmID = Self.alarmID(for: timerID) else { return }
        let manager = AlarmManager.shared
        let authorization: AlarmManager.AuthorizationState
        switch manager.authorizationState {
        case .notDetermined:
            authorization = try await manager.requestAuthorization()
        case .denied:
            authorization = .denied
        case .authorized:
            authorization = .authorized
        @unknown default:
            authorization = .denied
        }
        guard authorization == .authorized else { throw TimerAlarmError.authorizationDenied }

        let alert = Self.alert(for: phase)
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: TimerAlarmMetadata(timerID: timerID, phase: phase.rawValue),
            tintColor: Color(red: 1, green: 96.0 / 255.0, blue: 79.0 / 255.0)
        )
        let configuration = AlarmManager.AlarmConfiguration<TimerAlarmMetadata>.timer(
            duration: max(1, duration),
            attributes: attributes
        )
        _ = try await manager.schedule(id: alarmID, configuration: configuration)
#endif
    }

    func pause(timerID: String) throws {
#if os(iOS)
        guard #available(iOS 26.0, *), let alarmID = Self.alarmID(for: timerID) else { return }
        try AlarmManager.shared.pause(id: alarmID)
#endif
    }

    func resume(timerID: String) throws {
#if os(iOS)
        guard #available(iOS 26.0, *), let alarmID = Self.alarmID(for: timerID) else { return }
        try AlarmManager.shared.resume(id: alarmID)
#endif
    }

    func cancel(timerID: String) throws {
#if os(iOS)
        guard #available(iOS 26.0, *), let alarmID = Self.alarmID(for: timerID) else { return }
        try AlarmManager.shared.cancel(id: alarmID)
#endif
    }

    nonisolated static func alarmID(for timerID: String) -> UUID? {
        guard timerID.hasPrefix("timer-") else { return nil }
        return UUID(uuidString: String(timerID.dropFirst("timer-".count)))
    }
}

#if os(iOS)
@available(iOS 26.0, *)
private struct TimerAlarmMetadata: AlarmMetadata {
    let timerID: String
    let phase: String
}

@available(iOS 26.0, *)
private extension TimerAlarmScheduler {
    static func alert(for phase: TimerPhase) -> AlarmPresentation.Alert {
        let title: LocalizedStringResource = switch phase {
        case .focus: "Focus complete"
        case .shortBreak: "Short break complete"
        case .longBreak: "Long break complete"
        }
        if #available(iOS 26.1, *) {
            return AlarmPresentation.Alert(title: title)
        }
        return legacyAlert(title: title)
    }

    @available(iOS, introduced: 26.0, obsoleted: 26.1)
    static func legacyAlert(title: LocalizedStringResource) -> AlarmPresentation.Alert {
        AlarmPresentation.Alert(
            title: title,
            stopButton: AlarmButton(text: "Done", textColor: .white, systemImageName: "stop.circle.fill")
        )
    }
}
#endif
