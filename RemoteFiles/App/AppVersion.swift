import Foundation

enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var display: String { "\(short) (\(build))" }
    static var userAgent: String { "RemoteFiles/\(short) (iOS)" }
}
