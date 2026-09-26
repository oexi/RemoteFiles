import SwiftUI
import UIKit

/// Full-screen audio and video preview, played with libmpv.
struct MPVPlayerView: View {
    @StateObject private var player: MPVPlayer
    @Environment(\.scenePhase) private var scenePhase

    @State private var controlsVisible = true
    @State private var scrubPosition: Double?
    @State private var lastInteraction = Date()

    init(media: MPVPlayer.Media) {
        _player = StateObject(wrappedValue: MPVPlayer(media: media))
    }

    var body: some View {
        content
            .playbackChrome(visible: controlsVisible || player.errorMessage != nil)
            .task(id: AutoHideKey(visible: controlsVisible, paused: player.isPaused, scrubbing: scrubPosition != nil, interaction: lastInteraction)) {
                guard controlsVisible, !player.isPaused, scrubPosition == nil else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: player.enterBackground()
                case .active: player.enterForeground()
                default: break
                }
            }
            .onDisappear { player.pause() }
    }

    private var content: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVVideoSurface(player: player)
                .ignoresSafeArea()
            if let message = player.errorMessage {
                ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
                    .foregroundStyle(.white)
            } else {
                overlay
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible.toggle() }
            lastInteraction = Date()
        }
    }

    /// Centre items fill the whole screen, ignoring the safe area, so they sit in the
    /// middle of the picture, which is also centred on the full screen.
    @ViewBuilder
    private var overlay: some View {
        if player.isLoaded, !player.hasVideo, !player.isBuffering {
            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.35))
                .fullScreenCentered()
        }
        if player.isBuffering {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
                .fullScreenCentered()
        }
        if controlsVisible {
            transportButtons
                .fullScreenCentered()
                .transition(.opacity)
            VStack {
                Spacer()
                timeline
            }
            .transition(.opacity)
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 48) {
            Button {
                player.skip(by: -10)
                lastInteraction = Date()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.title)
            }
            .accessibilityLabel(Text("Skip Back 10 Seconds"))

            Button {
                player.togglePause()
                lastInteraction = Date()
            } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 40))
                    .frame(width: 56, height: 56)
            }
            .accessibilityLabel(player.isPaused ? Text("Play") : Text("Pause"))

            Button {
                player.skip(by: 10)
                lastInteraction = Date()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.title)
            }
            .accessibilityLabel(Text("Skip Forward 10 Seconds"))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 6)
        .opacity(player.isBuffering ? 0 : 1)
    }

    private var timeline: some View {
        HStack(spacing: 12) {
            Text(MPVPlayer.timeString(scrubPosition ?? player.position))
            PlaybackScrubber(
                position: player.position,
                duration: player.duration,
                scrubPosition: $scrubPosition
            ) { target in
                player.seek(to: target)
                lastInteraction = Date()
            }
            Text(MPVPlayer.timeString(player.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

}

private extension View {
    func fullScreenCentered() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}

extension View {
    /// Hides the tab bar while media plays, and the navigation bar, status bar and
    /// home indicator whenever the player's controls are hidden.
    func playbackChrome(visible: Bool) -> some View {
        self
            .toolbar(.hidden, for: .tabBar)
            .toolbar(visible ? .visible : .hidden, for: .navigationBar)
            .statusBarHidden(!visible)
            .persistentSystemOverlays(visible ? .automatic : .hidden)
    }
}

private struct AutoHideKey: Equatable {
    let visible: Bool
    let paused: Bool
    let scrubbing: Bool
    let interaction: Date
}

/// A thin progress bar that seeks when the drag ends.
private struct PlaybackScrubber: View {
    let position: Double
    let duration: Double
    @Binding var scrubPosition: Double?
    let onCommit: (Double) -> Void

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, (scrubPosition ?? position) / duration))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scrubbing = scrubPosition != nil
            let trackHeight: CGFloat = scrubbing ? 6 : 4
            let knob: CGFloat = scrubbing ? 16 : 12
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(.white)
                    .frame(width: width * fraction, height: trackHeight)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .offset(x: width * fraction - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        scrubPosition = min(1, max(0, value.location.x / width)) * duration
                    }
                    .onEnded { _ in
                        guard let target = scrubPosition else { return }
                        onCommit(target)
                        scrubPosition = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: scrubbing)
        }
        .frame(height: 28)
        .disabled(duration <= 0)
        .accessibilityElement()
        .accessibilityLabel(Text("Playback Position"))
        .accessibilityValue(Text(MPVPlayer.timeString(scrubPosition ?? position)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(position + 10)
            case .decrement: onCommit(position - 10)
            @unknown default: break
            }
        }
    }
}

/// Hosts the player's Metal layer and starts playback once the layer has a size.
private struct MPVVideoSurface: UIViewRepresentable {
    let player: MPVPlayer

    func makeUIView(context: Context) -> MPVLayerHostView {
        MPVLayerHostView(player: player)
    }

    func updateUIView(_ uiView: MPVLayerHostView, context: Context) {}
}

private final class MPVLayerHostView: UIView {
    private let player: MPVPlayer

    init(player: MPVPlayer) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.addSublayer(player.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        player.layout(
            in: bounds,
            displayScale: traitCollection.displayScale,
            screenSize: window?.screen.bounds.size ?? bounds.size
        )
        if bounds.width > 1, bounds.height > 1 {
            player.startIfNeeded()
        }
    }
}
