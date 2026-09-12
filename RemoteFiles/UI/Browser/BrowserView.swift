import Foundation
import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var connections: ConnectionStore
    @EnvironmentObject private var transfers: TransferEngine
    @EnvironmentObject private var offline: OfflineStore

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
    @State private var selectionMode = false
    @State private var selectedPaths: Set<String> = []
    @State private var showingBatchDeleteConfirmation = false
    @State private var permissionItem: RemoteItem?
    @State private var accessControlItem: RemoteItem?
    @State private var copyItem: RemoteItem?
    @State private var pendingDeleteItem: RemoteItem?
    @State private var offlineWorkingPath: String?
    @FocusState private var searchFocused: Bool

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
                if selectionMode {
                    Button("Done") { endSelection() }
                } else {
                    if model.canGoUp {
                        Button { Task { await model.goUp() } } label: { Image(systemName: "arrow.up") }
                    }
                    if model.capabilities.contains(.delete), !model.items.isEmpty {
                        Button { selectionMode = true } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .accessibilityLabel("Select Items")
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
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectionMode { selectionBar }
        }
        .onChange(of: searchText) { _, _ in displayLimit = 200 }
        .onChange(of: model.items) { _, items in
            selectedPaths.formIntersection(Set(items.map(\.path)))
        }
        .onChange(of: model.currentPath) { _, _ in
            displayLimit = 200
            endSelection()
        }
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
        .alert("Delete Selected Items?", isPresented: $showingBatchDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                let items = model.items.filter { selectedPaths.contains($0.path) }
                endSelection()
                Task { await model.delete(items) }
            }
        } message: {
            Text("This permanently deletes \(selectedPaths.count) selected item(s). Non-empty folders and their contents will also be deleted.")
        }
        .alert("Delete Folder?", isPresented: Binding(
            get: { pendingDeleteItem != nil },
            set: { if !$0 { pendingDeleteItem = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeleteItem = nil }
            Button("Delete", role: .destructive) {
                guard let item = pendingDeleteItem else { return }
                pendingDeleteItem = nil
                Task { await model.delete(item) }
            }
        } message: {
            Text("This permanently deletes the folder and everything inside it.")
        }
        .sheet(item: $permissionItem, onDismiss: {
            Task { await model.refresh() }
        }) { item in
            if let provider = model.provider {
                PermissionsEditorView(provider: provider, item: item)
            }
        }
        .sheet(item: $accessControlItem) { item in
            if let provider = model.provider {
                AccessControlView(provider: provider, item: item)
            }
        }
        .sheet(item: $copyItem) { item in
            if let provider = model.provider {
                CopyDestinationView(
                    profiles: connections.profiles.filter { $0.id != provider.profile.id },
                    fileName: item.name
                ) { destination in
                    do {
                        let destinationProvider = try ProviderFactory.make(for: destination)
                        transfers.copyFile(
                            item: item,
                            from: provider,
                            to: destinationProvider,
                            destinationPath: RemotePath.join(
                                RemotePath.normalize(destination.initialPath),
                                item.name
                            )
                        )
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
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
                if model.uploading || model.loading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(model.uploading ? "Uploading" : "Working")
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search this folder", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
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
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = false }
    }

    private var populatedFileList: some View {
        List {
            ForEach(visibleItems) { item in
                if selectionMode {
                    Button { toggleSelection(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedPaths.contains(item.path) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedPaths.contains(item.path) ? Color.accentColor : Color.secondary)
                            FileRow(item: item, provider: model.provider)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    itemRow(item)
                        .contextMenu {
                            itemContextMenu(item)
                        }
                        .swipeActions(edge: .trailing) {
                            if model.capabilities.contains(.delete) {
                                Button(role: .destructive) {
                                    if item.isDirectory {
                                        pendingDeleteItem = item
                                    } else {
                                        Task { await model.delete(item) }
                                    }
                                } label: {
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
                            if model.capabilities.contains(.permissions) {
                                Button {
                                    permissionItem = item
                                } label: {
                                    Label("Permissions", systemImage: "lock.shield")
                                }
                                .tint(.orange)
                            }
                            if model.capabilities.contains(.accessControl) {
                                Button {
                                    accessControlItem = item
                                } label: {
                                    Label("Access Control", systemImage: "person.badge.key")
                                }
                                .tint(.purple)
                            }
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
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
    }

    private var selectionBar: some View {
        let filteredPaths = Set(filteredItems.map(\.path))
        let allFilteredSelected = !filteredPaths.isEmpty && filteredPaths.isSubset(of: selectedPaths)
        return HStack(spacing: 16) {
            Button(allFilteredSelected ? "Deselect All" : "Select All") {
                if allFilteredSelected {
                    selectedPaths.subtract(filteredPaths)
                } else {
                    selectedPaths.formUnion(filteredPaths)
                }
            }
            Spacer()
            Button(role: .destructive) {
                showingBatchDeleteConfirmation = true
            } label: {
                Label("Delete \(selectedPaths.count)", systemImage: "trash")
            }
            .disabled(selectedPaths.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func toggleSelection(_ item: RemoteItem) {
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
    }

    private func endSelection() {
        selectionMode = false
        selectedPaths.removeAll()
    }

    @ViewBuilder
    private func itemContextMenu(_ item: RemoteItem) -> some View {
        Button("Select", systemImage: "checkmark.circle") {
            selectionMode = true
            selectedPaths = [item.path]
            searchFocused = false
        }

        if !item.isDirectory, let provider = model.provider {
            Button(
                offline.isPinned(profileID: provider.profile.id, path: item.path) ? "Remove Offline Copy" : "Keep Offline",
                systemImage: offline.isPinned(profileID: provider.profile.id, path: item.path) ? "checkmark.circle.fill" : "arrow.down.circle"
            ) {
                Task { await toggleOffline(item, provider: provider) }
            }
            .disabled(offlineWorkingPath != nil)

            Button("Copy to Server", systemImage: "arrow.right.doc.on.clipboard") {
                copyItem = item
            }
        }

        if model.capabilities.contains(.move) {
            Button("Rename", systemImage: "pencil") {
                renameItem = item
                renameText = item.name
            }
        }

        if model.capabilities.contains(.permissions) {
            Button("Permissions", systemImage: "lock.shield") {
                permissionItem = item
            }
        }

        if model.capabilities.contains(.accessControl) {
            Button("Access Control", systemImage: "person.badge.key") {
                accessControlItem = item
            }
        }

        if model.capabilities.contains(.delete) {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                if item.isDirectory {
                    pendingDeleteItem = item
                } else {
                    Task { await model.delete(item) }
                }
            }
        }
    }

    private func toggleOffline(_ item: RemoteItem, provider: any RemoteFileProvider) async {
        offlineWorkingPath = item.path
        defer { offlineWorkingPath = nil }
        if offline.isPinned(profileID: provider.profile.id, path: item.path) {
            offline.unpin(profileID: provider.profile.id, path: item.path)
            return
        }
        do {
            try await offline.pin(provider: provider, item: item)
        } catch {
            model.errorMessage = error.localizedDescription
        }
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
                    if let mode = item.permissions {
                        Text(String(format: "%04o", mode & 0o7777))
                            .fontDesign(.monospaced)
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

