import SwiftUI

enum BrowserSortKey: String, CaseIterable, Identifiable {
    case name
    case modified
    case size
    case kind

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    /// Newest and largest first reads better than the opposite for these keys.
    var defaultAscending: Bool {
        switch self {
        case .name, .kind: true
        case .modified, .size: false
        }
    }
}

enum BrowserLayout: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
}

struct BrowserSortOrder: Equatable {
    var key: BrowserSortKey = .name
    var ascending = true
    var foldersFirst = true

    /// Sorts by `key`, falling back to the name so equal values keep a stable order.
    /// Items without a size or date always sort after items that have one.
    func sorted(_ items: [RemoteItem]) -> [RemoteItem] {
        items.sorted(by: areInIncreasingOrder)
    }

    func areInIncreasingOrder(_ lhs: RemoteItem, _ rhs: RemoteItem) -> Bool {
        if foldersFirst, lhs.isFolderLike != rhs.isFolderLike {
            return lhs.isFolderLike
        }
        let primary: ComparisonResult
        switch key {
        case .name:
            primary = .orderedSame
        case .modified:
            if let order = Self.missingLast(lhs.modifiedAt, rhs.modifiedAt) { return order }
            primary = Self.compare(lhs.modifiedAt, rhs.modifiedAt)
        case .size:
            let left = lhs.isFolderLike ? nil : lhs.size
            let right = rhs.isFolderLike ? nil : rhs.size
            if let order = Self.missingLast(left, right) { return order }
            primary = Self.compare(left, right)
        case .kind:
            primary = Self.fileExtension(lhs).localizedStandardCompare(Self.fileExtension(rhs))
        }
        if primary != .orderedSame {
            return (primary == .orderedAscending) == ascending
        }
        // Ties read A to Z, unless the user is sorting by name itself.
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        if byName == .orderedSame { return false }
        return (byName == .orderedAscending) == (key == .name ? ascending : true)
    }

    /// Returns the order when exactly one value is missing, or nil when both are present or absent.
    private static func missingLast<T>(_ lhs: T?, _ rhs: T?) -> Bool? {
        switch (lhs, rhs) {
        case (.some, nil): true
        case (nil, .some): false
        default: nil
        }
    }

    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        guard let lhs, let rhs, lhs != rhs else { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func fileExtension(_ item: RemoteItem) -> String {
        item.isFolderLike ? "" : (item.name as NSString).pathExtension.lowercased()
    }
}
