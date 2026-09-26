import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SystemDocumentPicker: UIViewControllerRepresentable {
    enum Mode {
        case files
        case folder
        case privateKey

        var contentTypes: [UTType] {
            switch self {
            case .files:
                return [.item]
            case .folder:
                return [.folder]
            case .privateKey:
                // OpenSSH private keys are commonly extensionless, .pem, or arbitrary
                // text/data files. `.item` keeps extensionless keys selectable.
                return [.item]
            }
        }

        var asCopy: Bool {
            switch self {
            case .files, .privateKey:
                return true
            case .folder:
                return false
            }
        }

        var allowsMultipleSelection: Bool {
            switch self {
            case .files:
                return true
            case .folder, .privateKey:
                // With multiple selection the folder picker shows checkboxes,
                // and Open never returned the folder being viewed, so
                // nothing happened. Single selection makes Open pick it.
                return false
            }
        }

        func makeController() -> UIDocumentPickerViewController {
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: contentTypes,
                asCopy: asCopy
            )
            picker.allowsMultipleSelection = allowsMultipleSelection
            picker.shouldShowFileExtensions = true
            return picker
        }
    }

    let mode: Mode
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = mode.makeController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

