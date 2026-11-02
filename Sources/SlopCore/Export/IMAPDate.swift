import Foundation
import NIOIMAP

/// An IMAP INTERNALDATE, kept exactly as the server gave it (including its time zone) so it can
/// be sent back unchanged in APPEND and written into mbox `From ` lines.
public struct IMAPDate: Codable, Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int
    public var second: Int
    /// Offset from UTC in minutes.
    public var zoneMinutes: Int

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, zoneMinutes: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.zoneMinutes = zoneMinutes
    }

    init(_ date: ServerMessageDate) {
        let c = date.components
        self.init(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute, second: c.second,
                  zoneMinutes: c.zoneMinutes)
    }

    var serverMessageDate: ServerMessageDate? {
        ServerMessageDate.Components(year: year, month: month, day: day, hour: hour, minute: minute, second: second,
                                     timeZoneMinutes: zoneMinutes).map(ServerMessageDate.init)
    }

    /// The instant this date refers to.
    public var date: Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: zoneMinutes * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone!
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    public init(date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!, hour: c.hour!, minute: c.minute!, second: c.second!,
                  zoneMinutes: 0)
    }
}
