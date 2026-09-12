import SwiftUI

struct BrowserView: View {
    private enum ImportSelection {
        case files
        case folder

        var pickerMode: SystemDocumentPicker.Mode {
            switch self {
            case .files: return .files
            case .folder: return .folder
            }
        }
    }

    @StateObject private var model: BrowserViewModel
    @State private var showingFolderPrompt = false
    @State private var newFolderName = ""
    @State private var importSelection: ImportSelection = .files
    @State private var showingImporter = false
    @State private var searchText = ""
    @State private var renameItem: RemoteItem?
    @State private var renameText = ""
    @State private var displayLimit = 200

    init(profile: ConnectionProfile) {
        _model = StateObject(wrappedValue: BrowserViewModel(profile: profile))
    }

    var body: some View {
        VStack(spacing: 0) {
            browserHeader
            fileList
        }
        .navigationTitle(model.profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.canGoUp {
                    Button { Task { await model.goUp() } } label: { Image(systemName: "arrow.up") }
                }
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    if model.capabilities.contains(.createDirectory) {
                        Button("New Folder", systemImage: "folder.badge.plus") { showingFolderPrompt = true }
                    }
                    if model.capabilities.contains(.write) {
                        Button("Upload Files", systemImage: "square.and.arrow.up") {
                            importSelection = .files
                            showingImporter = true
                        }
                        Button("Upload Folder", systemImage: "folder.badge.plus") {
                            importSelection = .folder
                            showingImporter = true
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onChange(of: searchText) { _, _ in displayLimit = 200 }
        .onChange(of: model.currentPath) { _, _ in displayLimit = 200 }
        .task { await model.start() }
        .alert("New Folder", isPresented: $showingFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.createFolder(name: name) }
            }
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "Unknown error") }
        .sheet(isPresented: $showingImporter) {
            SystemDocumentPicker(
                mode: importSelection.pickerMode,
                onPick: { urls in
                    showingImporter = false
                    Task { await model.upload(localURLs: urls) }
                },
                onCancel: {
                    showingImporter = false
                }
            )
            .ignoresSafeArea()
        }
        .alert("Rename", isPresented: Binding(
            get: { renameItem != nil },
            set: { if !$0 { renameItem = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameItem = nil }
            Button("Rename") {
                guard let item = renameItem else { return }
                let name = renameText
                renameItem = nil
                Task { await model.rename(item, to: name) }
            }
        }
    }

    private var browserHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(model.currentPath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if model.uploading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Uploading")
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search this folder", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder
    private var fileList: some View {
        if model.items.isEmpty {
            emptyFolderArea
        } else {
            populatedFileList
        }
    }

    private var emptyFolderArea: some View {
        ZStack {
            EmptyFolderRefreshView {
                await model.refresh()
            }

            if model.loading {
                ProgressView()
            } else if model.errorMessage == nil {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text(model.currentPath)
                )
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var populatedFileList: some View {
        List {
            ForEach(visibleItems) { item in
                itemRow(item)
                    .swipeActions(edge: .trailing) {
                        if model.capabilities.contains(.delete) {
                            Button(role: .destructive) { Task { await model.delete(item) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        if model.capabilities.contains(.move) {
                            Button {
                                renameItem = item
                                renameText = item.name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
            }
            if filteredItems.count > displayLimit {
                Button {
                    displayLimit += 200
                } label: {
                    HStack {
                        Spacer()
                        Text("Load \(min(200, filteredItems.count - displayLimit)) more")
                        Spacer()
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
    }

    private var filteredItems: [RemoteItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.items }
        return model.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var visibleItems: ArraySlice<RemoteItem> {
        filteredItems.prefix(displayLimit)
    }

    @ViewBuilder
    private func itemRow(_ item: RemoteItem) -> some View {
        if item.isDirectory {
            Button { Task { await model.enter(item) } } label: { FileRow(item: item, provider: model.provider) }
                .buttonStyle(.plain)
        } else if let provider = model.provider {
            NavigationLink {
                FileDetailView(provider: provider, item: item)
            } label: { FileRow(item: item, provider: provider) }
        } else {
            FileRow(item: item, provider: nil)
        }
    }
}

private struct FileRow: View {
    let item: RemoteItem
    let provider: (any RemoteFileProvider)?
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: item.isDirectory ? "folder.fill" : iconName)
                        .font(.title3)
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                HStack(spacing: 8) {
                    if let size = item.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let date = item.modifiedAt {
                        Text(date, style: .date)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .task(id: item.id) {
            guard let provider, ThumbnailStore.shared.canThumbnail(item) else { return }
            thumbnail = await ThumbnailStore.shared.thumbnail(
                provider: provider,
                item: item,
                size: CGSize(width: 72, height: 72)
            )
        }
    }

    private var iconName: String {
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ArchiveManager.canOpen(fileName: item.name) { return "archivebox.fill" }
        if EditorLanguage.isEditable(fileName: item.name) { return "doc.text.fill" }
        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) { return "photo.fill" }
        if ["mp4", "mov", "m4v", "mkv"].contains(ext) { return "film.fill" }
        if ext == "pdf" { return "doc.richtext.fill" }
        return "doc.fill"
    }
}

