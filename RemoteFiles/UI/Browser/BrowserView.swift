import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @EnvironmentObject private var connections: ConnectionStore
    @EnvironmentObject private var transfers: TransferEngine
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var clipboard: FileOperationClipboard
    @EnvironmentObject private var history: LocationHistoryStore

    @StateObject private var model: BrowserViewModel
    @State private var showingFolderPrompt = false
    @State private var newFolderName = ""
    @State private var uploadPicker = UploadPicker()
    @State private var showingFolderImporter = false
    @State private var searchText = ""
    @State private var renameItem: RemoteItem?
    @State private var renameText = ""
    @State private var displayLimit = 200
    @State private var selectionMode = false
    @State private var selectedPaths: Set<String> = []
    @State private var showingBatchDeleteConfirmation = false
    @State private var permissionItem: RemoteItem?
    @State private var accessControlItem: RemoteItem?
    @State private var propertiesItem: RemoteItem?
    @State private var copyItem: RemoteItem?
    @State private var pendingDeleteItem: RemoteItem?
    @State private var offlineWorkingPath: String?
    @State private var linkedFile: RemoteItem?
    @FocusState private var searchFocused: Bool
    @AppStorage(AppPreferenceKey.browserSortKey) private var sortKey: BrowserSortKey = .name
    @AppStorage(AppPreferenceKey.browserSortAscending) private var sortAscending = true
    @AppStorage(AppPreferenceKey.browserFoldersFirst) private var foldersFirst = true
    @AppStorage(AppPreferenceKey.browserLayout) private var layout: BrowserLayout = .list

    init(profile: ConnectionProfile, startPath: String? = nil) {
        _model = StateObject(wrappedValue: BrowserViewModel(profile: profile, startPath: startPath))
    }

    private var browserBase: some View {
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
                        viewOptionsMenuContent
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        currentFolderFavoriteButton
                        if !clipboard.isEmpty, model.capabilities.contains(.write) {
                            Button(
                                "Paste \(clipboard.items.count == 1 ? clipboard.items[0].name : "\(clipboard.items.count) Items")",
                                systemImage: "doc.on.clipboard"
                            ) {
                                searchFocused = false
                                Task { await model.paste(clipboard, using: connections, transfers: transfers) }
                            }
                        }
                        if model.capabilities.contains(.createDirectory) {
                            Button("New Folder", systemImage: "folder.badge.plus") { showingFolderPrompt = true }
                        }
                        if model.capabilities.contains(.write) {
                            Button("Upload Files", systemImage: "square.and.arrow.up") {
                                presentUploadPicker(.files)
                            }
                            Button("Upload Folder", systemImage: "square.and.arrow.up.on.square") {
                                searchFocused = false
                                showingFolderImporter = true
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectionMode { selectionBar }
        }
        .background { keyboardShortcuts }
        .onChange(of: searchText) { _, _ in displayLimit = 200 }
        .onChange(of: model.items) { _, items in
            selectedPaths.formIntersection(Set(items.map(\.path)))
        }
        .onChange(of: model.currentPath) { _, _ in
            displayLimit = 200
            endSelection()
        }
        .task { await model.start() }
    }

    private var currentFolderFavoriteButton: some View {
        let isFavorite = history.isFavorite(profileID: model.profile.id, path: model.currentPath)
        return Button(
            isFavorite ? "Remove Folder from Favorites" : "Add Folder to Favorites",
            systemImage: isFavorite ? "star.slash" : "star"
        ) {
            let path = model.currentPath
            let name = path == "/" ? model.profile.name : (path as NSString).lastPathComponent
            history.toggleFavorite(profileID: model.profile.id, path: path, name: name, isDirectory: true)
        }
    }

    /// Invisible buttons that carry the iPad hardware keyboard shortcuts.
    /// Copy, cut, paste and delete stay off while the search field has focus
    /// so text editing keeps its usual shortcuts.
    private var keyboardShortcuts: some View {
        let canEditSelection = selectionMode && !selectedPaths.isEmpty && !searchFocused
        return Group {
            Button("Refresh") { Task { await model.refresh() } }
                .keyboardShortcut("r")
            Button("New Folder") { showingFolderPrompt = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.capabilities.contains(.createDirectory))
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f")
            Button("Enclosing Folder") { Task { await model.goUp() } }
                .keyboardShortcut(.upArrow)
                .disabled(!model.canGoUp)
            Button("Copy") { placeSelectedOnClipboard(.copy) }
                .keyboardShortcut("c")
                .disabled(!canEditSelection)
            Button("Cut") { placeSelectedOnClipboard(.move) }
                .keyboardShortcut("x")
                .disabled(
                    !canEditSelection ||
                    (!model.capabilities.contains(.move) && !model.capabilities.contains(.delete))
                )
            Button("Paste") {
                Task { await model.paste(clipboard, using: connections, transfers: transfers) }
            }
            .keyboardShortcut("v")
            .disabled(searchFocused || clipboard.isEmpty || !model.capabilities.contains(.write))
            Button("Delete Selected") { showingBatchDeleteConfirmation = true }
                .keyboardShortcut(.delete)
                .disabled(!canEditSelection || !model.capabilities.contains(.delete))
            Button("Show as List") { layout = .list }
                .keyboardShortcut("1")
            Button("Show as Grid") { layout = .grid }
                .keyboardShortcut("2")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var viewOptionsMenuContent: some View {
        Section {
            Picker("View", selection: $layout) {
                Label("List", systemImage: "list.bullet").tag(BrowserLayout.list)
                Label("Grid", systemImage: "square.grid.2x2").tag(BrowserLayout.grid)
            }
            Menu {
                ForEach(BrowserSortKey.allCases) { key in
                    Button {
                        if key == sortKey {
                            sortAscending.toggle()
                        } else {
                            sortKey = key
                            sortAscending = key.defaultAscending
                        }
                    } label: {
                        if key == sortKey {
                            Label(key.title, systemImage: sortAscending ? "chevron.up" : "chevron.down")
                        } else {
                            Text(key.title)
                        }
                    }
                }
                Divider()
                Toggle("Folders First", isOn: $foldersFirst)
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    private var browserWithPrompts: some View {
        browserBase
        .navigationDestination(item: $linkedFile) { file in
            if let provider = model.provider {
                FileDetailView(provider: provider, item: file)
            }
        }
        .alert("New Folder", isPresented: $showingFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.createFolder(name: name) }
            }
        }
        // Folders are opened in place (a folder cannot be picked as a copy).
        // Under LiveContainer that needs its "Fix File Picker" setting,
        // otherwise Open does nothing; see README.
        .fileImporter(
            isPresented: $showingFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                Task {
                    // Let the importer finish closing before a conflict
                    // dialog may need the screen.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    await model.upload(localURLs: urls, transfers: transfers)
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "Unknown error") }
    }

    private func presentUploadPicker(_ mode: SystemDocumentPicker.Mode) {
        searchFocused = false
        uploadPicker.present(mode: mode) { urls in
            guard !urls.isEmpty else { return }
            Task { await model.upload(localURLs: urls, transfers: transfers) }
        }
    }

    var body: some View {
        let shownConflictID = model.pendingUploadConflict?.id
        return browserWithPrompts
        .confirmationDialog(
            "Item Already Exists",
            isPresented: Binding(
                get: { model.pendingUploadConflict != nil },
                set: { if !$0, let shownConflictID { model.dismissUploadConflict(id: shownConflictID) } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingUploadConflict
        ) { conflict in
            uploadConflictButtons(conflict)
        } message: { conflict in
            if conflict.isFolder && conflict.existingIsFolder {
                Text("A folder named “\(conflict.name)” already exists in this folder. Merging puts the uploaded items into it; files with the same name are handled separately.")
            } else {
                Text("“\(conflict.name)” already exists in this folder.")
            }
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
        .alert(
            pendingDeleteItem?.isDirectory == true ? LocalizedStringKey("Delete Folder?") : LocalizedStringKey("Delete Item?"),
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            ),
            presenting: pendingDeleteItem
        ) { item in
            Button("Cancel", role: .cancel) { pendingDeleteItem = nil }
            Button("Delete", role: .destructive) {
                pendingDeleteItem = nil
                Task { await model.delete(item) }
            }
        } message: { item in
            Text(deleteConfirmationMessage(for: item))
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
        .sheet(item: $propertiesItem) { item in
            if let provider = model.provider {
                RemoteItemPropertiesView(provider: provider, item: item)
            }
        }
        .sheet(item: $copyItem) { item in
            if let provider = model.provider {
                CopyDestinationView(
                    profiles: connections.profiles.filter { $0.id != provider.profile.id },
                    fileName: item.name
                ) { destination, folder in
                    let sourceProfile = provider.profile
                    Task {
                        do {
                            try await transfers.copyItems(
                                [item],
                                from: sourceProfile,
                                to: destination,
                                destinationDirectory: folder
                            )
                        } catch is CancellationError {
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func uploadConflictButtons(_ conflict: UploadConflict) -> some View {
        let replaceTitle: LocalizedStringKey = conflict.isFolder ? "Merge" : "Replace"
        let replaceAllTitle: LocalizedStringKey = conflict.isFolder ? "Merge All" : "Replace All"
        if conflict.canReplace {
            Button(replaceTitle) { model.resolveUploadConflict(.replace, applyToAll: false) }
        }
        Button("Keep Both") { model.resolveUploadConflict(.keepBoth, applyToAll: false) }
        Button("Skip") { model.resolveUploadConflict(.skip, applyToAll: false) }
        // "… All" only means something when more items of this kind follow.
        if conflict.canApplyToAll {
            if conflict.canReplace {
                Button(replaceAllTitle) { model.resolveUploadConflict(.replace, applyToAll: true) }
            }
            Button("Keep Both for All") { model.resolveUploadConflict(.keepBoth, applyToAll: true) }
            Button("Skip All") { model.resolveUploadConflict(.skip, applyToAll: true) }
        }
        Button("Stop Upload", role: .cancel) { model.resolveUploadConflict(.stop, applyToAll: false) }
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
        } else if layout == .grid {
            populatedFileGrid
        } else {
            populatedFileList
        }
    }

    private var emptyFolderArea: some View {
        ZStack {
            EmptyFolderRefreshView(
                onRefresh: { await model.refresh() },
                onTap: { searchFocused = false }
            )

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
        let items = filteredItems
        return List {
            ForEach(items.prefix(displayLimit)) { item in
                if selectionMode {
                    Button { toggleSelection(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedPaths.contains(item.path) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedPaths.contains(item.path) ? Color.accentColor : Color.secondary)
                            FileRow(
                                item: item,
                                provider: model.provider,
                                displaySize: item.isFolderLike ? nil : item.size
                            )
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
                                    pendingDeleteItem = item
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
            if items.count > displayLimit {
                loadMoreButton(total: items.count)
            }
        }
        .refreshable { await model.refresh() }
        .scrollDismissesKeyboard(.interactively)
    }

    private var populatedFileGrid: some View {
        let items = filteredItems
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 8)], spacing: 8) {
                ForEach(items.prefix(displayLimit)) { item in
                    gridCell(item)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            if items.count > displayLimit {
                loadMoreButton(total: items.count)
                    .padding()
            }
        }
        .refreshable { await model.refresh() }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func gridCell(_ item: RemoteItem) -> some View {
        if selectionMode {
            Button { toggleSelection(item) } label: {
                BrowserGridCell(
                    item: item,
                    provider: model.provider,
                    selected: selectedPaths.contains(item.path)
                )
            }
            .buttonStyle(.plain)
        } else {
            itemActivator(item) {
                BrowserGridCell(item: item, provider: model.provider)
            }
            .buttonStyle(.plain)
            .contextMenu { itemContextMenu(item) }
        }
    }

    private func loadMoreButton(total: Int) -> some View {
        Button {
            displayLimit += 200
        } label: {
            HStack {
                Spacer()
                Text("Load \(min(200, total - displayLimit)) more")
                Spacer()
            }
        }
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
            Button {
                placeSelectedOnClipboard(.copy)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(selectedPaths.isEmpty)
            .accessibilityLabel("Copy Selected")
            Button {
                placeSelectedOnClipboard(.move)
            } label: {
                Image(systemName: "arrow.right.doc.on.clipboard")
            }
            .disabled(
                selectedPaths.isEmpty ||
                (!model.capabilities.contains(.move) && !model.capabilities.contains(.delete))
            )
            .accessibilityLabel("Move Selected")
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

    private func placeSelectedOnClipboard(_ operation: FileOperationClipboard.Operation) {
        let items = model.items.filter { selectedPaths.contains($0.path) }
        guard !items.isEmpty else { return }
        clipboard.set(items, from: model.profile.id, operation: operation)
        endSelection()
    }

    @ViewBuilder
    private func itemContextMenu(_ item: RemoteItem) -> some View {
        Button("Copy", systemImage: "doc.on.doc") {
            clipboard.set([item], from: model.profile.id, operation: .copy)
            searchFocused = false
        }

        if model.capabilities.contains(.move) || model.capabilities.contains(.delete) {
            Button("Move", systemImage: "arrow.right.doc.on.clipboard") {
                clipboard.set([item], from: model.profile.id, operation: .move)
                searchFocused = false
            }
        }

        Button("Select", systemImage: "checkmark.circle") {
            selectionMode = true
            selectedPaths = [item.path]
            searchFocused = false
        }

        Button("Properties", systemImage: "info.circle") {
            propertiesItem = item
            searchFocused = false
        }

        let isFavorite = history.isFavorite(profileID: model.profile.id, path: item.path)
        Button(
            isFavorite ? "Remove from Favorites" : "Add to Favorites",
            systemImage: isFavorite ? "star.slash" : "star"
        ) {
            history.toggleFavorite(
                profileID: model.profile.id,
                path: item.path,
                name: item.name,
                isDirectory: item.isFolderLike
            )
        }

        if let provider = model.provider {
            Button(
                offlineActionTitle(for: item, provider: provider),
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
                pendingDeleteItem = item
            }
        }
    }

    private func offlineActionTitle(for item: RemoteItem, provider: any RemoteFileProvider) -> LocalizedStringKey {
        offline.isPinned(profileID: provider.profile.id, path: item.path) ? "Remove Offline Copy" : "Keep Offline"
    }

    private func toggleOffline(_ item: RemoteItem, provider: any RemoteFileProvider) async {
        offlineWorkingPath = item.path
        defer { offlineWorkingPath = nil }
        if offline.isPinned(profileID: provider.profile.id, path: item.path) {
            offline.unpin(profileID: provider.profile.id, path: item.path)
            return
        }
        do {
            try await offline.pin(provider: provider, item: item, transfers: transfers)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private var sortOrder: BrowserSortOrder {
        BrowserSortOrder(key: sortKey, ascending: sortAscending, foldersFirst: foldersFirst)
    }

    private var filteredItems: [RemoteItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty
            ? model.items
            : model.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return sortOrder.sorted(matching)
    }

    private func deleteConfirmationMessage(for item: RemoteItem) -> LocalizedStringKey {
        if item.isDirectory {
            return "This permanently deletes the folder and everything inside it."
        }
        if item.kind == .symbolicLink {
            return "This permanently deletes the link “\(item.name)”. The item it points to is kept."
        }
        return "This permanently deletes “\(item.name)”."
    }

    private func itemRow(_ item: RemoteItem) -> some View {
        itemActivator(item) {
            FileRow(
                item: item,
                provider: model.provider,
                displaySize: item.isFolderLike ? nil : item.size
            )
        }
    }

    /// Wraps `label` in what tapping an item does: enter a folder, follow a link or open a file.
    @ViewBuilder
    private func itemActivator<Content: View>(
        _ item: RemoteItem,
        @ViewBuilder label: () -> Content
    ) -> some View {
        if item.isDirectory {
            Button { Task { await model.enter(item) } } label: { label() }
                .buttonStyle(.plain)
        } else if item.kind == .symbolicLink {
            Button {
                Task {
                    if let file = await model.openLink(item) { linkedFile = file }
                }
            } label: { label() }
            .buttonStyle(.plain)
        } else if let provider = model.provider {
            NavigationLink {
                FileDetailView(provider: provider, item: item)
            } label: { label() }
        } else {
            label()
        }
    }
}

private struct FileRow: View {
    let item: RemoteItem
    let provider: (any RemoteFileProvider)?
    let displaySize: Int64?
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    WhiteSurFileIconView(
                        fileName: item.name,
                        isDirectory: item.isFolderLike,
                        size: 36
                    )
                    .overlay(alignment: .bottomLeading) {
                        if item.kind == .symbolicLink {
                            Image(systemName: "arrow.turn.up.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(2)
                                .background(.background, in: Circle())
                        }
                    }
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                HStack(spacing: 8) {
                    if !item.isFolderLike {
                        if let size = displaySize {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        } else {
                            Text("—")
                        }
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
                // Matches BrowserGridCell: the thumbnail cache is keyed without size.
                size: CGSize(width: 84, height: 84)
            )
        }
    }

}

private struct RemoteItemPropertiesView: View {
    @Environment(\.dismiss) private var dismiss

    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var resolvedSize: Int64?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("General") {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Type") {
                        Text(item.isFolderLike ? LocalizedStringKey("Folder") : LocalizedStringKey("File"))
                    }
                    LabeledContent("Path", value: item.path)
                    if !item.isFolderLike {
                        LabeledContent("Size") {
                            if let size = resolvedSize ?? item.size {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            } else {
                                Text("Unavailable")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Dates") {
                    if let modifiedAt = item.modifiedAt {
                        LabeledContent("Modified") { Text(modifiedAt, style: .date) }
                    }
                    if let createdAt = item.createdAt {
                        LabeledContent("Created") { Text(createdAt, style: .date) }
                    }
                }

                if let permissions = item.permissions {
                    Section("Permissions") {
                        LabeledContent(
                            "Mode",
                            value: String(format: "%04o", permissions & 0o7777)
                        )
                    }
                }
            }
            .navigationTitle("Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadSize()
            }
        }
    }

    private func loadSize() async {
        guard !item.isFolderLike, item.size == nil else { return }
        do {
            let attributes = try await provider.attributes(path: item.path)
            resolvedSize = attributes.size
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
