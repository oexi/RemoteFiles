import UIKit

/// Presents the system document picker for uploads straight from UIKit.
///
/// Inside a SwiftUI sheet the picker dismisses itself behind SwiftUI's back:
/// the sheet's `onDismiss` could fire late, and a name-conflict dialog
/// presented while the picker was still on screen blocked its dismissal, so
/// Open seemed to do nothing. Here `onPick` runs only after the picker has
/// left the screen, when the browser can present its own dialogs again.
@MainActor
final class UploadPicker: NSObject, UIDocumentPickerDelegate {
    private var onPick: (([URL]) -> Void)?

    func present(mode: SystemDocumentPicker.Mode, onPick: @escaping ([URL]) -> Void) {
        guard let presenter = Self.topViewController() else { return }
        let picker = mode.makeController()
        picker.delegate = self
        self.onPick = onPick
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let onPick else { return }
        self.onPick = nil
        // Close the picker here unless it is already closing, so a conflict
        // dialog is never presented while it is still on screen.
        if controller.presentingViewController != nil, !controller.isBeingDismissed {
            controller.dismiss(animated: true) { onPick(urls) }
            return
        }
        Task { @MainActor in
            // Already closing: wait until it is gone (bounded) before continuing.
            for _ in 0..<60 {
                guard controller.presentingViewController != nil || controller.isBeingDismissed else { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            onPick(urls)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
