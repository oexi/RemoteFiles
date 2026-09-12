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
