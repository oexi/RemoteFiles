import XCTest
@testable import RemoteFiles

final class PermissionParsingTests: XCTestCase {
    func testFTPUnixModeParsing() {
        XCTAssertEqual(FTPProvider.parseUnixMode("rw-r--r--"), 0o644)
        XCTAssertEqual(FTPProvider.parseUnixMode("rwxr-xr-x"), 0o755)
        XCTAssertEqual(FTPProvider.parseUnixMode("rwsr-xr-t"), 0o5755)
        XCTAssertNil(FTPProvider.parseUnixMode("invalid!!"))
    }

    func testFTPReplyCodeUsesTerminalReply() {
        XCTAssertEqual(FTPProvider.replyCode("211-Features:\n UTF8\n211 End"), 211)
        XCTAssertEqual(FTPProvider.replyCode("200 SITE CHMOD command successful"), 200)
    }

    func testParsesSMBSecurityDescriptor() throws {
        var descriptor = Data()
        descriptor.append(contentsOf: [1, 0])
        appendLE(UInt16(0x9004), to: &descriptor) // SELF_RELATIVE | DACL_PRESENT | DACL_PROTECTED
        appendLE(UInt32(20), to: &descriptor) // owner
        appendLE(UInt32(32), to: &descriptor) // group
        appendLE(UInt32(0), to: &descriptor)  // SACL
        appendLE(UInt32(48), to: &descriptor) // DACL

        descriptor.append(sid(authority: 1, subAuthorities: [0])) // Everyone
        descriptor.append(sid(authority: 5, subAuthorities: [32, 545])) // BUILTIN\Users

        descriptor.append(contentsOf: [2, 0]) // ACL revision + reserved
        appendLE(UInt16(28), to: &descriptor)
        appendLE(UInt16(1), to: &descriptor)
        appendLE(UInt16(0), to: &descriptor)
        descriptor.append(contentsOf: [0x00, 0x10]) // ACCESS_ALLOWED + INHERITED
        appendLE(UInt16(20), to: &descriptor)
        appendLE(UInt32(0x00020001), to: &descriptor)
        descriptor.append(sid(authority: 1, subAuthorities: [0]))

        let parsed = try WindowsSecurityDescriptorParser.parse(descriptor)
        XCTAssertEqual(parsed.owner, "Everyone (S-1-1-0)")
        XCTAssertEqual(parsed.group, "BUILTIN\\Users (S-1-5-32-545)")
        XCTAssertTrue(parsed.daclProtected)
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.entries[0].kind, .allow)
        XCTAssertTrue(parsed.entries[0].isInherited)
        XCTAssertTrue(parsed.entries[0].rights.contains("Read / List"))
        XCTAssertTrue(parsed.entries[0].rights.contains("Read Permissions"))
    }

    private func sid(authority: UInt64, subAuthorities: [UInt32]) -> Data {
        var data = Data([1, UInt8(subAuthorities.count)])
        for shift in stride(from: 40, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: authority >> UInt64(shift)))
        }
        for value in subAuthorities { appendLE(value, to: &data) }
        return data
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
