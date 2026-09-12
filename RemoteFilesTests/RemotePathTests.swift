import XCTest
@testable import RemoteFiles

final class RemotePathTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(RemotePath.normalize(""), "/")
        XCTAssertEqual(RemotePath.normalize("foo/bar"), "/foo/bar")
        XCTAssertEqual(RemotePath.normalize("//foo///bar/"), "/foo/bar")
    }

    func testJoin() {
        XCTAssertEqual(RemotePath.join("/", "file.txt"), "/file.txt")
        XCTAssertEqual(RemotePath.join("/a/b", "c"), "/a/b/c")
    }

    func testParent() {
        XCTAssertEqual(RemotePath.parent("/"), "/")
        XCTAssertEqual(RemotePath.parent("/a"), "/")
        XCTAssertEqual(RemotePath.parent("/a/b"), "/a")
    }
}

