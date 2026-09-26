import SwiftUI

struct RemotePreviewView: View {
    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var localURL: URL?
    @State private var errorMessage: String?
    @State private var showingShare = false
    @State private var streamSource: RemoteByteStreamSource?

    init(provider: any RemoteFileProvider, item: RemoteItem) {
        self.provider = provider
        self.item = item
        let source = MPVPlayer.canPlay(fileName: item.name)
            ? RemoteByteStreamSource(provider: provider, item: item)
            : nil
        _streamSource = State(initialValue: source)
    }

    var body: some View {
        Group {
            if let streamSource {
                MPVPlayerView(media: .remote(streamSource), title: item.name)
            } else {
                downloadedPreview
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if localURL != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingShare = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showingShare) {
            if let localURL {
                SystemShareSheet(urls: [localURL]) {
                    showingShare = false
                }
                .ignoresSafeArea()
            }
        }
        .task {
            // Media is streamed; everything else, and media that cannot be streamed
            // (FTP, unknown size), is downloaded to the cache first.
            guard streamSource == nil, localURL == nil else { return }
            do {
                localURL = try await CacheManager.shared.materialize(provider: provider, item: item)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var downloadedPreview: some View {
        Group {
            if let localURL {
                if MPVPlayer.canPlay(fileName: item.name) {
                    MPVPlayerView(media: .local(localURL), title: item.name)
                } else {
                    QuickLookView(url: localURL)
                }
            } else if let errorMessage {
                ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("Downloading preview…")
            }
        }
    }
}
