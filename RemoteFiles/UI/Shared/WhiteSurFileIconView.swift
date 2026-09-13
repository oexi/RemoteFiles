import SwiftUI

enum WhiteSurFileIcon {
    static func assetName(fileName: String, isDirectory: Bool) -> String {
        if isDirectory {
            return folderAssetName(fileName: fileName)
        }

        let ext = (fileName as NSString).pathExtension.lowercased()
        if ArchiveManager.canOpen(fileName: fileName) {
            return "WhiteSurFileArchive"
        }
        if ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg"].contains(ext) {
            return "WhiteSurFileImage"
        }
        if ["mp4", "mov", "m4v", "mkv", "avi", "webm", "mpeg", "mpg", "ts"].contains(ext) {
            return "WhiteSurFileVideo"
        }
        if ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "alac"].contains(ext) {
            return "WhiteSurFileAudio"
        }
        if ext == "pdf" {
            return "WhiteSurFilePDF"
        }
        if ["doc", "docx", "odt", "rtf", "pages"].contains(ext) {
            return "WhiteSurFileDocument"
        }
        if ["xls", "xlsx", "ods", "csv", "numbers"].contains(ext) {
            return "WhiteSurFileSpreadsheet"
        }
        if ["ppt", "pptx", "odp", "key", "keynote"].contains(ext) {
            return "WhiteSurFilePresentation"
        }
        if ["exe", "msi", "appimage", "apk", "ipa", "deb", "rpm", "dmg", "pkg"].contains(ext) {
            return "WhiteSurFileExecutable"
        }
        if EditorLanguage.language(fileName: fileName) != nil {
            return "WhiteSurFileCode"
        }
        if EditorLanguage.isEditable(fileName: fileName) {
            return "WhiteSurFileText"
        }
        return "WhiteSurFileGeneric"
    }

    private static func folderAssetName(fileName: String) -> String {
        let name = fileName.lowercased()
        if ["documents", "document", "docs"].contains(name) {
            return "WhiteSurFolderDocuments"
        }
        if ["pictures", "picture", "images", "image", "photos", "photo"].contains(name) {
            return "WhiteSurFolderImages"
        }
        if ["videos", "video", "movies", "movie"].contains(name) {
            return "WhiteSurFolderVideos"
        }
        if ["music", "audio"].contains(name) {
            return "WhiteSurFolderMusic"
        }
        if ["downloads", "download"].contains(name) {
            return "WhiteSurFolderDownloads"
        }
        if ["src", "source", "sources", "code", "projects", "project", "workspace", ".git", "www"].contains(name) {
            return "WhiteSurFolderCode"
        }
        return "WhiteSurFolder"
    }
}

struct WhiteSurFileIconView: View {
    let fileName: String
    let isDirectory: Bool
    var size: CGFloat = 36

    var body: some View {
        Image(WhiteSurFileIcon.assetName(fileName: fileName, isDirectory: isDirectory))
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
