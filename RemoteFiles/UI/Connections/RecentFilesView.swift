import SwiftUI

/// Recently opened files, newest first and grouped by day.
struct RecentFilesView: View {
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var history: LocationHistoryStore
    @State private var confirmingClear = false

    var body: some View {
        let groups = RecentFileGroup.grouping(
            VisibleBookmark.resolve(history.recents, profiles: store.profiles)
        )
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        BookmarkLink(entry: entry, detail: .date)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { history.remove(entry.bookmark) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(group.period.title)
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No Recent Files",
                    systemImage: "clock",
                    description: Text("Files you open appear here.")
                )
            }
        }
        .navigationTitle("Recent Files")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") { confirmingClear = true }
                    .disabled(groups.isEmpty)
            }
        }
        .confirmationDialog("Clear Recent Files?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Recent Files", role: .destructive) { history.clearRecents() }
        }
    }
}

struct RecentFileGroup: Identifiable {
    enum Period: Int, CaseIterable {
        case today, yesterday, earlier

        var title: LocalizedStringKey {
            switch self {
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .earlier: "Earlier"
            }
        }

        static func of(_ date: Date, calendar: Calendar) -> Period {
            if calendar.isDateInToday(date) { return .today }
            if calendar.isDateInYesterday(date) { return .yesterday }
            return .earlier
        }
    }

    let period: Period
    let entries: [VisibleBookmark]
    var id: Int { period.rawValue }

    /// Splits recents into today, yesterday and earlier, keeping their order
    /// and leaving out empty groups.
    static func grouping(_ entries: [VisibleBookmark], calendar: Calendar = .current) -> [RecentFileGroup] {
        let byPeriod = Dictionary(grouping: entries) { Period.of($0.bookmark.date, calendar: calendar) }
        return Period.allCases.compactMap { period in
            byPeriod[period].map { RecentFileGroup(period: period, entries: $0) }
        }
    }
}
