import Foundation

enum RemoteFileOperations {
    static func removeRecursively(
        _ item: RemoteItem,
        provider: any RemoteFileProvider
    ) async throws {
        guard item.isDirectory else {
            try await provider.remove(path: item.path, isDirectory: false)
            return
        }

        let children = try await provider.list(path: item.path)
        for child in children {
            try Task.checkCancellation()
            try await removeRecursively(child, provider: provider)
        }
        try await provider.remove(path: item.path, isDirectory: true)
    }

    static func removeRecursively(
        path: String,
        provider: any RemoteFileProvider
    ) async throws {
        let item = try await provider.attributes(path: path)
        try await removeRecursively(item, provider: provider)
    }
}
