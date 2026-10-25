import Foundation

/// The next thing a mode does by itself: the active mode's timer or schedule ending, or a mode's
/// scheduled start, whichever comes first.
public enum ModeAlarm: Sendable, Equatable {
    case stop(modeID: String, at: Date, reason: String)
    case start(modeID: String, at: Date, askFirst: Bool)

    public var date: Date {
        switch self {
        case .stop(_, let date, _), .start(_, let date, _): date
        }
    }

    /// The mode that's on now, as far as alarms care.
    public struct Active: Sendable, Equatable {
        public var modeID: String
        public var started: Date
        public var endsAt: Date?
        public var bySchedule: Bool

        public init(modeID: String, started: Date, endsAt: Date?, bySchedule: Bool) {
            self.modeID = modeID
            self.started = started
            self.endsAt = endsAt
            self.bySchedule = bySchedule
        }
    }

    public static func next(after now: Date, modes: [ModeDefinition], active: Active?, calendar: Calendar = .current) -> ModeAlarm? {
        var alarms: [ModeAlarm] = []
        if let active {
            if let endsAt = active.endsAt { alarms.append(.stop(modeID: active.modeID, at: max(endsAt, now), reason: "its timer ended")) }
            if active.bySchedule, let schedule = modes.first(where: { $0.id == active.modeID })?.schedule,
               let end = schedule.nextEnd(after: active.started, calendar: calendar) {
                alarms.append(.stop(modeID: active.modeID, at: max(end, now), reason: "its scheduled time ended"))
            }
        }
        for mode in modes where mode.id != active?.modeID {
            guard let schedule = mode.schedule, let start = schedule.nextStart(after: now, calendar: calendar) else { continue }
            alarms.append(.start(modeID: mode.id, at: start, askFirst: schedule.askFirst))
        }
        return alarms.min { $0.date < $1.date }
    }
}
