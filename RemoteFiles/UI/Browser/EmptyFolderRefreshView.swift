import SwiftUI
import UIKit

struct EmptyFolderRefreshView: UIViewRepresentable {
    let onRefresh: @MainActor () async -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRefresh: onRefresh)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(
            context.coordinator,
            action: #selector(Coordinator.refresh(_:)),
            for: .valueChanged
        )
        scrollView.refreshControl = refreshControl
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) { }

    final class Coordinator: NSObject {
        private let onRefresh: @MainActor () async -> Void

        init(onRefresh: @escaping @MainActor () async -> Void) {
            self.onRefresh = onRefresh
        }

        @objc func refresh(_ sender: UIRefreshControl) {
            Task { @MainActor in
                await onRefresh()
                sender.endRefreshing()
            }
        }
    }
}

