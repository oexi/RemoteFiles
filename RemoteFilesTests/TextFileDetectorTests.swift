import XCTest
@testable import RemoteFiles

final class TextFileDetectorTests: XCTestCase {
    func testExtensionlessUtf8TextIsDetected() {
        let data = Data("#!/bin/sh\necho hello\n".utf8)
        XCTAssertEqual(TextFileDetector.decode(data), "#!/bin/sh\necho hello\n")
        XCTAssertTrue(EditorLanguage.isEditable(fileName: "authorized_keys"))
        XCTAssertTrue(EditorLanguage.isEditable(fileName: "LICENSE"))
    }

    func testBinaryDataIsRejected() {
        XCTAssertNil(TextFileDetector.decode(Data([0x7F, 0x45, 0x4C, 0x46, 0, 1, 2, 3])))
        XCTAssertNil(TextFileDetector.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))
    }
}

final class TextEncodingRoundTripTests: XCTestCase {
    func testUtf16LittleEndianWithBOMRoundTrips() throws {
        let body = try XCTUnwrap("Windows Registry Editor\r\nhéllo".data(using: .utf16LittleEndian))
        let original = Data(TextEncoding.utf16LittleEndianBOM) + body

        let decoded = try XCTUnwrap(TextFileDetector.decodeText(original))

        XCTAssertEqual(decoded.text, "Windows Registry Editor\r\nhéllo")
        XCTAssertEqual(decoded.encoding, .utf16LittleEndian(byteOrderMark: true))
        XCTAssertEqual(decoded.encoding.encode(decoded.text), original)
    }

    func testUtf16BigEndianBOMIsNotPartOfTheText() throws {
        let body = try XCTUnwrap("abc".data(using: .utf16BigEndian))
        let original = Data(TextEncoding.utf16BigEndianBOM) + body

        let decoded = try XCTUnwrap(TextFileDetector.decodeText(original))

        XCTAssertEqual(decoded.text, "abc")
        XCTAssertEqual(decoded.encoding.encode("abcd"), Data(TextEncoding.utf16BigEndianBOM) + "abcd".data(using: .utf16BigEndian)!)
    }

    func testUtf8BOMIsPreservedOnSave() throws {
        let original = Data(TextEncoding.utf8BOM) + Data("key = \"值\"\n".utf8)

        let decoded = try XCTUnwrap(TextFileDetector.decodeText(original))

        XCTAssertEqual(decoded.text, "key = \"值\"\n")
        XCTAssertEqual(decoded.encoding, .utf8(byteOrderMark: true))
        XCTAssertEqual(decoded.encoding.encode(decoded.text + "x"), Data(TextEncoding.utf8BOM) + Data("key = \"值\"\nx".utf8))
    }

    func testPlainUtf8DoesNotGainABOM() throws {
        let original = Data("plain\n".utf8)

        let decoded = try XCTUnwrap(TextFileDetector.decodeText(original))

        XCTAssertEqual(decoded.encoding, .utf8(byteOrderMark: false))
        XCTAssertEqual(decoded.encoding.encode(decoded.text), original)
    }

    func testEmptyFileIsEditableAsUtf8() throws {
        let decoded = try XCTUnwrap(TextFileDetector.decodeText(Data()))
        XCTAssertEqual(decoded.text, "")
        XCTAssertEqual(decoded.encoding, .utf8(byteOrderMark: false))
    }
}

final class LegacyChineseEncodingTests: XCTestCase {
    // "编辑中文配置文件：服务器 = 本地\n" encoded as GBK/GB18030.
    private let gbkBytes = Data(hex: "b1e0bcadd6d0cec4c5e4d6c3cec4bcfea3bab7fecef1c6f7203d20b1beb5d80a")

    func testGBKTextOpensAndSavesInGB18030() throws {
        let decoded = try XCTUnwrap(TextFileDetector.decodeText(gbkBytes))

        XCTAssertEqual(decoded.text, "编辑中文配置文件：服务器 = 本地\n")
        XCTAssertEqual(decoded.encoding, .gb18030)
        XCTAssertEqual(decoded.encoding.encode(decoded.text), gbkBytes)
    }

    func testUtf8ChineseStaysUtf8() throws {
        let data = Data("编辑中文\n".utf8)
        XCTAssertEqual(TextFileDetector.decodeText(data)?.encoding, .utf8(byteOrderMark: false))
    }

    func testBinaryWithHighBytesIsStillRejected() {
        var bytes: [UInt8] = []
        for index in 0..<512 { bytes.append(UInt8(truncatingIfNeeded: index * 37)) }
        XCTAssertNil(TextFileDetector.decodeText(Data(bytes)))
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
