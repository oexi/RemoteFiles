import SwiftUI

struct RemotePreviewView: View {
    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var localURL: URL?
    @State private var errorMessage: String?
    @State private var showingShare = false
    @State private var playback: Playback

    /// How the file is shown: streamed with AVFoundation, streamed with libmpv, or
    /// downloaded to the cache first.
    private enum Playback {
        case native(RemoteMediaResourceLoader)
        case mpv(RemoteByteStreamSource)
        case download

        var needsDownload: Bool {
            if case .download = self { return true }
            return false
        }
    }

    init(provider: any RemoteFileProvider, item: RemoteItem) {
        self.provider = provider
        self.item = item
        if let loader = RemoteMediaResourceLoader(provider: provider, item: item) {
            _playback = State(initialValue: .native(loader))
        } else {
            _playback = State(initialValue: Self.mpvPlayback(provider: provider, item: item) ?? .download)
        }
    }

    private static func mpvPlayback(provider: any RemoteFileProvider, item: RemoteItem) -> Playback? {
        guard MPVPlayer.canPlay(fileName: item.name),
              let source = RemoteByteStreamSource(provider: provider, item: item) else { return nil }
        return .mpv(source)
    }

    var body: some View {
        Group {
            switch playback {
            case .native(let loader):
                RemoteMediaPlayerView(loader: loader) {
                    // AVFoundation rejected the stream (for example an unsupported codec).
                    playback = Self.mpvPlayback(provider: provider, item: item) ?? .download
                }
            case .mpv(let source):
                MPVPlayerView(media: .remote(source))
            case .download:
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
        .task(id: playback.needsDownload) {
            // Streamed media is only downloaded when neither player can stream it.
            guard playback.needsDownload, localURL == nil else { return }
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
                if MPVPlayer.isPreferred(forFileName: item.name) {
                    MPVPlayerView(media: .local(localURL))
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
