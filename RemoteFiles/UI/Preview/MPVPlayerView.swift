import SwiftUI
import UIKit

/// Full-screen player for media that only libmpv can play.
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
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
            lastInteraction = Date()
        }
        .toolbar(controlsVisible || player.errorMessage != nil ? .automatic : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { trackMenu }
        }
        .task(id: AutoHideKey(visible: controlsVisible, paused: player.isPaused, scrubbing: scrubPosition != nil, interaction: lastInteraction)) {
            guard controlsVisible, !player.isPaused, scrubPosition == nil, player.hasVideo else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
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

    @ViewBuilder
    private var overlay: some View {
        if player.isBuffering {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
        }
        if controlsVisible || !player.hasVideo {
            VStack {
                Spacer()
                transportButtons
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
                    .font(.system(size: 44))
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
        .shadow(radius: 4)
        .opacity(player.isBuffering ? 0 : 1)
    }

    private var timeline: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubPosition ?? player.position },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    guard !editing, let target = scrubPosition else { return }
                    player.seek(to: target)
                    scrubPosition = nil
                    lastInteraction = Date()
                }
            )
            .disabled(player.duration <= 0)
            HStack {
                Text(MPVPlayer.timeString(scrubPosition ?? player.position))
                Spacer()
                Text(MPVPlayer.timeString(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
        .tint(.white)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .padding([.horizontal, .bottom])
    }

    @ViewBuilder
    private var trackMenu: some View {
        let audio = player.audioTracks
        let subtitles = player.subtitleTracks
        if audio.count > 1 || !subtitles.isEmpty {
            Menu {
                if audio.count > 1 {
                    Section("Audio") {
                        ForEach(audio) { track in
                            trackButton(track.displayName, selected: track.isSelected) {
                                player.selectTrack(track, type: "audio")
                            }
                        }
                    }
                }
                if !subtitles.isEmpty {
                    Section("Subtitles") {
                        trackButton(String(localized: "Off"), selected: !subtitles.contains(where: \.isSelected)) {
                            player.selectTrack(nil, type: "sub")
                        }
                        ForEach(subtitles) { track in
                            trackButton(track.displayName, selected: track.isSelected) {
                                player.selectTrack(track, type: "sub")
                            }
                        }
                    }
                }
            } label: {
                Label("Audio and Subtitles", systemImage: "captions.bubble")
            }
        }
    }

    private func trackButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

private struct AutoHideKey: Equatable {
    let visible: Bool
    let paused: Bool
    let scrubbing: Bool
    let interaction: Date
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player.layer.frame = bounds
        player.layer.contentsScale = traitCollection.displayScale
        CATransaction.commit()
        if bounds.width > 1, bounds.height > 1 {
            player.startIfNeeded()
        }
    }
}
