import SwiftUI

struct RemotePreviewView: View {
    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var localURL: URL?
    @State private var errorMessage: String?
    @State private var showingShare = false
    @State private var streamLoader: RemoteMediaResourceLoader?

    init(provider: any RemoteFileProvider, item: RemoteItem) {
        self.provider = provider
        self.item = item
        _streamLoader = State(initialValue: RemoteMediaResourceLoader(provider: provider, item: item))
    }

    var body: some View {
        Group {
            if let streamLoader {
                RemoteMediaPlayerView(loader: streamLoader) {
                    self.streamLoader = nil
                }
            } else if let localURL {
                QuickLookView(url: localURL)
            } else if let errorMessage {
                ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("Downloading preview…")
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
        .task(id: streamLoader == nil) {
            // Streamed media is only downloaded when AVFoundation cannot play the stream.
            guard streamLoader == nil, localURL == nil else { return }
            do {
                localURL = try await CacheManager.shared.materialize(provider: provider, item: item)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
