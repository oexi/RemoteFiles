import Foundation
import Combine

@MainActor
final class FileOperationClipboard: ObservableObject {
    enum Operation: String, Sendable {
        case copy
        case move
    }

    @Published private(set) var operation: Operation?
    @Published private(set) var sourceProfileID: UUID?
    @Published private(set) var items: [RemoteItem] = []

    var isEmpty: Bool { items.isEmpty || operation == nil || sourceProfileID == nil }

    func set(_ items: [RemoteItem], from profileID: UUID, operation: Operation) {
        self.items = items
        self.sourceProfileID = profileID
        self.operation = operation
    }

    func clear() {
        operation = nil
        sourceProfileID = nil
        items = []
    }
}
