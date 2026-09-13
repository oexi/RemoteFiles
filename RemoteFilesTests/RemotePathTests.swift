import XCTest
@testable import RemoteFiles

final class RemotePathTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(RemotePath.normalize(""), "/")
        XCTAssertEqual(RemotePath.normalize("foo/bar"), "/foo/bar")
        XCTAssertEqual(RemotePath.normalize("//foo///bar/"), "/foo/bar")
        XCTAssertEqual(RemotePath.normalize("/foo/./bar/../baz"), "/foo/baz")
        XCTAssertEqual(RemotePath.normalize("../../foo"), "/foo")
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

    func testIsDescendantOrEqualUsesPathBoundaries() {
        XCTAssertTrue(RemotePath.isDescendantOrEqual("/root", of: "/root"))
        XCTAssertTrue(RemotePath.isDescendantOrEqual("/root/child", of: "/root"))
        XCTAssertFalse(RemotePath.isDescendantOrEqual("/root2", of: "/root"))
        XCTAssertFalse(RemotePath.isDescendantOrEqual("/root/../outside", of: "/root"))
        XCTAssertTrue(RemotePath.isDescendantOrEqual("/child", of: "/"))
        XCTAssertTrue(RemotePath.isDescendantOrEqual("/", of: "/"))
    }

    func testIsDirectChildUsesCanonicalComponents() {
        XCTAssertTrue(RemotePath.isDirectChild("/root/file", of: "/root"))
        XCTAssertTrue(RemotePath.isDirectChild("/root/./file", of: "/root"))
        XCTAssertFalse(RemotePath.isDirectChild("/root/folder/file", of: "/root"))
        XCTAssertFalse(RemotePath.isDirectChild("/root2/file", of: "/root"))
        XCTAssertTrue(RemotePath.isDirectChild("/file", of: "/"))
        XCTAssertFalse(RemotePath.isDirectChild("/", of: "/"))
    }

    func testConfinedCanonicalizesAndRejectsTraversal() {
        XCTAssertEqual(RemotePath.confined("/root/child/./file", to: "/root"), "/root/child/file")
        XCTAssertNil(RemotePath.confined("/root/child/../../outside", to: "/root"))
        XCTAssertNil(RemotePath.confined("/root2/file", to: "/root"))
        XCTAssertEqual(RemotePath.confined("/file", to: "/"), "/file")
    }
}
