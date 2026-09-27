import SwiftUI

/// A white symbol on a coloured rounded square, as Settings uses for its rows.
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 29

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The badge for a connection's protocol, coloured so servers of different
/// kinds are told apart at a glance.
struct ProtocolBadge: View {
    let protocolType: RemoteProtocol
    var size: CGFloat = 29

    var body: some View {
        IconBadge(systemName: protocolType.systemImage, color: protocolType.tint, size: size)
    }
}

extension RemoteProtocol {
    var tint: Color {
        switch self {
        case .ftp: .orange
        case .ftps: .green
        case .sftp: .indigo
        case .smb: .blue
        case .webdav: .teal
        case .nfs: .purple
        }
    }
}

/// A Settings-style row label: a coloured icon badge before the title.
struct SettingsLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color

    init(_ title: LocalizedStringKey, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IconBadge(systemName: systemImage, color: color)
        }
    }
}
