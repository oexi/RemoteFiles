import AVKit
import SwiftUI

/// Plays remote audio or video while it streams through `RemoteMediaResourceLoader`.
struct RemoteMediaPlayerView: View {
    let loader: RemoteMediaResourceLoader
    /// Called when AVFoundation cannot play the stream, so the caller can download instead.
    let onUnplayable: () -> Void

    @State private var player: AVPlayer?
    @State private var chromeVisible = true
    @State private var lastInteraction = Date()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    // AVKit toggles its own controls on a tap; follow it with the bars.
                    .simultaneousGesture(TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.25)) { chromeVisible.toggle() }
                        lastInteraction = Date()
                    })
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .playbackChrome(visible: chromeVisible)
        .task(id: lastInteraction) {
            guard chromeVisible, player != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, player?.timeControlStatus != .paused else { return }
            withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
        }
        .task { await prepare() }
        .onDisappear {
            player?.pause()
            loader.cancelAll()
        }
    }

    private func prepare() async {
        guard player == nil else { return }
        let asset = AVURLAsset(url: loader.assetURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        do {
            guard try await asset.load(.isPlayable) else {
                onUnplayable()
                return
            }
        } catch is CancellationError {
            return
        } catch {
            onUnplayable()
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player = player
        player.play()
        lastInteraction = Date()
    }
}
