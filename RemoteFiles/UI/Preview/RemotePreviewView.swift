import SwiftUI

struct RemotePreviewView: View {
    let provider: any RemoteFileProvider
    let item: RemoteItem

    @State private var localURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let localURL {
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
            if let localURL {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: localURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            do {
                localURL = try await CacheManager.shared.materialize(provider: provider, item: item)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

