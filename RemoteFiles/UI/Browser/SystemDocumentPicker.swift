import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SystemDocumentPicker: UIViewControllerRepresentable {
    enum Mode {
        case files
        case folder

        var contentTypes: [UTType] {
            switch self {
            case .files:
                return [.item]
            case .folder:
                return [.folder]
            }
        }

        var asCopy: Bool {
            switch self {
            case .files:
                return true
            case .folder:
                return false
            }
        }
    }

    let mode: Mode
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: mode.contentTypes,
            asCopy: mode.asCopy
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
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

