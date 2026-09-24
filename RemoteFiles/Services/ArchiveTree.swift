import Foundation

/// A folder hierarchy built from an archive's flat entry list.
struct ArchiveTreeNode: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    /// Normalized path inside the archive, without leading `./` or trailing `/`.
    let path: String
    let kind: RemoteItemKind
    /// The raw archive member name, or nil for folders the archive only implies.
    let entryPath: String?
    let children: [ArchiveTreeNode]
    /// Regular files at or below this node.
    let fileCount: Int
    /// Uncompressed bytes of the regular files at or below this node.
    let totalSize: UInt64

    var isDirectory: Bool { kind == .directory }
    var outlineChildren: [ArchiveTreeNode]? { isDirectory ? children : nil }
}

struct ArchiveSummary: Equatable, Sendable {
    let fileCount: Int
    let folderCount: Int
    let totalSize: UInt64
}

enum ArchiveTree {
    /// Splits an archive member name into path components, dropping empty and `.` parts.
    static func components(of path: String) -> [String] {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { $0 != "." }
    }

    static func build(from entries: [ArchiveEntryInfo]) -> [ArchiveTreeNode] {
        let root = Builder(name: "", path: "")
        for entry in entries {
            let parts = components(of: entry.path)
            guard !parts.isEmpty else { continue }
            var node = root
            for (index, part) in parts.enumerated() {
                let isLeaf = index == parts.count - 1
                let path = parts[...index].joined(separator: "/")
                let child = node.children[part] ?? Builder(name: part, path: path)
                node.children[part] = child
                if isLeaf {
                    child.entryPath = entry.path
                    child.kind = entry.kind
                    child.size = entry.uncompressedSize
                } else {
                    child.kind = .directory
                }
                node = child
            }
        }
        return root.freezeChildren()
    }

    static func summary(of nodes: [ArchiveTreeNode]) -> ArchiveSummary {
        var folders = 0
        func countFolders(_ nodes: [ArchiveTreeNode]) {
            for node in nodes where node.isDirectory {
                folders += 1
                countFolders(node.children)
            }
        }
        countFolders(nodes)
        return ArchiveSummary(
            fileCount: nodes.reduce(0) { $0 + $1.fileCount },
            folderCount: folders,
            totalSize: nodes.reduce(0) { $0 + $1.totalSize }
        )
    }

    /// All nodes whose name contains `query`, depth first.
    static func search(_ nodes: [ArchiveTreeNode], matching query: String) -> [ArchiveTreeNode] {
        var result: [ArchiveTreeNode] = []
        func visit(_ nodes: [ArchiveTreeNode]) {
            for node in nodes {
                if node.name.localizedCaseInsensitiveContains(query) { result.append(node) }
                visit(node.children)
            }
        }
        visit(nodes)
        return result
    }

    private final class Builder {
        let name: String
        let path: String
        var kind: RemoteItemKind = .directory
        var entryPath: String?
        var size: UInt64 = 0
        var children: [String: Builder] = [:]

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func freeze() -> ArchiveTreeNode {
            let frozen = freezeChildren()
            let isFile = kind == .file
            return ArchiveTreeNode(
                name: name,
                path: path,
                kind: kind,
                entryPath: entryPath,
                children: frozen,
                fileCount: frozen.reduce(isFile ? 1 : 0) { $0 + $1.fileCount },
                totalSize: frozen.reduce(isFile ? size : 0) { $0 + $1.totalSize }
            )
        }

        func freezeChildren() -> [ArchiveTreeNode] {
            children.values.map { $0.freeze() }.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
