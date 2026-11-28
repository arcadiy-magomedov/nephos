import Foundation
import Testing
import XCTest

@testable import NephosCore

final class LocalMediaTests: XCTestCase {
    func testChronologyGroupsInTheUsersCalendarAndPreservesAssetIdentity() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        let midnightUTC = Date(timeIntervalSince1970: 1_767_225_600)
        let items = [
            item("newer", midnightUTC.addingTimeInterval(6 * 3600)),
            item("older", midnightUTC.addingTimeInterval(4 * 3600)),
            item("same-day", midnightUTC),
            item("unknown", nil),
        ]
        let groups = LocalMediaDay.group(items, calendar: calendar)
        XCTAssertEqual(groups.map { $0.items.map(\.id) }, [["newer"], ["older", "same-day"], ["unknown"]])
        XCTAssertNil(groups.last?.id)
        XCTAssertEqual(groups.first?.id, calendar.startOfDay(for: items[0].capturedAt!))
    }

    func testDurationSupportsLongVideosAndUnknownValues() {
        XCTAssertEqual(LocalMediaItem.playbackTime(12.8), "0:12")
        XCTAssertEqual(LocalMediaItem.playbackTime(3601), "1:00:01")
        XCTAssertEqual(LocalMediaItem.playbackTime(.nan), "0:00")
        XCTAssertEqual(LocalMediaItem.playbackTime(-1), "0:00")
    }

    private func item(_ id: String, _ date: Date?) -> LocalMediaItem {
        LocalMediaItem(
            id: id, kind: .photo, capturedAt: date, modifiedAt: nil, duration: 0, pixelWidth: 100, pixelHeight: 100)
    }
}

struct PlaybackTimeTests {
    @Test(
        "Playback time truncates fractional seconds at minute and hour boundaries",
        arguments: [
            (0.0, "0:00"), (59.9, "0:59"), (60.0, "1:00"), (3599.9, "59:59"),
            (3600.0, "1:00:00"), (3601.9, "1:00:01"), (TimeInterval.infinity, "0:00"),
        ])
    func playbackTime(seconds: TimeInterval, expected: String) {
        let formatted = LocalMediaItem.playbackTime(seconds)

        #expect(formatted == expected)
    }
}
