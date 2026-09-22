import Foundation

/// The on-disk text encoding of a file opened in an editor. Saving must use
/// the same encoding and byte-order mark, otherwise editing a UTF-16 or BOM
/// file silently rewrites it as plain UTF-8.
enum TextEncoding: Equatable, Sendable {
    case utf8(byteOrderMark: Bool)
    case utf16LittleEndian(byteOrderMark: Bool)
    case utf16BigEndian(byteOrderMark: Bool)

    static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    static let utf16LittleEndianBOM: [UInt8] = [0xFF, 0xFE]
    static let utf16BigEndianBOM: [UInt8] = [0xFE, 0xFF]

    func encode(_ text: String) -> Data? {
        switch self {
        case .utf8(let byteOrderMark):
            return (byteOrderMark ? Data(Self.utf8BOM) : Data()) + Data(text.utf8)
        case .utf16LittleEndian(let byteOrderMark):
            guard let body = text.data(using: .utf16LittleEndian) else { return nil }
            return (byteOrderMark ? Data(Self.utf16LittleEndianBOM) : Data()) + body
        case .utf16BigEndian(let byteOrderMark):
            guard let body = text.data(using: .utf16BigEndian) else { return nil }
            return (byteOrderMark ? Data(Self.utf16BigEndianBOM) : Data()) + body
        }
    }
}

struct DecodedText: Equatable, Sendable {
    let text: String
    let encoding: TextEncoding
}

enum TextFileDetector {
    static func decode(_ data: Data) -> String? {
        decodeText(data)?.text
    }

    static func decodeText(_ data: Data) -> DecodedText? {
        guard !data.isEmpty else { return DecodedText(text: "", encoding: .utf8(byteOrderMark: false)) }

        if data.starts(with: TextEncoding.utf8BOM) {
            return String(data: data.dropFirst(3), encoding: .utf8)
                .map { DecodedText(text: $0, encoding: .utf8(byteOrderMark: true)) }
        }
        if data.starts(with: TextEncoding.utf16LittleEndianBOM) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
                .map { DecodedText(text: $0, encoding: .utf16LittleEndian(byteOrderMark: true)) }
        }
        if data.starts(with: TextEncoding.utf16BigEndianBOM) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
                .map { DecodedText(text: $0, encoding: .utf16BigEndian(byteOrderMark: true)) }
        }

        // Common binary signatures. Extensionless binaries should never fall through to the text editor.
        let signatures: [[UInt8]] = [
            [0x7F, 0x45, 0x4C, 0x46],                         // ELF
            [0xCF, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF], // Mach-O
            [0xCA, 0xFE, 0xBA, 0xBE],                         // Mach-O universal / Java class
            [0x89, 0x50, 0x4E, 0x47],                         // PNG
            [0xFF, 0xD8, 0xFF],                               // JPEG
            [0x47, 0x49, 0x46, 0x38],                         // GIF
            [0x50, 0x4B, 0x03, 0x04],                         // ZIP
            [0x1F, 0x8B],                                     // GZip
            [0x25, 0x50, 0x44, 0x46]                          // PDF
        ]
        if signatures.contains(where: { data.starts(with: $0) }) { return nil }

        if let utf8 = String(data: data, encoding: .utf8), looksLikeText(utf8) {
            return DecodedText(text: utf8, encoding: .utf8(byteOrderMark: false))
        }

        // Only try UTF-16 without a BOM when the byte layout actually resembles UTF-16 text.
        if data.count >= 4 {
            let sample = data.prefix(min(data.count, 4096))
            let evenNuls = sample.enumerated().filter { $0.offset.isMultiple(of: 2) && $0.element == 0 }.count
            let oddNuls = sample.enumerated().filter { !$0.offset.isMultiple(of: 2) && $0.element == 0 }.count
            let threshold = max(2, sample.count / 8)
            if oddNuls >= threshold,
               let value = String(data: data, encoding: .utf16LittleEndian), looksLikeText(value) {
                return DecodedText(text: value, encoding: .utf16LittleEndian(byteOrderMark: false))
            }
            if evenNuls >= threshold,
               let value = String(data: data, encoding: .utf16BigEndian), looksLikeText(value) {
                return DecodedText(text: value, encoding: .utf16BigEndian(byteOrderMark: false))
            }
        }
        return nil
    }

    private static func looksLikeText(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        var controls = 0
        var total = 0
        for scalar in value.unicodeScalars.prefix(8192) {
            total += 1
            if scalar.value == 0 { return false }
            if scalar.value < 0x20,
               scalar.value != 0x0A,
               scalar.value != 0x0D,
               scalar.value != 0x09 {
                controls += 1
            }
        }
        return total == 0 || Double(controls) / Double(total) < 0.02
    }
}
