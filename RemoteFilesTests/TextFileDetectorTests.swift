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
