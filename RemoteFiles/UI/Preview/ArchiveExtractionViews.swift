import SwiftUI

/// The progress bar pinned to the bottom of an archive screen while it extracts.
struct ArchiveExtractionProgressView: View {
    let progress: ArchiveExtractionProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if progress.fraction == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let fraction = progress.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            ProgressView(value: progress.fraction ?? 0)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .animation(.default, value: progress)
    }

    private var title: LocalizedStringKey {
        switch progress.phase {
        case .downloading: "Downloading archive…"
        case .extracting: "Extracting…"
        case .uploading: "Uploading extracted files…"
        }
    }
}

extension View {
    /// Asks whether to extract an archive with several top-level items into a new folder
    /// named after the archive or straight into the current folder.
    func archiveExtractionChoice(
        isPresented: Binding<Bool>,
        archiveName: String,
        extract: @escaping (_ intoFolder: Bool) -> Void
    ) -> some View {
        confirmationDialog(
            "Extract Archive",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Extract to “\(ArchiveManager.suggestedFolderName(for: archiveName))”") {
                extract(true)
            }
            Button("Extract into Current Folder") {
                extract(false)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This archive has several items at its top level. Extract them into a new folder?")
        }
    }
}
