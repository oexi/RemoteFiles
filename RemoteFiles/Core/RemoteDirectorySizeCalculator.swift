import Foundation

struct RemoteDirectorySizeResult: Sendable, Equatable {
    let bytes: Int64
    let skippedItemCount: Int
}

enum RemoteDirectorySizeCalculator {
    static func calculate(
        path: String,
        provider: any RemoteFileProvider
    ) async throws -> RemoteDirectorySizeResult {
        let children = try await provider.list(path: path)
        return try await sum(children, provider: provider)
    }

    private static func sum(
        _ children: [RemoteItem],
        provider: any RemoteFileProvider
    ) async throws -> RemoteDirectorySizeResult {
        var bytes: Int64 = 0
        var skipped = 0

        for child in children {
            try Task.checkCancellation()

            if child.isDirectory {
                do {
                    let nestedChildren = try await provider.list(path: child.path)
                    let nested = try await sum(nestedChildren, provider: provider)
                    bytes += nested.bytes
                    skipped += nested.skippedItemCount
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    skipped += 1
                }
                continue
            }

            if let size = child.size {
                bytes += max(0, size)
                continue
            }

            do {
                if let size = try await provider.attributes(path: child.path).size {
                    bytes += max(0, size)
                } else {
                    skipped += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped += 1
            }
        }

        return RemoteDirectorySizeResult(bytes: bytes, skippedItemCount: skipped)
    }
}
