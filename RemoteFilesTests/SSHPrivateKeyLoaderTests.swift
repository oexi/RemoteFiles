import CryptoKit
import Foundation
import XCTest
@testable import RemoteFiles

final class SSHPrivateKeyLoaderTests: XCTestCase {
    private let passphrase = Data("correct horse".utf8)

    func testBCryptPBKDFMatchesReferenceVectors() {
        // Vectors produced with the Python `bcrypt` package (bcrypt.kdf).
        XCTAssertEqual(
            BCryptPBKDF.deriveKey(password: Data("password".utf8), salt: Data("salt".utf8), keyLength: 32, rounds: 4).hex,
            "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9"
        )
        XCTAssertEqual(
            BCryptPBKDF.deriveKey(password: Data("hunter2".utf8), salt: Data(0..<16), keyLength: 48, rounds: 16).hex,
            "76903cbe9474a3ba898308c55ddddd574d7d7d8aeecff6200b408d39b9e09bd82f79ea4d43f236fa8dd765260a93a96a"
        )
    }

    func testEncryptedOpenSSHP256Key() throws {
        let scalar = try SSHPrivateKeyLoader.openSSHECDSAScalar(Self.enc256, passphrase: passphrase, curve: "nistp256", size: 32)
        let key = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        XCTAssertEqual(key.publicKey.x963Representation.hex, Self.enc256Public)
        XCTAssertEqual(try SSHPrivateKeyLoader.detectKind(Self.enc256), .ecdsaP256)
        XCTAssertNoThrow(try SSHPrivateKeyLoader.authenticationMethod(username: "u", key: Self.enc256, passphrase: passphrase))
    }

    func testEncryptedOpenSSHP384Key() throws {
        let scalar = try SSHPrivateKeyLoader.openSSHECDSAScalar(Self.enc384, passphrase: passphrase, curve: "nistp384", size: 48)
        let key = try P384.Signing.PrivateKey(rawRepresentation: scalar)
        XCTAssertEqual(key.publicKey.x963Representation.hex, Self.enc384Public)
        XCTAssertEqual(try SSHPrivateKeyLoader.detectKind(Self.enc384), .ecdsaP384)
    }

    func testEncryptedOpenSSHP521Key() throws {
        let scalar = try SSHPrivateKeyLoader.openSSHECDSAScalar(Self.enc521, passphrase: passphrase, curve: "nistp521", size: 66)
        let key = try P521.Signing.PrivateKey(rawRepresentation: scalar)
        XCTAssertEqual(key.publicKey.x963Representation.hex, Self.enc521Public)
        XCTAssertEqual(try SSHPrivateKeyLoader.detectKind(Self.enc521), .ecdsaP521)
    }

    func testUnencryptedOpenSSHP256Key() throws {
        let scalar = try SSHPrivateKeyLoader.openSSHECDSAScalar(Self.plain256, passphrase: nil, curve: "nistp256", size: 32)
        let key = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        XCTAssertEqual(key.publicKey.x963Representation.hex, Self.plain256Public)
    }

    func testPEMP256Key() throws {
        XCTAssertEqual(try SSHPrivateKeyLoader.detectKind(Self.pem256), .ecdsaP256)
        let key = try P256.Signing.PrivateKey(pemRepresentation: Self.pem256)
        XCTAssertEqual(key.publicKey.x963Representation.hex, Self.pem256Public)
        XCTAssertNoThrow(try SSHPrivateKeyLoader.authenticationMethod(username: "u", key: Self.pem256, passphrase: nil))
    }

    func testWrongPassphraseIsReported() {
        XCTAssertThrowsError(
            try SSHPrivateKeyLoader.openSSHECDSAScalar(Self.enc256, passphrase: Data("wrong".utf8), curve: "nistp256", size: 32)
        ) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .wrongPassphrase)
        }
    }

    func testMissingPassphraseIsReported() {
        XCTAssertThrowsError(
            try SSHPrivateKeyLoader.openSSHECDSAScalar(Self.enc256, passphrase: nil, curve: "nistp256", size: 32)
        ) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .passphraseRequired)
        }
    }

    static let enc256 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABALbbTMBX
8pm4/QC0TpVEMeAAAAGAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
dHAyNTYAAABBBNFEe5zU6HP4TSOO/niK5KKC7kxdY2wbArORukvjB0+hqrM5SkpUby4uT8
Tn/GChzKuxlM+OpYNb7A424QGA5DAAAACgKvr9IiPVnpdh8iJTMMlBc90bT9k23YMHW4//
/8J5Ir6moVTqLEl0Xacc9YZTh2wWxnLza94gdktI2gKYQhAynM6lMcuk2KjawOW+U2cBYh
D8UqEDLWAhrxVXgC1NE75N5qnJ9W2mTf74TOoAzX2ANu+S7dbfOxl8eh5AMQ+kVPiKVfx+
uSACJfpXwuxDmVaJrrSlifwho+WUYvruqxpFvA==
-----END OPENSSH PRIVATE KEY-----
"""

    static let enc256Public = "04d1447b9cd4e873f84d238efe788ae4a282ee4c5d636c1b02b391ba4be3074fa1aab3394a4a546f2e2e4fc4e7fc60a1ccabb194cf8ea5835bec0e36e10180e430"

    static let enc384 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCQvbVOvE
9Y1tIxzC2CPtydAAAAGAAAAAEAAACIAAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlz
dHAzODQAAABhBFYt/Ul3TnzON1rOsG1xt112/LQB9bvrOowJYoyL6thFggzes/tKJzQLh6
6yMVzbpJu8F4byokeHV0Lu39AoufGPEbHHSsarvMIqWIzDpkpERajWG0JWHrazr0yXWoH0
AQAAANAjGk6L6fcEDl2wgDDnwrI6S8fZULgU2aOFthXqxkAptDoOlNxBLto1rl0BaHFQFo
n4Rk0x+i2Y0Waxzp58qJ0QwIub1Tnm88GXf+ZWXNDW4Jjs+Uaz+xzY6SbklH0yNOx+vkGr
0A1yXDRRmPnDxaGlHbdhJdMR6nJpV4R2dqGImIb5msaenH+lHc/X3izpM8aS3OZUJ0tdVO
yD4ELOyl4aC02XweHmFDIXDAlq4b8551ECA7fKGbIc3rkaPBr/Nfjm0d2zpVohGhpZUpaI
kB9I
-----END OPENSSH PRIVATE KEY-----
"""

    static let enc384Public = "04562dfd49774e7cce375aceb06d71b75d76fcb401f5bbeb3a8c09628c8bead845820cdeb3fb4a27340b87aeb2315cdba49bbc1786f2a247875742eedfd028b9f18f11b1c74ac6abbcc22a588cc3a64a4445a8d61b42561eb6b3af4c975a81f401"

    static let enc521 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBkExju8t
kf0ImMTSPMeROPAAAAGAAAAAEAAACsAAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlz
dHA1MjEAAACFBAE/MoHGfvJmmv6VEeYn9dq1n5eUTulAYqPOrUPemEAzJl9/AtgQV9N0Sk
aM9+J2uX5XL0le9jUrAKLaTuBWLLFrugGfNb7968XAjXSYWayOwWulEUvt4ibRVYBhcsHe
mmdXLueOzcF3DKu5qBp1vgjQdqHtrDQP7f8SWgdzE4Mr2EO3aQAAARDKKtd3yGy8H2KHsU
JHegzMwdKxaqEg+Gi6uNnLUulbmcJWsqCttIdO0tmucbKthJe9pWN056y6O/NbJLSSsNtk
b+Xz6ALOqRJDyOTnc0ZEBHCOSDgzmPUAMkmmujuOTG9E3E/B9dHboEsOAwQzJpvuomuqYI
h98FNJnumEqUofjg+vYXo5wdrYnb8X8Xcvf2+/B+ff7hPg3plhBQWzSyNp5PKJ7AR11OMz
edMstF6bZhYzFWbjMufBx0XOGGbZrJsMTiahfAjv2v0sWHvFAKmCd15jg0yCf6LQvRhpx6
XruU9pnX5gzq3QhbR7uUVcCn2Kxvto/6SE4h7jtHeif40WDyJEo1qMtH6H/YaWBhpchQ==
-----END OPENSSH PRIVATE KEY-----
"""

    static let enc521Public = "04013f3281c67ef2669afe9511e627f5dab59f97944ee94062a3cead43de984033265f7f02d81057d3744a468cf7e276b97e572f495ef6352b00a2da4ee0562cb16bba019f35befdebc5c08d749859ac8ec16ba5114bede226d155806172c1de9a67572ee78ecdc1770cabb9a81a75be08d076a1edac340fedff125a077313832bd843b769"

    static let plain256 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQSdfG8O+G1kWhU2v3eUNyWuneaFbd2e
7pBlrslUaP8p1i4Te8ohbSlUGSYW1MRhfAjgvCF4cCIPjEFCpEBaRSSHAAAAoNmXRuPZl0
bjAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJ18bw74bWRaFTa/
d5Q3Ja6d5oVt3Z7ukGWuyVRo/ynWLhN7yiFtKVQZJhbUxGF8COC8IXhwIg+MQUKkQFpFJI
cAAAAgdHpGcwu4wVDY1foPlgZeF5rqdxtpRgBw/BorHhVF2QUAAAAIcGxhaW4yNTY=
-----END OPENSSH PRIVATE KEY-----
"""

    static let plain256Public = "049d7c6f0ef86d645a1536bf77943725ae9de6856ddd9eee9065aec95468ff29d62e137bca216d2954192616d4c4617c08e0bc217870220f8c4142a4405a452487"

    static let pem256 = """
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIDcUZb/yild25NffebG8qf7wdmthHZsLzLWe1lyGtX2foAoGCCqGSM49
AwEHoUQDQgAEMTB6r3VcSn37WNvODRbSLRA7F265Dzv+UC++ELpu1pVd7dH6Z0wM
y5P5HXdFMaNjLNVJspFeuhUkiCw3p+tTbg==
-----END EC PRIVATE KEY-----
"""

    static let pem256Public = "0431307aaf755c4a7dfb58dbce0d16d22d103b176eb90f3bfe502fbe10ba6ed6955dedd1fa674c0ccb93f91d774531a3632cd549b2915eba1524882c37a7eb536e"

}

private extension DataProtocol {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
