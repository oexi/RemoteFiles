import SwiftUI
import UIKit

/// Full-screen audio and video preview, played with libmpv.
struct MPVPlayerView: View {
    let title: String

    @StateObject private var player: MPVPlayer
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var controlsVisible = true
    @State private var scrubPosition: Double?
    @State private var lastInteraction = Date()

    init(media: MPVPlayer.Media, title: String) {
        self.title = title
        _player = StateObject(wrappedValue: MPVPlayer(media: media, title: title))
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
                VStack {
                    topBar
                    Spacer()
                }
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
        // While the controls are shown the buttons stay put, so repeated taps never land
        // on the empty screen behind them; buffering shows in the timeline instead.
        if player.isBuffering, !controlsVisible {
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
                topBar
                Spacer()
                timeline
            }
            .transition(.opacity)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Close"))
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 4)
        .padding(.horizontal, 8)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 32) {
            Button {
                player.skip(by: -10)
                lastInteraction = Date()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.title)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Skip Back 10 Seconds"))

            Button {
                player.togglePause()
                lastInteraction = Date()
            } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 40))
                    .frame(width: 72, height: 72)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(player.isPaused ? Text("Play") : Text("Pause"))

            Button {
                player.skip(by: 10)
                lastInteraction = Date()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.title)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Skip Forward 10 Seconds"))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 6)
        // Taps just beside the buttons keep the controls up instead of hiding them.
        .padding(24)
        .contentShape(Rectangle())
        .onTapGesture { lastInteraction = Date() }
    }

    private var timeline: some View {
        HStack(spacing: 12) {
            ZStack {
                Text(MPVPlayer.timeString(scrubPosition ?? player.position))
                    .opacity(player.isBuffering ? 0 : 1)
                if player.isBuffering {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                }
            }
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
    /// Hides the app's tab and navigation bars while media plays (the player draws its own
    /// close button and title), and the status bar and home indicator whenever the
    /// player's controls are hidden.
    func playbackChrome(visible: Bool) -> some View {
        self
            .toolbar(.hidden, for: .tabBar)
            .toolbar(.hidden, for: .navigationBar)
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
