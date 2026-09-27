import Foundation
import XCTest
@testable import RemoteFiles

final class RecentFileGroupTests: XCTestCase {
    func testGroupsByDayKeepingOrderAndSkippingEmptyGroups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let profile = ConnectionProfile.empty(for: .sftp)
        let now = Date()
        func entry(_ name: String, daysAgo: Int) -> VisibleBookmark {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let bookmark = LocationBookmark(profileID: profile.id, path: "/\(name)", name: name, isDirectory: false, date: date)
            return VisibleBookmark(bookmark: bookmark, profile: profile)
        }

        let groups = RecentFileGroup.grouping(
            [entry("a", daysAgo: 0), entry("b", daysAgo: 5), entry("c", daysAgo: 0), entry("d", daysAgo: 9)],
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.period), [.today, .earlier])
        XCTAssertEqual(groups[0].entries.map(\.bookmark.name), ["a", "c"])
        XCTAssertEqual(groups[1].entries.map(\.bookmark.name), ["b", "d"])
    }

    func testRecentsOfDeletedConnectionsAreHidden() {
        let kept = ConnectionProfile.empty(for: .smb)
        let bookmarks = [
            LocationBookmark(profileID: kept.id, path: "/x", name: "x", isDirectory: false, date: Date()),
            LocationBookmark(profileID: UUID(), path: "/y", name: "y", isDirectory: false, date: Date()),
        ]

        XCTAssertEqual(VisibleBookmark.resolve(bookmarks, profiles: [kept]).map(\.bookmark.name), ["x"])
    }
}
