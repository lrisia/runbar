import Foundation

public struct CronError: Error, CustomStringConvertible, Equatable {
    public var description: String
}

/// Standard 5-field cron: minute hour day-of-month month day-of-week.
/// Supports `*`, lists, ranges, steps, month/day names and the @hourly-style macros.
/// When both day fields are restricted, a day matches if either one does (as in cron).
public struct CronSchedule: Equatable, Sendable {
    public let expression: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>  // 0 = Sunday
    let daysRestricted: Bool
    let weekdaysRestricted: Bool

    static let macros: [String: String] = [
        "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *",
        "@weekly": "0 0 * * 0", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
        "@hourly": "0 * * * *",
    ]
    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    public init(_ expression: String) throws {
        self.expression = expression
        let trimmed = expression.trimmingCharacters(in: .whitespaces).lowercased()
        let expanded = Self.macros[trimmed] ?? trimmed
        let fields = expanded.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else {
            throw CronError(description: "expected 5 fields (minute hour day month weekday), got \(fields.count)")
        }
        minutes = try Self.parseField(fields[0], name: "minute", range: 0...59, names: [])
        hours = try Self.parseField(fields[1], name: "hour", range: 0...23, names: [])
        days = try Self.parseField(fields[2], name: "day", range: 1...31, names: [])
        months = try Self.parseField(fields[3], name: "month", range: 1...12, names: Self.monthNames, nameBase: 1)
        let rawWeekdays = try Self.parseField(fields[4], name: "weekday", range: 0...7, names: Self.dayNames)
        weekdays = Set(rawWeekdays.map { $0 == 7 ? 0 : $0 })
        daysRestricted = !fields[2].hasPrefix("*")
        weekdaysRestricted = !fields[4].hasPrefix("*")
    }

    static func parseField(_ field: String, name: String, range: ClosedRange<Int>, names: [String], nameBase: Int = 0) throws -> Set<Int> {
        func value(_ token: String) throws -> Int {
            if let n = Int(token) {
                guard range.contains(n) else {
                    throw CronError(description: "\(name) value \(n) is outside \(range.lowerBound)-\(range.upperBound)")
                }
                return n
            }
            if let index = names.firstIndex(of: token) { return index + nameBase }
            throw CronError(description: "bad \(name) value \"\(token)\"")
        }

        var result = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !part.isEmpty else { throw CronError(description: "empty item in \(name) field") }
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count <= 2 else { throw CronError(description: "bad step in \(name) field \"\(part)\"") }
            var step = 1
            if pieces.count == 2 {
                guard let s = Int(pieces[1]), s > 0 else {
                    throw CronError(description: "bad step in \(name) field \"\(part)\"")
                }
                step = s
            }
            let base = pieces[0]
            let lower: Int
            let upper: Int
            if base == "*" {
                lower = range.lowerBound
                upper = range.upperBound
            } else if let dash = base.firstIndex(of: "-") {
                lower = try value(String(base[..<dash]))
                upper = try value(String(base[base.index(after: dash)...]))
                guard lower <= upper else {
                    throw CronError(description: "range \(base) in \(name) field runs backwards")
                }
            } else {
                lower = try value(base)
                // "5/15" means "from 5 to the end, every 15".
                upper = pieces.count == 2 ? range.upperBound : lower
            }
            result.formUnion(stride(from: lower, through: upper, by: step))
        }
        return result
    }

    func dayMatches(day: Int, weekday: Int) -> Bool {
        switch (daysRestricted, weekdaysRestricted) {
        case (true, true): return days.contains(day) || weekdays.contains(weekday)
        case (true, false): return days.contains(day)
        case (false, true): return weekdays.contains(weekday)
        case (false, false): return true
        }
    }

    /// The first matching minute strictly after `date`.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .weekday]
        guard let floored = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)),
              var current = calendar.date(byAdding: .minute, value: 1, to: floored)
        else { return nil }

        // Each step jumps at least one minute; 5 years of whole-day/hour jumps fits easily.
        for _ in 0..<200_000 {
            let c = calendar.dateComponents(units, from: current)
            guard let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute,
                  let weekday = c.weekday, let year = c.year
            else { return nil }

            if year > (calendar.component(.year, from: date) + 5) { return nil }

            if !months.contains(month) {
                guard let startOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                      let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth)
                else { return nil }
                current = nextMonth
                continue
            }
            if !dayMatches(day: day, weekday: weekday - 1) {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current))
                else { return nil }
                current = nextDay
                continue
            }
            if !hours.contains(hour) {
                guard let startOfHour = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)),
                      let nextHour = calendar.date(byAdding: .hour, value: 1, to: startOfHour)
                else { return nil }
                current = nextHour
                continue
            }
            if !minutes.contains(minute) {
                guard let nextMinute = calendar.date(byAdding: .minute, value: 1, to: current) else { return nil }
                current = nextMinute
                continue
            }
            return current
        }
        return nil
    }
}
