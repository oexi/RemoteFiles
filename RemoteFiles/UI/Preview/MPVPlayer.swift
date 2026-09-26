import AVFoundation
import Libmpv
import QuartzCore
import UniformTypeIdentifiers

/// Plays media that AVFoundation cannot (MKV, AVI, WebM, …) with libmpv, rendering into
/// `layer` through MoltenVK. Remote files are read through `RemoteByteStreamSource`,
/// so playback starts at once and seeks without downloading the whole file.
@MainActor
final class MPVPlayer: ObservableObject {
    enum Media {
        case remote(RemoteByteStreamSource)
        case local(URL)
    }

    struct Track: Identifiable, Decodable, Equatable {
        let id: Int
        let type: String
        let title: String?
        let lang: String?
        let codec: String?
        let selected: Bool?
        let albumart: Bool?

        var isSelected: Bool { selected == true }

        var displayName: String {
            let parts = [title, lang?.uppercased(), codec].compactMap { $0?.isEmpty == false ? $0 : nil }
            return parts.isEmpty ? String(localized: "Track \(id)") : parts.joined(separator: " · ")
        }
    }

    nonisolated static let streamProtocol = "remotefiles"

    let layer = MPVMetalLayer()

    @Published private(set) var isPaused = false
    @Published private(set) var isBuffering = true
    @Published private(set) var isAtEnd = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var errorMessage: String?
    /// Display aspect ratio (width / height) of the video, once known.
    @Published private(set) var videoAspect: Double?

    var audioTracks: [Track] { tracks.filter { $0.type == "audio" } }
    var subtitleTracks: [Track] { tracks.filter { $0.type == "sub" } }
    var hasVideo: Bool { tracks.contains { $0.type == "video" && $0.albumart != true } }

    private let media: Media
    private var core: MPVCore?
    private var backgrounded = false
    private var subtitlePosition = 100

    init(media: Media) {
        self.media = media
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.framebufferOnly = true
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

    func selectTrack(_ track: Track?, type: String) {
        let property = type == "sub" ? "sid" : "aid"
        core?.setProperty(property, track.map { String($0.id) } ?? "no")
    }

    /// Moves subtitles up, as a percentage of the video height (100 is the default bottom
    /// position), so they stay above the playback controls.
    func setSubtitlePosition(_ percent: Int) {
        let percent = min(100, max(0, percent))
        guard percent != subtitlePosition else { return }
        subtitlePosition = percent
        core?.setProperty("sub-pos", String(percent))
    }

    /// MoltenVK loses its surface in the background; drop video until the app returns.
    func enterBackground() {
        guard core != nil, !backgrounded else { return }
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
        case .double("video-params/aspect", let value):
            videoAspect = value > 0 ? value : nil
        case .string("track-list", let json):
            tracks = (try? JSONDecoder().decode([Track].self, from: Data(json.utf8))) ?? []
        case .fileLoaded:
            isBuffering = false
        case .failed(let message):
            isBuffering = false
            errorMessage = message
        default:
            break
        }
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

    /// AVFoundation claims these containers but plays few of the codecs found in them (Xvid, DivX).
    private nonisolated static let avFoundationUnreliableExtensions: Set<String> = ["avi", "divx"]

    /// Media that libmpv plays but AVFoundation and QuickLook cannot (or only rarely can).
    nonisolated static func isPreferred(forFileName fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if avFoundationUnreliableExtensions.contains(ext) { return true }
        return canPlay(fileName: fileName) && RemoteMediaResourceLoader.playableType(forFileName: fileName) == nil
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

/// Works around MoltenVK shrinking the drawable to 1×1 when it forces a present,
/// which flickers or leaves the video stuck at that size (mpv-player/mpv#13651).
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
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

    /// Family name of the bundled `SubtitleFonts/NotoSansSC-Regular.otf`.
    static let subtitleFontFamily = "Noto Sans SC"

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
            ("video-rotate", "no"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            // On devices CoreText falls back to private system fonts (PingFangUI.ttc) that
            // the app cannot open, so CJK text renders as boxes and stalls rendering.
            // Use fonts embedded in the file plus a bundled CJK font instead.
            ("sub-font-provider", "none"),
            ("sub-font", MPVCore.subtitleFontFamily),
            // Render text subtitles inside the picture rather than in the black bars,
            // so they stay clear of the controls.
            ("sub-use-margins", "no"),
            // Read ahead in memory only; nothing is cached on disk.
            ("cache", "yes"),
            ("cache-on-disk", "no"),
            ("demuxer-max-bytes", "64MiB"),
            ("demuxer-max-back-bytes", "16MiB")
        ]
        for (name, value) in options {
            mpv_set_option_string(handle, name, value)
        }
        if let fonts = Bundle.main.url(forResource: "SubtitleFonts", withExtension: nil) {
            mpv_set_option_string(handle, "sub-fonts-dir", fonts.path)
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
        mpv_observe_property(handle, 0, "video-params/aspect", MPV_FORMAT_DOUBLE)
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
