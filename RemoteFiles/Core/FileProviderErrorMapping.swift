import FileProvider
import Foundation
import Network

/// Translates provider errors into the `NSFileProviderError` codes the Files
/// app understands, so a missing item is removed instead of lingering, a bad
/// credential prompts for authentication and an offline server is retried.
/// Errors without a File Provider equivalent are returned unchanged so their
/// descriptive message still reaches the user.
enum FileProviderErrorMapping {
    static func map(_ error: Error) -> Error {
        if error is NSFileProviderError { return error }
        if error is CancellationError { return CocoaError(.userCancelled) }
        if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled { return error }

        if RemoteProviderError.isNotFound(error) {
            return NSFileProviderError(.noSuchItem)
        }
        if let providerError = error as? RemoteProviderError {
            switch providerError {
            case .authenticationRequired:
                return NSFileProviderError(.notAuthenticated)
            case .notConnected:
                return NSFileProviderError(.serverUnreachable)
            case .conflict:
                return NSFileProviderError(.filenameCollision)
            default:
                return error
            }
        }
        if isServerUnreachable(error) {
            return NSFileProviderError(.serverUnreachable)
        }
        return error
    }

    static func isServerUnreachable(_ error: Error) -> Bool {
        if error is NWError { return true }
        if let urlError = error as? URLError {
            let codes: Set<URLError.Code> = [
                .notConnectedToInternet,
                .networkConnectionLost,
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed,
                .timedOut,
                .internationalRoamingOff,
                .dataNotAllowed
            ]
            return codes.contains(urlError.code)
        }
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else { return false }
        let codes: Set<Int32> = [
            ECONNREFUSED, ECONNRESET, ECONNABORTED, ENOTCONN, EPIPE,
            ETIMEDOUT, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH
        ]
        return codes.contains(Int32(nsError.code))
    }
}
