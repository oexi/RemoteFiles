import SwiftUI

/// Shows an archive's entries as an expandable folder tree with a summary header.
struct ArchiveTreeView: View {
    let archiveURL: URL
    let archiveName: String

    private let nodes: [ArchiveTreeNode]
    private let summary: ArchiveSummary
    private let archiveSize: Int64?

    @State private var expanded: Set<String>
    @State private var searchText = ""

    /// `nodes` comes from `ArchiveTree.build(from:)`; build it once when the archive loads.
    init(nodes: [ArchiveTreeNode], archiveURL: URL, archiveName: String) {
        self.archiveURL = archiveURL
        self.archiveName = archiveName
        self.nodes = nodes
        summary = ArchiveTree.summary(of: nodes)
        archiveSize = (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        // A single top-level folder is the usual archive layout; open it right away.
        if nodes.count == 1, let only = nodes.first, only.isDirectory {
            _expanded = State(initialValue: [only.path])
        } else {
            _expanded = State(initialValue: [])
        }
    }

    var body: some View {
        List {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                summarySection
                Section {
                    ForEach(nodes) { node in
                        ArchiveTreeNodeView(
                            node: node,
                            expanded: $expanded,
                            archiveURL: archiveURL,
                            archiveName: archiveName
                        )
                    }
                }
            } else {
                let matches = ArchiveTree.search(nodes, matching: query)
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(matches) { node in
                        ArchiveEntryLink(node: node, archiveURL: archiveURL, archiveName: archiveName) {
                            ArchiveTreeRow(node: node, showsPath: true)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search archive")
    }

    private var summarySection: some View {
        Section {
            LabeledContent("Files", value: "\(summary.fileCount)")
            LabeledContent("Folders", value: "\(summary.folderCount)")
            LabeledContent(
                "Uncompressed Size",
                value: ByteCountFormatter.string(fromByteCount: Int64(clamping: summary.totalSize), countStyle: .file)
            )
            if let archiveSize {
                LabeledContent(
                    "Archive Size",
                    value: ByteCountFormatter.string(fromByteCount: archiveSize, countStyle: .file)
                )
                if summary.totalSize > 0 {
                    LabeledContent(
                        "Compression Ratio",
                        value: (Double(archiveSize) / Double(summary.totalSize))
                            .formatted(.percent.precision(.fractionLength(0...1)))
                    )
                }
            }
        }
    }
}

private struct ArchiveTreeNodeView: View {
    let node: ArchiveTreeNode
    @Binding var expanded: Set<String>
    let archiveURL: URL
    let archiveName: String

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children) { child in
                    ArchiveTreeNodeView(
                        node: child,
                        expanded: $expanded,
                        archiveURL: archiveURL,
                        archiveName: archiveName
                    )
                }
            } label: {
                ArchiveTreeRow(node: node, showsPath: false)
            }
        } else {
            ArchiveEntryLink(node: node, archiveURL: archiveURL, archiveName: archiveName) {
                ArchiveTreeRow(node: node, showsPath: false)
            }
        }
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.path) },
            set: { isOpen in
                if isOpen { expanded.insert(node.path) } else { expanded.remove(node.path) }
            }
        )
    }
}

/// Wraps a regular file in a link that previews that single entry.
private struct ArchiveEntryLink<RowLabel: View>: View {
    let node: ArchiveTreeNode
    let archiveURL: URL
    let archiveName: String
    @ViewBuilder let label: () -> RowLabel

    var body: some View {
        if node.kind == .file, let entryPath = node.entryPath {
            NavigationLink {
                ArchiveEntryPreviewView(
                    archiveURL: archiveURL,
                    archiveName: archiveName,
                    entryPath: entryPath,
                    title: node.name
                )
            } label: {
                label()
            }
        } else {
            label()
        }
    }
}

private struct ArchiveTreeRow: View {
    let node: ArchiveTreeNode
    let showsPath: Bool

    var body: some View {
        HStack(spacing: 10) {
            WhiteSurFileIconView(fileName: node.name, isDirectory: node.isDirectory, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(2)
                if showsPath, node.path != node.name {
                    Text(node.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: node.totalSize), countStyle: .file)
        if node.isDirectory {
            Text("\(node.fileCount) file(s) · \(size)")
        } else if node.kind == .file {
            Text(size)
        }
    }
}

private struct ArchiveEntryPreviewView: View {
    let archiveURL: URL
    let archiveName: String
    let entryPath: String
    let title: String

    @State private var extractedURL: URL?
    @State private var workDirectory: URL?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let extractedURL {
                QuickLookView(url: extractedURL)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Extracting…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await extract() }
        .onDisappear {
            if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        }
    }

    private func extract() async {
        guard extractedURL == nil else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesArchivePreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        workDirectory = directory
        let archiveURL = archiveURL
        let archiveName = archiveName
        let entryPath = entryPath
        do {
            extractedURL = try await Task.detached(priority: .userInitiated) {
                try ArchiveManager.extractEntry(
                    entryPath,
                    from: archiveURL,
                    originalName: archiveName,
                    to: directory
                )
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
