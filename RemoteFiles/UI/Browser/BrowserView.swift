import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @StateObject private var model: BrowserViewModel
    @State private var showingFolderPrompt = false
    @State private var newFolderName = ""
    @State private var showingImporter = false

    init(profile: ConnectionProfile) {
        _model = StateObject(wrappedValue: BrowserViewModel(profile: profile))
    }

    var body: some View {
        List {
            if model.loading && model.items.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            ForEach(model.items) { item in
                itemRow(item)
                    .swipeActions(edge: .trailing) {
                        if model.capabilities.contains(.delete) {
                            Button(role: .destructive) { Task { await model.delete(item) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            }
        }
        .overlay {
            if !model.loading && model.items.isEmpty && model.errorMessage == nil {
                ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text(model.currentPath))
            }
        }
        .navigationTitle(model.profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(model.currentPath).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 7)
            .background(.bar)
        }
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
                        Button("Upload Files", systemImage: "square.and.arrow.up") { showingImporter = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .refreshable { await model.refresh() }
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
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.upload(localURLs: urls) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: RemoteItem) -> some View {
        if item.isDirectory {
            Button { Task { await model.enter(item) } } label: { FileRow(item: item) }
                .buttonStyle(.plain)
        } else if let provider = model.provider {
            NavigationLink {
                FileDetailView(provider: provider, item: item)
            } label: { FileRow(item: item) }
        } else {
            FileRow(item: item)
        }
    }
}

private struct FileRow: View {
    let item: RemoteItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : iconName)
                .font(.title3)
                .frame(width: 28)
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
    }

    private var iconName: String {
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ext == "zip" { return "archivebox.fill" }
        if EditorLanguage.isEditable(fileName: item.name) { return "doc.text.fill" }
        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) { return "photo.fill" }
        if ["mp4", "mov", "m4v", "mkv"].contains(ext) { return "film.fill" }
        if ext == "pdf" { return "doc.richtext.fill" }
        return "doc.fill"
    }
}

