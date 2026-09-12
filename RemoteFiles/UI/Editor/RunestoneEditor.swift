import Runestone
import SwiftUI

private struct BasicCharacterPair: CharacterPair {
    let leading: String
    let trailing: String
}

struct RunestoneEditor: UIViewRepresentable {
    @Binding var text: String
    let fileName: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.editorDelegate = context.coordinator
        view.showLineNumbers = true
        view.alwaysBounceVertical = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.isLineWrappingEnabled = false
        view.characterPairs = [
            BasicCharacterPair(leading: "(", trailing: ")"),
            BasicCharacterPair(leading: "[", trailing: "]"),
            BasicCharacterPair(leading: "{", trailing: "}"),
            BasicCharacterPair(leading: "\"", trailing: "\"")
        ]
        let state = EditorLanguage.language(fileName: fileName).map { TextViewState(text: text, language: $0) } ?? TextViewState(text: text)
        view.setState(state)
        return view
    }

    func updateUIView(_ uiView: TextView, context: Context) {
        guard uiView.text != text, !context.coordinator.updatingFromEditor else { return }
        context.coordinator.updatingFromSwiftUI = true
        uiView.text = text
        context.coordinator.updatingFromSwiftUI = false
    }

    final class Coordinator: NSObject, TextViewDelegate {
        var text: Binding<String>
        var updatingFromEditor = false
        var updatingFromSwiftUI = false

        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: TextView) {
            guard !updatingFromSwiftUI else { return }
            updatingFromEditor = true
            text.wrappedValue = textView.text
            updatingFromEditor = false
        }
    }
}

