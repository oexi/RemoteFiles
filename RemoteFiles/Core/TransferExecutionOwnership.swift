import Foundation

struct TransferExecutionToken: Hashable, Sendable {
    let id: UUID

    init() {
        id = UUID()
    }
}

/// Gives each attempt exclusive ownership of a transfer record. Invalidating a
/// token prevents late cancellation/error/progress callbacks from touching a retry.
struct TransferExecutionOwnership: Sendable {
    private(set) var activeToken: TransferExecutionToken?

    mutating func begin() -> TransferExecutionToken {
        let token = TransferExecutionToken()
        activeToken = token
        return token
    }

    mutating func invalidate() {
        activeToken = nil
    }

    func owns(_ token: TransferExecutionToken) -> Bool {
        activeToken == token
    }

    @discardableResult
    mutating func finish(_ token: TransferExecutionToken) -> Bool {
        guard owns(token) else { return false }
        activeToken = nil
        return true
    }
}
