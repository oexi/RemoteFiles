import XCTest
@testable import RemoteFiles

final class BrowserSortingTests: XCTestCase {
    private let old = Date(timeIntervalSince1970: 1_000)
    private let new = Date(timeIntervalSince1970: 2_000)

    func testNameSortIsNaturalWithFoldersFirst() {
        let items = [file("b10.txt"), folder("Zed"), file("b2.txt"), folder("alpha")]

        XCTAssertEqual(names(BrowserSortOrder().sorted(items)), ["alpha", "Zed", "b2.txt", "b10.txt"])
        XCTAssertEqual(
            names(BrowserSortOrder(ascending: false).sorted(items)),
            ["Zed", "alpha", "b10.txt", "b2.txt"]
        )
    }

    func testFoldersFirstCanBeTurnedOff() {
        let items = [folder("m"), file("a"), file("z")]

        XCTAssertEqual(names(BrowserSortOrder(foldersFirst: false).sorted(items)), ["a", "m", "z"])
    }

    func testSizeSortPutsMissingSizesLastInBothDirections() {
        let items = [file("small", size: 1), file("unknown"), file("big", size: 9)]

        XCTAssertEqual(
            names(BrowserSortOrder(key: .size, ascending: false).sorted(items)),
            ["big", "small", "unknown"]
        )
        XCTAssertEqual(
            names(BrowserSortOrder(key: .size, ascending: true).sorted(items)),
            ["small", "big", "unknown"]
        )
    }

    func testDateSortTiesFallBackToAscendingName() {
        let items = [file("b", modified: old), file("a", modified: old), file("c", modified: new)]

        XCTAssertEqual(
            names(BrowserSortOrder(key: .modified, ascending: false).sorted(items)),
            ["c", "a", "b"]
        )
    }

    func testKindSortGroupsByExtension() {
        let items = [file("z.txt"), file("a.png"), file("b.txt"), file("README")]

        XCTAssertEqual(
            names(BrowserSortOrder(key: .kind).sorted(items)),
            ["README", "a.png", "b.txt", "z.txt"]
        )
    }

    private func names(_ items: [RemoteItem]) -> [String] { items.map(\.name) }

    private func file(_ name: String, size: Int64? = nil, modified: Date? = nil) -> RemoteItem {
        RemoteItem(name: name, path: "/" + name, kind: .file, size: size, modifiedAt: modified)
    }

    private func folder(_ name: String) -> RemoteItem {
        RemoteItem(name: name, path: "/" + name, kind: .directory)
    }
}
