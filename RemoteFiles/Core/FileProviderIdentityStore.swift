import FileProvider
import Foundation

struct FileProviderPathCodec {
    let rootPath: String

    func identifier(for path: String) -> NSFileProviderItemIdentifier {
        let normalized = RemotePath.normalize(path)
        if normalized == RemotePath.normalize(rootPath) { return .rootContainer }
        let encoded = Data(normalized.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return NSFileProviderItemIdentifier("path:\(encoded)")
    }

    func path(for identifier: NSFileProviderItemIdentifier) throws -> String {
        if identifier == .rootContainer { return RemotePath.normalize(rootPath) }
        guard identifier.rawValue.hasPrefix("path:") else {
            throw RemoteProviderError.invalidResponse("Unknown File Provider item identifier.")
        }
        var encoded = String(identifier.rawValue.dropFirst(5))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded), let value = String(data: data, encoding: .utf8) else {
            throw RemoteProviderError.invalidResponse("Invalid File Provider item identifier.")
        }
        guard let path = RemotePath.confined(value, to: rootPath) else {
            throw RemoteProviderError.invalidResponse("File Provider item path is outside the configured root.")
        }
        return path
    }

    func childPath(parent: String, filename: String) throws -> String {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RemoteProviderError.invalidResponse("Invalid File Provider item filename.")
        }
        let path = RemotePath.join(parent, filename)
        guard let confined = RemotePath.confined(path, to: rootPath),
              confined != RemotePath.normalize(parent) else {
            throw RemoteProviderError.invalidResponse("File Provider item path is outside the configured root.")
        }
        return confined
    }

    func contains(_ path: String) -> Bool {
        RemotePath.confined(path, to: rootPath) != nil
    }

    func containsDirectChild(_ path: String, of containerPath: String) -> Bool {
        contains(containerPath) && RemotePath.isDirectChild(path, of: containerPath)
    }

    func parentIdentifier(for path: String) -> NSFileProviderItemIdentifier {
        identifier(for: RemotePath.parent(path))
    }
}

/// Persists the small amount of File Provider identity state that cannot be derived from a
/// remote path alone.
///
/// Most items continue to use the historical `path:` identifier. Observed
/// paths are registered so an extension-owned directory move can preserve the
/// identifiers of its descendants; a generated `item:` identifier is needed
/// only when an old path is reused after a move. This deliberately does not
/// guess at renames performed by another remote client because the supported
/// protocols do not all expose a stable object ID.
final class FileProviderIdentityStore: @unchecked Sendable {
    private static let appGroupIdentifier = "group.com.oexi.RemoteFiles"

    private struct State: Codable {
        var identifiers: [String: String] = [:]
        var origins: [String: String] = [:]

        private enum CodingKeys: String, CodingKey {
            case identifiers
            case origins
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identifiers = try container.decodeIfPresent([String: String].self, forKey: .identifiers) ?? [:]
            origins = try container.decodeIfPresent([String: String].self, forKey: .origins) ?? [:]
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var state: State

    init(profileID: UUID, directory: URL? = nil) {
        let baseDirectory = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        fileURL = baseDirectory
            .appendingPathComponent(profileID.uuidString)
            .appendingPathExtension("json")
        state = Self.load(from: fileURL)
    }

    /// Resolves an item identifier, honoring extension-owned move mappings
    /// before falling back to the legacy path encoding.
    func path(
        for identifier: NSFileProviderItemIdentifier,
        codec: FileProviderPathCodec
    ) throws -> String {
        if identifier == .rootContainer {
            return RemotePath.normalize(codec.rootPath)
        }

        lock.lock()
        let mappedPath = state.identifiers[identifier.rawValue]
        let legacyPath: String?
        if mappedPath == nil {
            legacyPath = try? codec.path(for: identifier)
        } else {
            legacyPath = nil
        }
        let translatedPath = legacyPath.flatMap {
            translatedPathLocked(for: $0, codec: codec)
        }
        lock.unlock()

        if let mappedPath,
           let confined = RemotePath.confined(mappedPath, to: codec.rootPath) {
            return confined
        }
        if let translatedPath {
            return translatedPath
        }
        return try codec.path(for: identifier)
    }

    /// Returns the stable identifier for a path.  Existing `path:` IDs remain
    /// unchanged during migration, so an upgrade does not invalidate all
    /// items in an existing File Provider snapshot.
    func identifier(
        for path: String,
        codec: FileProviderPathCodec
    ) throws -> NSFileProviderItemIdentifier {
        guard let confined = RemotePath.confined(path, to: codec.rootPath) else {
            throw RemoteProviderError.invalidResponse(
                "File Provider item path is outside the configured root."
            )
        }
        if confined == RemotePath.normalize(codec.rootPath) {
            return .rootContainer
        }

        lock.lock()
        defer { lock.unlock() }

        let previous = state
        let result = try identifierLocked(for: confined, codec: codec)
        do {
            if state.identifiers != previous.identifiers || state.origins != previous.origins {
                try persistLocked()
            }
        } catch {
            state = previous
            throw error
        }
        return result
    }

    /// Read-only lookup for the app, which must never write the extension's
    /// identity state. Returns the identifier the extension reports for an
    /// already-known path, or nil when resolving it would mint a new one
    /// (the extension has not enumerated that item yet).
    func knownIdentifier(
        for path: String,
        codec: FileProviderPathCodec
    ) -> NSFileProviderItemIdentifier? {
        guard let confined = RemotePath.confined(path, to: codec.rootPath) else { return nil }
        if confined == RemotePath.normalize(codec.rootPath) {
            return .rootContainer
        }

        lock.lock()
        defer { lock.unlock() }

        let snapshot = state
        defer { state = snapshot }
        guard let identifier = try? identifierLocked(for: confined, codec: codec),
              state.identifiers == snapshot.identifiers else {
            return nil
        }
        return identifier
    }

    /// Registers a batch of paths with one persistence operation.  Enumeration
    /// uses this to make already-observed descendants available for a later
    /// directory move without writing one file per item.
    func register(paths: [String], codec: FileProviderPathCodec) throws {
        lock.lock()
        defer { lock.unlock() }
        let previous = state
        do {
            for path in paths {
                guard let confined = RemotePath.confined(path, to: codec.rootPath),
                      confined != RemotePath.normalize(codec.rootPath) else {
                    continue
                }
                let identifier = try identifierLocked(for: confined, codec: codec)
                state.identifiers[identifier.rawValue] = confined
            }
            if state.identifiers != previous.identifiers || state.origins != previous.origins {
                try persistLocked()
            }
        } catch {
            state = previous
            throw error
        }
    }

    /// Records a move performed by the extension.  The provider operation is
    /// intentionally responsible for deciding whether the target conflicts;
    /// this method only updates the local identity after that operation has
    /// succeeded.
    func relocate(
        identifier: NSFileProviderItemIdentifier,
        from oldPath: String,
        to newPath: String,
        codec: FileProviderPathCodec
    ) throws {
        guard identifier != .rootContainer,
              let oldPath = RemotePath.confined(oldPath, to: codec.rootPath),
              let newPath = RemotePath.confined(newPath, to: codec.rootPath),
              oldPath != RemotePath.normalize(codec.rootPath),
              newPath != RemotePath.normalize(codec.rootPath) else {
            throw RemoteProviderError.invalidResponse("Invalid File Provider move.")
        }

        lock.lock()
        defer { lock.unlock() }

        let knownPath = resolvedPathLocked(for: identifier, codec: codec)
        guard let knownPath,
              RemotePath.normalize(knownPath) == oldPath else {
            throw RemoteProviderError.invalidResponse(
                "File Provider item identity does not match its current path."
            )
        }

        let previous = state
        let movedIdentifiers = state.identifiers.compactMap { entry -> (String, String)? in
            let key = entry.key
            let value = entry.value
            guard RemotePath.isDescendantOrEqual(value, of: oldPath) else { return nil }
            let suffix = String(value.dropFirst(oldPath.count))
            let translated = suffix.isEmpty
                ? newPath
                : RemotePath.join(newPath, String(suffix.dropFirst()))
            return (key, translated)
        }
        let movingKeys = Set(movedIdentifiers.map { $0.0 }).union([identifier.rawValue])
        // A successful provider move makes any old identity for the target
        // path stale.  Removing it also prevents two IDs from resolving to
        // one path after an external deletion/recreation sequence.
        state.identifiers = state.identifiers.filter { entry in
            movingKeys.contains(entry.key)
                || !RemotePath.isDescendantOrEqual(entry.value, of: newPath)
        }
        for (key, value) in movedIdentifiers {
            state.identifiers[key] = value
        }
        state.identifiers[identifier.rawValue] = newPath
        if state.origins[identifier.rawValue] == nil,
           identifier.rawValue.hasPrefix("item:") {
            state.origins[identifier.rawValue] = oldPath
        }
        do {
            try persistLocked()
        } catch {
            state = previous
            throw error
        }
    }

    /// Drops identities for a deleted item and, for a directory, its known
    /// descendants.  Legacy path identifiers need no explicit tombstone: if
    /// they are later requested, the codec still decodes their old path.
    func remove(
        identifier: NSFileProviderItemIdentifier,
        includingDescendantsOf path: String? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let previous = state
        let normalizedPath = path.map(RemotePath.normalize)
        state.identifiers = state.identifiers.filter { entry in
            if entry.key == identifier.rawValue { return false }
            guard let normalizedPath else { return true }
            return !RemotePath.isDescendantOrEqual(entry.value, of: normalizedPath)
        }
        let removed = Set(previous.identifiers.keys).subtracting(state.identifiers.keys)
        for key in removed {
            state.origins.removeValue(forKey: key)
        }
        do {
            try persistLocked()
        } catch {
            state = previous
            throw error
        }
    }

    private func identifierLocked(
        for confined: String,
        codec: FileProviderPathCodec
    ) throws -> NSFileProviderItemIdentifier {
        // A moved item keeps its original identifier at its new path.
        if let existing = state.identifiers
            .filter({ RemotePath.normalize($0.value) == confined })
            .map({ $0.key })
            .sorted()
            .first {
            return NSFileProviderItemIdentifier(existing)
        }

        // If a parent directory moved, derive the old path of an as-yet
        // unobserved descendant so its legacy identifier can remain stable.
        let sourcePath = sourcePathLocked(forCurrentPath: confined, codec: codec)
        let legacy = codec.identifier(for: sourcePath)
        // If the old virtual path is now occupied by a different remote
        // object, resolving that legacy ID would incorrectly translate it
        // into the moved directory.  Give the new object its own ID.
        if let translatedLegacyPath = translatedPathLocked(for: sourcePath, codec: codec),
           RemotePath.normalize(translatedLegacyPath) != confined {
            let fresh = NSFileProviderItemIdentifier("item:\(UUID().uuidString)")
            state.identifiers[fresh.rawValue] = confined
            state.origins[fresh.rawValue] = sourcePath
            return fresh
        }
        // The legacy identifier is available unless it is currently owned by
        // an extension-moved item at another path.
        if let owner = state.identifiers[legacy.rawValue],
           RemotePath.normalize(owner) != confined {
            let fresh = NSFileProviderItemIdentifier("item:\(UUID().uuidString)")
            state.identifiers[fresh.rawValue] = confined
            state.origins[fresh.rawValue] = sourcePath
            return fresh
        }
        return legacy
    }

    private func resolvedPathLocked(
        for identifier: NSFileProviderItemIdentifier,
        codec: FileProviderPathCodec
    ) -> String? {
        if let mappedPath = state.identifiers[identifier.rawValue],
           let confined = RemotePath.confined(mappedPath, to: codec.rootPath) {
            return confined
        }
        guard let legacyPath = try? codec.path(for: identifier) else { return nil }
        return translatedPathLocked(for: legacyPath, codec: codec) ?? legacyPath
    }

    private func translatedPathLocked(
        for legacyPath: String,
        codec: FileProviderPathCodec
    ) -> String? {
        let normalized = RemotePath.normalize(legacyPath)
        let candidates = state.identifiers.compactMap { entry -> (String, String, String)? in
            guard let origin = originPathLocked(for: entry.key, codec: codec),
                  RemotePath.isDescendantOrEqual(normalized, of: origin),
                  let confined = RemotePath.confined(entry.value, to: codec.rootPath) else {
                return nil
            }
            return (origin, confined, entry.key)
        }
        guard let best = candidates.max(by: { $0.0.count < $1.0.count }) else { return nil }
        let suffix = String(normalized.dropFirst(best.0.count))
        return suffix.isEmpty
            ? best.1
            : RemotePath.join(best.1, String(suffix.dropFirst()))
    }

    private func sourcePathLocked(
        forCurrentPath currentPath: String,
        codec: FileProviderPathCodec
    ) -> String {
        let candidates = state.identifiers.compactMap { entry -> (String, String)? in
            guard let origin = originPathLocked(for: entry.key, codec: codec),
                  RemotePath.isDescendantOrEqual(currentPath, of: entry.value),
                  currentPath != RemotePath.normalize(entry.value) else {
                return nil
            }
            return (entry.value, origin)
        }
        guard let best = candidates.max(by: { $0.0.count < $1.0.count }) else {
            return currentPath
        }
        let suffix = String(currentPath.dropFirst(best.0.count))
        return suffix.isEmpty
            ? best.1
            : RemotePath.join(best.1, String(suffix.dropFirst()))
    }

    private func originPathLocked(
        for identifier: String,
        codec: FileProviderPathCodec
    ) -> String? {
        if let origin = state.origins[identifier] {
            return RemotePath.normalize(origin)
        }
        return try? codec.path(for: NSFileProviderItemIdentifier(identifier))
    }

    private func persistLocked() throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> State {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return decoded
    }

    private static func defaultDirectory() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("FileProviderIdentities", isDirectory: true)
    }
}

/// Builds deletions from a path-keyed snapshot while preserving a moved
/// item's identifier. A rename initiated by this extension appears as a new
/// path plus the old path disappearing; if both paths carry the same
/// identifier, only the update should be delivered to File Provider.
func fileProviderDeletedItemIdentifiers(
    previousFingerprints: [String: String],
    previousIdentifiers: [String: String],
    currentIdentifiers: Set<String>,
    codec: FileProviderPathCodec
) -> [NSFileProviderItemIdentifier] {
    var seen = Set<String>()
    return previousFingerprints.keys.compactMap { path in
        let rawIdentifier = previousIdentifiers[path] ?? codec.identifier(for: path).rawValue
        guard currentIdentifiers.contains(rawIdentifier) == false,
              seen.insert(rawIdentifier).inserted else {
            return nil
        }
        return NSFileProviderItemIdentifier(rawIdentifier)
    }
}
