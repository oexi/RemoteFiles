import Foundation

enum WindowsSecurityDescriptorParser {
    static func parse(_ data: Data) throws -> RemoteAccessControlInfo {
        guard data.count >= 20 else {
            throw RemoteProviderError.invalidResponse("The SMB server returned a truncated security descriptor.")
        }

        let control = try readUInt16(data, at: 2)
        let ownerOffset = Int(try readUInt32(data, at: 4))
        let groupOffset = Int(try readUInt32(data, at: 8))
        let daclOffset = Int(try readUInt32(data, at: 16))

        let owner = ownerOffset == 0 ? nil : displaySID(try parseSID(data, at: ownerOffset))
        let group = groupOffset == 0 ? nil : displaySID(try parseSID(data, at: groupOffset))
        let entries = daclOffset == 0 ? [] : try parseACL(data, at: daclOffset)

        return RemoteAccessControlInfo(
            owner: owner,
            group: group,
            daclProtected: control & 0x1000 != 0,
            entries: entries
        )
    }

    private static func parseACL(_ data: Data, at offset: Int) throws -> [RemoteAccessControlEntry] {
        guard offset >= 0, offset + 8 <= data.count else {
            throw RemoteProviderError.invalidResponse("The SMB DACL offset is outside the security descriptor.")
        }
        let aclSize = Int(try readUInt16(data, at: offset + 2))
        let aceCount = Int(try readUInt16(data, at: offset + 4))
        guard aclSize >= 8, offset + aclSize <= data.count else {
            throw RemoteProviderError.invalidResponse("The SMB server returned an invalid DACL size.")
        }

        var entries: [RemoteAccessControlEntry] = []
        var cursor = offset + 8
        for index in 0..<aceCount {
            guard cursor + 4 <= offset + aclSize else {
                throw RemoteProviderError.invalidResponse("The SMB server returned a truncated access-control entry.")
            }
            let type = data[cursor]
            let flags = data[cursor + 1]
            let aceSize = Int(try readUInt16(data, at: cursor + 2))
            guard aceSize >= 8, cursor + aceSize <= offset + aclSize else {
                throw RemoteProviderError.invalidResponse("The SMB server returned an invalid access-control entry size.")
            }

            let mask = try readUInt32(data, at: cursor + 4)
            let sidOffset = try sidOffset(forACEType: type, data: data, aceOffset: cursor, aceSize: aceSize)
            let principal: String
            if let sidOffset {
                principal = (try? parseSID(data, at: sidOffset)).map(displaySID) ?? "Unrecognized SID"
            } else {
                principal = "Special ACE"
            }

            entries.append(RemoteAccessControlEntry(
                id: index,
                kind: kind(forACEType: type),
                principal: principal,
                accessMask: mask,
                flags: flags,
                rights: rights(for: mask)
            ))
            cursor += aceSize
        }
        return entries
    }

    private static func sidOffset(forACEType type: UInt8, data: Data, aceOffset: Int, aceSize: Int) throws -> Int? {
        switch type {
        case 0x00, 0x01, 0x02, 0x03, 0x09, 0x0A, 0x0D, 0x11, 0x12, 0x13:
            return aceOffset + 8
        case 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0F:
            guard aceSize >= 12 else { return nil }
            let objectFlags = try readUInt32(data, at: aceOffset + 8)
            var result = aceOffset + 12
            if objectFlags & 0x00000001 != 0 { result += 16 }
            if objectFlags & 0x00000002 != 0 { result += 16 }
            return result < aceOffset + aceSize ? result : nil
        default:
            return nil
        }
    }

    private static func kind(forACEType type: UInt8) -> RemoteAccessControlEntryKind {
        switch type {
        case 0x00, 0x05, 0x09, 0x0B: return .allow
        case 0x01, 0x06, 0x0A, 0x0C: return .deny
        case 0x02, 0x07, 0x0D, 0x0F: return .audit
        default: return .unknown
        }
    }

    private static func parseSID(_ data: Data, at offset: Int) throws -> String {
        guard offset >= 0, offset + 8 <= data.count else {
            throw RemoteProviderError.invalidResponse("The SMB server returned a truncated SID.")
        }
        let revision = data[offset]
        let count = Int(data[offset + 1])
        let length = 8 + count * 4
        guard offset + length <= data.count else {
            throw RemoteProviderError.invalidResponse("The SMB server returned a truncated SID.")
        }

        var authority: UInt64 = 0
        for byte in data[(offset + 2)..<(offset + 8)] {
            authority = (authority << 8) | UInt64(byte)
        }
        var parts = ["S", String(revision), String(authority)]
        for index in 0..<count {
            parts.append(String(try readUInt32(data, at: offset + 8 + index * 4)))
        }
        return parts.joined(separator: "-")
    }

    private static func rights(for mask: UInt32) -> [String] {
        var result: [String] = []
        func add(_ bit: UInt32, _ name: String) { if mask & bit != 0 { result.append(name) } }

        add(0x10000000, "Full Control")
        add(0x80000000, "Generic Read")
        add(0x40000000, "Generic Write")
        add(0x20000000, "Generic Execute")
        add(0x00000001, "Read / List")
        add(0x00000002, "Write / Create File")
        add(0x00000004, "Append / Create Folder")
        add(0x00000008, "Read Extended Attributes")
        add(0x00000010, "Write Extended Attributes")
        add(0x00000020, "Execute / Traverse")
        add(0x00000040, "Delete Child")
        add(0x00000080, "Read Attributes")
        add(0x00000100, "Write Attributes")
        add(0x00010000, "Delete")
        add(0x00020000, "Read Permissions")
        add(0x00040000, "Change Permissions")
        add(0x00080000, "Take Ownership")
        add(0x00100000, "Synchronize")
        return result.isEmpty ? [String(format: "Mask 0x%08X", mask)] : result
    }

    private static func displaySID(_ sid: String) -> String {
        let names: [String: String] = [
            "S-1-1-0": "Everyone",
            "S-1-5-2": "Network",
            "S-1-5-11": "Authenticated Users",
            "S-1-5-18": "LOCAL SYSTEM",
            "S-1-5-19": "LOCAL SERVICE",
            "S-1-5-20": "NETWORK SERVICE",
            "S-1-5-32-544": "BUILTIN\\Administrators",
            "S-1-5-32-545": "BUILTIN\\Users",
            "S-1-5-32-546": "BUILTIN\\Guests",
            "S-1-5-32-547": "BUILTIN\\Power Users",
            "S-1-5-32-551": "BUILTIN\\Backup Operators"
        ]
        guard let name = names[sid] else { return sid }
        return "\(name) (\(sid))"
    }

    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw RemoteProviderError.invalidResponse("The SMB security descriptor is truncated.")
        }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw RemoteProviderError.invalidResponse("The SMB security descriptor is truncated.")
        }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
