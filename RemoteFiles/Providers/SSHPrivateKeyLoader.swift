import Citadel
import CommonCrypto
import Crypto
import Foundation

enum SSHPrivateKeyError: LocalizedError, Equatable {
    case passphraseRequired
    case wrongPassphrase
    case unsupportedCipher(String)
    case unsupportedKeyType(String)
    case encryptedPEM
    case malformed

    var errorDescription: String? {
        switch self {
        case .passphraseRequired:
            "This private key is protected by a passphrase. Enter the key passphrase."
        case .wrongPassphrase:
            "The key passphrase is incorrect."
        case .unsupportedCipher(let cipher):
            "Private keys encrypted with \(cipher) are not supported. Re-encrypt the key with ssh-keygen -p."
        case .unsupportedKeyType(let type):
            "The \(type) private-key type is not supported. Use Ed25519, ECDSA or RSA."
        case .encryptedPEM:
            "Encrypted PEM private keys are not supported. Convert the key to OpenSSH format with ssh-keygen -p -f <key>."
        case .malformed:
            "The private key file is not a valid OpenSSH or PEM private key."
        }
    }
}

/// Builds SSH authentication from an imported private key. Ed25519 and RSA
/// keys use Citadel's OpenSSH parser; ECDSA keys (nistp256/384/521), which
/// Citadel cannot parse, are read here from OpenSSH format (optionally
/// passphrase-protected with bcrypt + AES-CTR) or unencrypted PEM.
enum SSHPrivateKeyLoader {
    enum KeyKind: Equatable {
        case ed25519
        case rsa
        case ecdsaP256
        case ecdsaP384
        case ecdsaP521
    }

    static func detectKind(_ key: String) throws -> KeyKind {
        if isPEMEllipticCurveKey(key) {
            return try pemECDSAKind(key)
        }
        if key.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            let container = try OpenSSHKeyContainer(text: key)
            if let kind = kind(forKeyType: container.publicKeyType) { return kind }
            throw SSHPrivateKeyError.unsupportedKeyType(container.publicKeyType)
        }
        let citadelType = try SSHKeyDetection.detectPrivateKeyType(from: key)
        if citadelType == .ed25519 { return .ed25519 }
        if citadelType == .rsa { return .rsa }
        throw SSHPrivateKeyError.unsupportedKeyType(citadelType.description)
    }

    static func authenticationMethod(username: String, key: String, passphrase: Data?) throws -> SSHAuthenticationMethod {
        switch try detectKind(key) {
        case .ed25519:
            return .ed25519(username: username, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: key, decryptionKey: passphrase))
        case .rsa:
            return .rsa(username: username, privateKey: try Insecure.RSA.PrivateKey(sshRsa: key, decryptionKey: passphrase))
        case .ecdsaP256:
            if isPEMEllipticCurveKey(key) {
                return .p256(username: username, privateKey: try P256.Signing.PrivateKey(pemRepresentation: key))
            }
            let scalar = try openSSHECDSAScalar(key, passphrase: passphrase, curve: "nistp256", size: 32)
            return .p256(username: username, privateKey: try P256.Signing.PrivateKey(rawRepresentation: scalar))
        case .ecdsaP384:
            if isPEMEllipticCurveKey(key) {
                return .p384(username: username, privateKey: try P384.Signing.PrivateKey(pemRepresentation: key))
            }
            let scalar = try openSSHECDSAScalar(key, passphrase: passphrase, curve: "nistp384", size: 48)
            return .p384(username: username, privateKey: try P384.Signing.PrivateKey(rawRepresentation: scalar))
        case .ecdsaP521:
            if isPEMEllipticCurveKey(key) {
                return .p521(username: username, privateKey: try P521.Signing.PrivateKey(pemRepresentation: key))
            }
            let scalar = try openSSHECDSAScalar(key, passphrase: passphrase, curve: "nistp521", size: 66)
            return .p521(username: username, privateKey: try P521.Signing.PrivateKey(rawRepresentation: scalar))
        }
    }

    /// Returns the big-endian private scalar of an OpenSSH ECDSA key, left
    /// padded to the curve's scalar size.
    static func openSSHECDSAScalar(_ key: String, passphrase: Data?, curve: String, size: Int) throws -> Data {
        let container = try OpenSSHKeyContainer(text: key)
        var reader = SSHWireReader(try container.decryptedPrivateSection(passphrase: passphrase))
        let check1 = try reader.readUInt32()
        let check2 = try reader.readUInt32()
        guard check1 == check2 else {
            throw container.isEncrypted ? SSHPrivateKeyError.wrongPassphrase : SSHPrivateKeyError.malformed
        }
        let keyType = try reader.readString()
        guard String(decoding: keyType, as: UTF8.self) == "ecdsa-sha2-\(curve)",
              String(decoding: try reader.readString(), as: UTF8.self) == curve else {
            throw SSHPrivateKeyError.malformed
        }
        _ = try reader.readString() // public point
        var scalar = try reader.readString()
        while scalar.first == 0 { scalar.removeFirst() }
        guard scalar.count <= size else { throw SSHPrivateKeyError.malformed }
        return Data(repeating: 0, count: size - scalar.count) + scalar
    }

    private static func kind(forKeyType type: String) -> KeyKind? {
        switch type {
        case "ssh-ed25519": .ed25519
        case "ssh-rsa": .rsa
        case "ecdsa-sha2-nistp256": .ecdsaP256
        case "ecdsa-sha2-nistp384": .ecdsaP384
        case "ecdsa-sha2-nistp521": .ecdsaP521
        default: nil
        }
    }

    private static func isPEMEllipticCurveKey(_ key: String) -> Bool {
        key.contains("-----BEGIN EC PRIVATE KEY-----")
            || key.contains("-----BEGIN PRIVATE KEY-----")
            || key.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----")
    }

    private static func pemECDSAKind(_ key: String) throws -> KeyKind {
        if key.contains("ENCRYPTED") { throw SSHPrivateKeyError.encryptedPEM }
        if (try? P256.Signing.PrivateKey(pemRepresentation: key)) != nil { return .ecdsaP256 }
        if (try? P384.Signing.PrivateKey(pemRepresentation: key)) != nil { return .ecdsaP384 }
        if (try? P521.Signing.PrivateKey(pemRepresentation: key)) != nil { return .ecdsaP521 }
        throw SSHPrivateKeyError.malformed
    }
}

/// The "openssh-key-v1" private-key container.
struct OpenSSHKeyContainer {
    let cipherName: String
    let kdfName: String
    let kdfOptions: Data
    let publicKeyType: String
    let privateSection: Data

    var isEncrypted: Bool { cipherName != "none" }

    init(text: String) throws {
        let body = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()
        guard let blob = Data(base64Encoded: body) else { throw SSHPrivateKeyError.malformed }
        let magic = Data("openssh-key-v1".utf8) + Data([0])
        guard blob.starts(with: magic) else { throw SSHPrivateKeyError.malformed }
        var reader = SSHWireReader(blob.dropFirst(magic.count))
        cipherName = String(decoding: try reader.readString(), as: UTF8.self)
        kdfName = String(decoding: try reader.readString(), as: UTF8.self)
        kdfOptions = try reader.readString()
        guard try reader.readUInt32() == 1 else { throw SSHPrivateKeyError.malformed }
        var publicReader = SSHWireReader(try reader.readString())
        publicKeyType = String(decoding: try publicReader.readString(), as: UTF8.self)
        privateSection = try reader.readString()
    }

    func decryptedPrivateSection(passphrase: Data?) throws -> Data {
        guard isEncrypted else { return privateSection }
        let keyLength: Int
        switch cipherName {
        case "aes256-ctr": keyLength = 32
        case "aes128-ctr": keyLength = 16
        default: throw SSHPrivateKeyError.unsupportedCipher(cipherName)
        }
        guard kdfName == "bcrypt" else { throw SSHPrivateKeyError.unsupportedCipher(kdfName) }
        guard let passphrase, !passphrase.isEmpty else { throw SSHPrivateKeyError.passphraseRequired }

        var options = SSHWireReader(kdfOptions)
        let salt = try options.readString()
        let rounds = Int(try options.readUInt32())
        guard rounds > 0, rounds <= 1 << 20 else { throw SSHPrivateKeyError.malformed }
        let material = BCryptPBKDF.deriveKey(password: passphrase, salt: salt, keyLength: keyLength + 16, rounds: rounds)
        return try Self.aesCTR(
            privateSection,
            key: material.prefix(keyLength),
            iv: material.suffix(16)
        )
    }

    static func aesCTR(_ input: Data, key: Data, iv: Data) throws -> Data {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    keyBytes.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), let cryptor else { throw SSHPrivateKeyError.malformed }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: input.count)
        var moved = 0
        let updateStatus = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress,
                    inputBytes.count,
                    outputBytes.baseAddress,
                    outputBytes.count,
                    &moved
                )
            }
        }
        guard updateStatus == CCCryptorStatus(kCCSuccess), moved == input.count else { throw SSHPrivateKeyError.malformed }
        return output
    }
}

/// Reads SSH wire-format integers and length-prefixed strings.
struct SSHWireReader {
    private var bytes: [UInt8]
    private var offset = 0

    init<D: DataProtocol>(_ data: D) {
        bytes = Array(data)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw SSHPrivateKeyError.malformed }
        let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard length <= bytes.count - offset else { throw SSHPrivateKeyError.malformed }
        let value = Data(bytes[offset..<offset + length])
        offset += length
        return value
    }
}
