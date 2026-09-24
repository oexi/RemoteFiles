import SwiftUI

/// A tile for the browser's grid layout: a large thumbnail or icon above the name.
struct BrowserGridCell: View {
    let item: RemoteItem
    let provider: (any RemoteFileProvider)?
    var selected: Bool?

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    WhiteSurFileIconView(fileName: item.name, isDirectory: item.isFolderLike, size: 64)
                }
            }
            .frame(width: 84, height: 84)
            .overlay(alignment: .bottomLeading) {
                if item.kind == .symbolicLink {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .background(.background, in: Circle())
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .background(.background, in: Circle())
                        .offset(x: 4, y: -4)
                }
            }

            Text(item.name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
            Group {
                if !item.isFolderLike, let size = item.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                } else if let date = item.modifiedAt {
                    Text(date, style: .date)
                } else {
                    Text(" ")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .task(id: item.id) {
            guard let provider, ThumbnailStore.shared.canThumbnail(item) else { return }
            thumbnail = await ThumbnailStore.shared.thumbnail(
                provider: provider,
                item: item,
                size: CGSize(width: 84, height: 84)
            )
        }
    }
}
