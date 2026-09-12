import Foundation

enum TextFileDetector {
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
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
            return utf8
        }

        // Only try UTF-16 without a BOM when the byte layout actually resembles UTF-16 text.
        if data.count >= 4 {
            let sample = data.prefix(min(data.count, 4096))
            let evenNuls = sample.enumerated().filter { $0.offset.isMultiple(of: 2) && $0.element == 0 }.count
            let oddNuls = sample.enumerated().filter { !$0.offset.isMultiple(of: 2) && $0.element == 0 }.count
            let threshold = max(2, sample.count / 8)
            if oddNuls >= threshold,
               let value = String(data: data, encoding: .utf16LittleEndian), looksLikeText(value) {
                return value
            }
            if evenNuls >= threshold,
               let value = String(data: data, encoding: .utf16BigEndian), looksLikeText(value) {
                return value
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
