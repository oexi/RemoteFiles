import XCTest
@testable import RemoteFiles

@MainActor
final class LocationHistoryStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocationHistoryStoreTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testToggleFavoriteAddsAndRemovesByNormalizedPath() {
        let store = LocationHistoryStore(fileURL: fileURL)
        let profile = UUID()

        store.toggleFavorite(profileID: profile, path: "/media/", name: "media", isDirectory: true)
        XCTAssertTrue(store.isFavorite(profileID: profile, path: "/media"))
        XCTAssertFalse(store.isFavorite(profileID: UUID(), path: "/media"))

        store.toggleFavorite(profileID: profile, path: "/media", name: "media", isDirectory: true)
        XCTAssertTrue(store.favorites.isEmpty)
    }

    func testRecentsMoveReopenedItemToTopWithoutDuplicates() {
        let store = LocationHistoryStore(fileURL: fileURL)
        let profile = UUID()

        store.recordOpened(profileID: profile, path: "/a.txt", name: "a.txt")
        store.recordOpened(profileID: profile, path: "/b.txt", name: "b.txt")
        store.recordOpened(profileID: profile, path: "/a.txt", name: "a.txt")

        XCTAssertEqual(store.recents.map(\.path), ["/a.txt", "/b.txt"])
    }

    func testRecentsAreCapped() {
        let store = LocationHistoryStore(fileURL: fileURL)
        let profile = UUID()

        for index in 0..<(LocationHistoryStore.recentLimit + 5) {
            store.recordOpened(profileID: profile, path: "/\(index)", name: "\(index)")
        }

        XCTAssertEqual(store.recents.count, LocationHistoryStore.recentLimit)
        XCTAssertEqual(store.recents.first?.path, "/\(LocationHistoryStore.recentLimit + 4)")
    }

    func testRemoveAllForProfileKeepsOtherConnections() {
        let store = LocationHistoryStore(fileURL: fileURL)
        let removed = UUID()
        let kept = UUID()
        store.toggleFavorite(profileID: removed, path: "/x", name: "x", isDirectory: true)
        store.toggleFavorite(profileID: kept, path: "/y", name: "y", isDirectory: true)
        store.recordOpened(profileID: removed, path: "/x/file", name: "file")

        store.removeAll(for: removed)

        XCTAssertEqual(store.favorites.map(\.profileID), [kept])
        XCTAssertTrue(store.recents.isEmpty)
    }

    func testStatePersistsAcrossInstances() {
        let profile = UUID()
        do {
            let store = LocationHistoryStore(fileURL: fileURL)
            store.toggleFavorite(profileID: profile, path: "/docs", name: "docs", isDirectory: true)
            store.recordOpened(profileID: profile, path: "/docs/a.pdf", name: "a.pdf")
        }

        let reloaded = LocationHistoryStore(fileURL: fileURL)
        XCTAssertTrue(reloaded.isFavorite(profileID: profile, path: "/docs"))
        XCTAssertEqual(reloaded.recents.map(\.name), ["a.pdf"])
    }
}
