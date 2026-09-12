import SwiftUI
import UIKit

struct EmptyFolderRefreshView: UIViewRepresentable {
    let onRefresh: @MainActor () async -> Void
    let onTap: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRefresh: onRefresh, onTap: onTap)
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

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) { }

    final class Coordinator: NSObject {
        private let onRefresh: @MainActor () async -> Void
        private let onTap: @MainActor () -> Void

        init(
            onRefresh: @escaping @MainActor () async -> Void,
            onTap: @escaping @MainActor () -> Void
        ) {
            self.onRefresh = onRefresh
            self.onTap = onTap
        }

        @objc func refresh(_ sender: UIRefreshControl) {
            Task { @MainActor in
                await onRefresh()
                sender.endRefreshing()
            }
        }

        @objc func tap() {
            Task { @MainActor in onTap() }
        }
    }
}

