import SwiftUI
import UIKit

/// UIKit-backed share sheet with an explicit popover anchor. SwiftUI's ShareLink normally supplies
/// this for us, but containerised/sideloaded hosts (and some iPad presentation paths) can surface a
/// UIActivityViewController without one and UIKit will raise an exception.
struct SystemShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> ShareHostViewController {
        ShareHostViewController(urls: urls, onFinish: onFinish)
    }

    func updateUIViewController(_ uiViewController: ShareHostViewController, context: Context) { }

    final class ShareHostViewController: UIViewController {
        private let urls: [URL]
        private let onFinish: () -> Void
        private var didPresent = false

        init(urls: [URL], onFinish: @escaping () -> Void) {
            self.urls = urls
            self.onFinish = onFinish
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !didPresent else { return }
            didPresent = true

            let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
            activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
                guard let self else { return }
                DispatchQueue.main.async { self.onFinish() }
            }

            if let popover = activity.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(
                    x: view.bounds.midX,
                    y: view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            present(activity, animated: true)
        }
    }
}
