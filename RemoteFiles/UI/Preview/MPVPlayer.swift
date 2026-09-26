import AVFoundation
import Libmpv
import QuartzCore
import UniformTypeIdentifiers

/// Plays audio and video with libmpv, rendering into `layer` through MoltenVK. Remote
/// files are read through `RemoteByteStreamSource`, so playback starts at once and seeks
/// without downloading the whole file.
@MainActor
final class MPVPlayer: ObservableObject {
    enum Media {
        case remote(RemoteByteStreamSource)
        case local(URL)
    }

    /// The fields of an entry in libmpv's `track-list` that the player needs.
    struct Track: Decodable, Equatable {
        let id: Int
        let type: String
        let albumart: Bool?
        let width: Int?
        let height: Int?
        let rotation: Int?
        let pixelAspect: Double?

        enum CodingKeys: String, CodingKey {
            case id, type, albumart
            case width = "demux-w"
            case height = "demux-h"
            case rotation = "demux-rotation"
            case pixelAspect = "demux-par"
        }

        /// Display size in pixels, after rotation and pixel aspect ratio.
        var displaySize: CGSize? {
            guard type == "video", let width, let height, width > 0, height > 0 else { return nil }
            let displayWidth = Double(width) * (pixelAspect.map { $0 > 0 ? $0 : 1 } ?? 1)
            let size = CGSize(width: displayWidth, height: Double(height))
            let quarterTurns = ((rotation ?? 0) / 90) % 2
            return quarterTurns == 0 ? size : CGSize(width: size.height, height: size.width)
        }
    }

    nonisolated static let streamProtocol = "remotefiles"

    let layer = MPVMetalLayer()

    @Published private(set) var isPaused = false
    @Published private(set) var isBuffering = true
    @Published private(set) var isAtEnd = false
    @Published private(set) var isLoaded = false
    @Published private(set) var hasVideo = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?

    /// Longest side, in pixels, of the drawable video is rendered into. Set by the
    /// hosting view from the screen size.
    var maximumDrawableDimension: CGFloat = 2560

    private let media: Media
    private var core: MPVCore?
    private var backgrounded = false

    init(media: Media) {
        self.media = media
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.framebufferOnly = true
        layer.contentsGravity = .resizeAspect
    }

    deinit {
        core?.destroy()
    }

    /// Starts playback once `layer` has a size; later calls do nothing.
    func startIfNeeded() {
        guard core == nil, errorMessage == nil else { return }
        let source: RemoteByteStreamSource?
        let target: String
        switch media {
        case .remote(let remote):
            source = remote
            var components = URLComponents()
            components.scheme = Self.streamProtocol
            components.host = "media"
            components.path = "/" + remote.fileName
            target = components.url?.absoluteString ?? "\(Self.streamProtocol)://media/stream"
        case .local(let url):
            source = nil
            target = url.path
        }
        let core = MPVCore(layer: layer, source: source) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(event) }
            }
        }
        guard let core else {
            errorMessage = String(localized: "The video player could not be started.")
            return
        }
        self.core = core
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        core.command(["loadfile", target, "replace"])
    }

    func togglePause() {
        if isPaused, isAtEnd {
            seek(to: 0)
        }
        core?.setProperty("pause", isPaused ? "no" : "yes")
    }

    func pause() {
        core?.setProperty("pause", "yes")
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        position = target
        core?.command(["seek", String(target), "absolute"])
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    /// MoltenVK loses its surface in the background; drop video until the app returns.
    func enterBackground() {
        guard hasVideo, !backgrounded else { return }
        backgrounded = true
        pause()
        core?.setProperty("vid", "no")
    }

    func enterForeground() {
        guard backgrounded else { return }
        backgrounded = false
        core?.setProperty("vid", "auto")
    }

    private func apply(_ event: MPVCore.Event) {
        switch event {
        case .flag("pause", let value):
            isPaused = value
        case .flag("paused-for-cache", let value), .flag("seeking", let value):
            isBuffering = value
        case .flag("eof-reached", let value):
            isAtEnd = value
        case .double("time-pos", let value):
            // time-pos changes every frame; a quarter second is enough for the controls.
            if abs(value - position) >= 0.25 || value < position { position = value }
        case .double("duration", let value):
            duration = value
        case .string("track-list", let json):
            let tracks = (try? JSONDecoder().decode([Track].self, from: Data(json.utf8))) ?? []
            startVideoIfNeeded(tracks)
        case .fileLoaded:
            isLoaded = true
            isBuffering = false
        case .failed(let message):
            isBuffering = false
            errorMessage = message
        default:
            break
        }
    }

    /// Video starts disabled (`vid=no`). MPVKit's MoltenVK context reads the drawable size
    /// only when video starts and never follows later resizes such as rotation, so the
    /// drawable is fixed to the video's own aspect ratio first; Core Animation then scales
    /// it to fit the layer in any orientation.
    private func startVideoIfNeeded(_ tracks: [Track]) {
        guard !hasVideo, let track = tracks.first(where: { $0.type == "video" }) else { return }
        if let size = track.displaySize {
            layer.fixedDrawableSize = Self.drawableSize(for: size, maximumDimension: maximumDrawableDimension)
        }
        hasVideo = true
        core?.setProperty("vid", "auto")
    }

    nonisolated static func drawableSize(for videoSize: CGSize, maximumDimension: CGFloat) -> CGSize {
        let longest = max(videoSize.width, videoSize.height)
        let scale = longest > maximumDimension ? maximumDimension / longest : 1
        return CGSize(
            width: max(2, (videoSize.width * scale).rounded()),
            height: max(2, (videoSize.height * scale).rounded())
        )
    }

    // MARK: - Formats

    private nonisolated static let extraExtensions: Set<String> = [
        "3g2", "3gp", "aac", "ac3", "aif", "aiff", "amr", "ape", "asf", "avi", "caf", "divx",
        "dts", "dv", "eac3", "f4v", "flac", "flv", "m1v", "m2t", "m2ts", "m2v", "m4a", "m4v",
        "mka", "mkv", "mov", "mp2", "mp3", "mp4", "mpe", "mpeg", "mpg", "mts", "mxf", "nut",
        "oga", "ogg", "ogm", "ogv", "opus", "rm", "rmvb", "tak", "ts", "tta", "vob", "wav",
        "webm", "wma", "wmv", "wv"
    ]

    /// Whether libmpv should be able to play the file, judged by its name.
    nonisolated static func canPlay(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if extraExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .audiovisualContent) == true
    }

    nonisolated static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = total / 60 % 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// The layer libmpv renders into through MoltenVK.
final class MPVMetalLayer: CAMetalLayer {
    /// When set, the drawable keeps this size whatever the layer's bounds; see
    /// `MPVPlayer.startVideoIfNeeded`.
    var fixedDrawableSize: CGSize? {
        didSet {
            if let fixedDrawableSize { super.drawableSize = fixedDrawableSize }
        }
    }

    override var drawableSize: CGSize {
        get { fixedDrawableSize ?? super.drawableSize }
        set {
            if let fixedDrawableSize {
                // MoltenVK re-applies the swapchain extent; keep everything else out.
                if newValue == fixedDrawableSize { super.drawableSize = newValue }
            } else if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                // MoltenVK shrinks the drawable to 1×1 to force a present, which
                // flickers or leaves the video at that size (mpv-player/mpv#13651).
                super.drawableSize = newValue
            }
        }
    }
}

/// Owns one libmpv handle. Every libmpv call runs on `queue`, which is also where
/// events are read and where the handle is finally destroyed.
final class MPVCore: @unchecked Sendable {
    enum Event: Sendable {
        case flag(String, Bool)
        case double(String, Double)
        case string(String, String)
        case fileLoaded
        case failed(String)
    }

    private let queue = DispatchQueue(label: "RemoteFiles.MPV", qos: .userInitiated)
    private let source: RemoteByteStreamSource?
    private let onEvent: @Sendable (Event) -> Void
    private var handle: OpaquePointer?

    init?(layer: CAMetalLayer, source: RemoteByteStreamSource?, onEvent: @escaping @Sendable (Event) -> Void) {
        guard let handle = mpv_create() else { return nil }
        self.source = source
        self.onEvent = onEvent
        self.handle = handle

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            // Video is enabled once its size is known; see MPVPlayer.startVideoIfNeeded.
            ("vid", "no"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            // A simple preview: no subtitles.
            ("sid", "no"),
            ("sub-auto", "no"),
            // Read ahead in memory only; nothing is cached on disk.
            ("cache", "yes"),
            ("cache-on-disk", "no"),
            ("demuxer-max-bytes", "64MiB"),
            ("demuxer-max-back-bytes", "16MiB")
        ]
        for (name, value) in options {
            mpv_set_option_string(handle, name, value)
        }
        #if DEBUG
        mpv_request_log_messages(handle, "warn")
        #endif

        if let source {
            let userData = Unmanaged.passUnretained(source).toOpaque()
            guard mpv_stream_cb_add_ro(handle, MPVPlayer.streamProtocol, userData, openRemoteStream) >= 0 else {
                mpv_terminate_destroy(handle)
                return nil
            }
        }
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            return nil
        }

        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "seeking", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        // Node properties formatted as strings come back as JSON.
        mpv_observe_property(handle, 0, "track-list", MPV_FORMAT_STRING)

        // The wakeup callback stops before `mpv_terminate_destroy` returns, and
        // `destroy` keeps `self` alive until then.
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let core = Unmanaged<MPVCore>.fromOpaque(context).takeUnretainedValue()
            core.queue.async { core.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func command(_ arguments: [String]) {
        queue.async { [self] in
            guard let handle else { return }
            var cArguments: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
            cArguments.append(nil)
            defer { cArguments.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
            mpv_command_async(handle, 0, &cArguments)
        }
    }

    func setProperty(_ name: String, _ value: String) {
        queue.async { [self] in
            guard let handle else { return }
            mpv_set_property_string(handle, name, value)
        }
    }

    /// Stops playback and frees libmpv off the main thread. Blocked remote reads are
    /// cancelled first so shutdown does not wait for the network.
    func destroy() {
        queue.async { [self] in
            guard let handle else { return }
            self.handle = nil
            source?.cancelAll()
            mpv_terminate_destroy(handle)
        }
    }

    private func drainEvents() {
        while let handle, let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                      let data = property.data else { continue }
                let name = String(cString: property.name)
                switch property.format {
                case MPV_FORMAT_FLAG:
                    onEvent(.flag(name, data.load(as: Int32.self) != 0))
                case MPV_FORMAT_DOUBLE:
                    onEvent(.double(name, data.load(as: Double.self)))
                case MPV_FORMAT_STRING:
                    if let string = data.load(as: UnsafePointer<CChar>?.self) {
                        onEvent(.string(name, String(cString: string)))
                    }
                default:
                    break
                }
            case MPV_EVENT_FILE_LOADED:
                onEvent(.fileLoaded)
            case MPV_EVENT_END_FILE:
                guard let endFile = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
                      endFile.reason == MPV_END_FILE_REASON_ERROR else { continue }
                let reason = String(cString: mpv_error_string(endFile.error))
                onEvent(.failed(String(localized: "The file could not be played (\(reason)).")))
            case MPV_EVENT_LOG_MESSAGE:
                #if DEBUG
                if let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                    print("[mpv/\(String(cString: message.prefix))] \(String(cString: message.text))", terminator: "")
                }
                #endif
            default:
                break
            }
        }
    }
}

// MARK: - libmpv stream callbacks

/// Opens a `RemoteByteStream` for a `remotefiles://` URL. The cookie retains the stream
/// until libmpv calls `close_fn`.
private let openRemoteStream: mpv_stream_cb_open_ro_fn = { userData, _, info in
    guard let userData, let info else { return MPV_ERROR_LOADING_FAILED.rawValue }
    let source = Unmanaged<RemoteByteStreamSource>.fromOpaque(userData).takeUnretainedValue()
    let stream = source.open()
    info.pointee.cookie = Unmanaged.passRetained(stream).toOpaque()
    info.pointee.read_fn = { cookie, buffer, count in
        guard let cookie, let buffer else { return -1 }
        let stream = Unmanaged<RemoteByteStream>.fromOpaque(cookie).takeUnretainedValue()
        guard let read = stream.read(into: buffer, count: Int(clamping: count)) else { return -1 }
        return Int64(read)
    }
    info.pointee.seek_fn = { cookie, offset in
        guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
        let stream = Unmanaged<RemoteByteStream>.fromOpaque(cookie).takeUnretainedValue()
        return stream.seek(to: offset) ?? Int64(MPV_ERROR_GENERIC.rawValue)
    }
    info.pointee.size_fn = { cookie in
        guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
        return Int64(Unmanaged<RemoteByteStream>.fromOpaque(cookie).takeUnretainedValue().size)
    }
    info.pointee.cancel_fn = { cookie in
        guard let cookie else { return }
        Unmanaged<RemoteByteStream>.fromOpaque(cookie).takeUnretainedValue().cancel()
    }
    info.pointee.close_fn = { cookie in
        guard let cookie else { return }
        let stream = Unmanaged<RemoteByteStream>.fromOpaque(cookie).takeRetainedValue()
        stream.close()
    }
    return 0
}
