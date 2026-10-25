import XCTest
@testable import WatchDotCore

final class ChatMessageTimestampTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -3 * 3600)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    func testTodayShowsOnlyLocalTime() throws {
        // The UTC dates differ, but both timestamps are October 4 on the watch.
        let message = ChatMessage(role: .assistant, text: "Respuesta",
                                  createdAt: try date("2026-10-04T21:30:00Z"))
        XCTAssertEqual(message.timestampLabel(relativeTo: try date("2026-10-05T02:00:00Z"),
            calendar: calendar, locale: Locale(identifier: "es_CL@hours=h23")), "18:30")
    }

    func testPreviousLocalDayShowsLowercaseMonthDayAndTime() throws {
        // Only one hour elapsed, but midnight passed in the watch's time zone.
        let message = ChatMessage(role: .assistant, text: "Respuesta",
                                  createdAt: try date("2026-10-05T02:30:00Z"))
        XCTAssertEqual(message.timestampLabel(relativeTo: try date("2026-10-05T03:30:00Z"),
            calendar: calendar, locale: Locale(identifier: "es_CL@hours=h23")), "oct-04 23:30")
    }

    func testPreviousYearAlsoShowsDateWithTwoDigitDay() throws {
        let message = ChatMessage(role: .user, text: "Mensaje",
                                  createdAt: try date("2025-10-04T12:05:00Z"))
        XCTAssertEqual(message.timestampLabel(relativeTo: try date("2026-10-04T21:30:00Z"),
            calendar: calendar, locale: Locale(identifier: "es_CL@hours=h23")), "oct-04 09:05")
    }

    func testMonthAbbreviationIsEnglishRegardlessOfDeviceLocale() throws {
        // Spanish would render "ene" and "ago"; labels always use English month names.
        let now = try date("2026-10-04T21:30:00Z")
        let january = ChatMessage(role: .user, text: "Message", createdAt: try date("2026-01-07T15:00:00Z"))
        let august = ChatMessage(role: .user, text: "Message", createdAt: try date("2026-08-07T15:00:00Z"))
        XCTAssertEqual(january.timestampLabel(relativeTo: now, calendar: calendar,
            locale: Locale(identifier: "es_CL@hours=h23")), "jan-07 12:00")
        XCTAssertEqual(august.timestampLabel(relativeTo: now, calendar: calendar,
            locale: Locale(identifier: "es_CL@hours=h23")), "aug-07 12:00")
    }
}
