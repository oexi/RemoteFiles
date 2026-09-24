import XCTest
@testable import RemoteFiles

final class ArchiveTreeTests: XCTestCase {
    func testImpliedFoldersAreCreatedAndAggregated() {
        let nodes = ArchiveTree.build(from: [
            entry("docs/a.txt", size: 10),
            entry("docs/sub/b.txt", size: 5),
            entry("readme.md", size: 1)
        ])

        XCTAssertEqual(nodes.map(\.name), ["docs", "readme.md"])
        let docs = nodes[0]
        XCTAssertTrue(docs.isDirectory)
        XCTAssertNil(docs.entryPath)
        XCTAssertEqual(docs.fileCount, 2)
        XCTAssertEqual(docs.totalSize, 15)
        XCTAssertEqual(docs.children.map(\.name), ["sub", "a.txt"])
        XCTAssertEqual(docs.children[0].children.first?.path, "docs/sub/b.txt")
        XCTAssertEqual(docs.children[0].children.first?.entryPath, "docs/sub/b.txt")
    }

    func testExplicitFolderEntriesAndDotPrefixesMerge() {
        let nodes = ArchiveTree.build(from: [
            entry("./pkg/", kind: .directory),
            entry("./pkg/bin/tool", size: 3),
            entry("pkg/lib.a", size: 4)
        ])

        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].path, "pkg")
        XCTAssertEqual(nodes[0].entryPath, "./pkg/")
        XCTAssertEqual(nodes[0].children.map(\.path), ["pkg/bin", "pkg/lib.a"])
        XCTAssertEqual(nodes[0].children[1].entryPath, "pkg/lib.a")
    }

    func testChildrenSortFoldersFirstThenNaturalName() {
        let nodes = ArchiveTree.build(from: [
            entry("file10.txt"),
            entry("file2.txt"),
            entry("zeta/x"),
            entry("Alpha/y")
        ])

        XCTAssertEqual(nodes.map(\.name), ["Alpha", "zeta", "file2.txt", "file10.txt"])
    }

    func testSummaryCountsFilesFoldersAndBytes() {
        let nodes = ArchiveTree.build(from: [
            entry("a/b/c.txt", size: 7),
            entry("a/d.txt", size: 3),
            entry("e/", kind: .directory),
            entry("link", kind: .symbolicLink)
        ])

        XCTAssertEqual(
            ArchiveTree.summary(of: nodes),
            ArchiveSummary(fileCount: 2, folderCount: 3, totalSize: 10)
        )
    }

    func testSearchFindsNestedNodes() {
        let nodes = ArchiveTree.build(from: [
            entry("src/Main.swift"),
            entry("src/util/mainHelper.swift"),
            entry("README")
        ])

        XCTAssertEqual(
            ArchiveTree.search(nodes, matching: "main").map(\.path),
            ["src/util/mainHelper.swift", "src/Main.swift"]
        )
    }

    private func entry(_ path: String, kind: RemoteItemKind = .file, size: UInt64 = 0) -> ArchiveEntryInfo {
        ArchiveEntryInfo(path: path, kind: kind, uncompressedSize: size, compressedSize: 0)
    }
}
