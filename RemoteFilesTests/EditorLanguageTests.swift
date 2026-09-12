import XCTest
@testable import RemoteFiles

final class EditorLanguageTests: XCTestCase {
    func testShellDotfilesAreEditable() {
        XCTAssertTrue(EditorLanguage.isEditable(fileName: ".zshrc"))
        XCTAssertTrue(EditorLanguage.isEditable(fileName: ".bashrc"))
        XCTAssertTrue(EditorLanguage.isEditable(fileName: ".myconfig"))
        XCTAssertFalse(EditorLanguage.isEditable(fileName: ".DS_Store"))
        XCTAssertNotNil(EditorLanguage.language(fileName: ".zshrc"))
    }

    func testCommonExtensionlessTextFilesAreEditable() {
        XCTAssertTrue(EditorLanguage.isEditable(fileName: "Makefile"))
        XCTAssertTrue(EditorLanguage.isEditable(fileName: "Dockerfile"))
    }
}
