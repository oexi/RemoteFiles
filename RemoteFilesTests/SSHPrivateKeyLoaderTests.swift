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
            BCryptPBKDF.deriveKey(password: Data("hunter2".utf8), salt: Data(0..<16), keyLength: 48, rounds: 2).hex,
            "2ea50c73be689534a7ccaca3403a8666e66031b69c70be0874b301eb7625526448114a1ecbbb61d250d02de641285a63"
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

    // Encrypted fixtures come from `ssh-keygen -t ecdsa -a 1`: one bcrypt round keeps
    // the Debug-build tests fast, and the multi-round path is covered by the vectors above.
    static let enc256 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABA5n1dVnk
emJeda5cqj2dXrAAAAAQAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
dHAyNTYAAABBBMxvW0eAWD+damMO9zt8YIp715X/qiK99HHQ2DfvmFcm6/CYE2T2rVO/h8
y9bLOr0DkxRxR2C/ZqbFUTeGi0NtQAAACgjLiGSo3hLAdji6dI2dDLSXEy/mp3fNL+MwZq
+YCJKB3rOxh/O6F3YE4UXdqB91APCNiWw1eOFb9AIgrAyqZMTftV01plDS08nwk4e+yMLa
fvqg1hzthBOBVAaJhTW6BuAmuyzitxlM7NjmCzuDS9JBaPsRYE2HtVjKYVsTnx9o0Pa4qW
Iwbgn8hlfwbKtlIdZ5d0Q+x6idWH1cN7FRvRqQ==
-----END OPENSSH PRIVATE KEY-----
"""

    static let enc256Public = "04cc6f5b4780583f9d6a630ef73b7c608a7bd795ffaa22bdf471d0d837ef985726ebf0981364f6ad53bf87ccbd6cb3abd039314714760bf66a6c55137868b436d4"

    static let enc384 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCCRcQvyu
bvSmTcXMb0OUPwAAAAAQAAAAEAAACIAAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlz
dHAzODQAAABhBMnzyaPOTMixW9wJhHuSckFeKv5SKJ1ynKUsjfmCVR4uQWxJc/qoLoSLXR
6jm+1VPg1jB6bjd5N1d/0UbNYTLy7baBV9CaPVJuMHt4fLJKREAk+XJLWo0dldcsMPV2nR
4AAAANBP4McuYnCXXOFPdZzgf/+v8u5CdEn6+JYaj/rLeksNPeCyshjZmMmqZU1OltShQo
t3QEAOyY/qFlcI1bTLG4Bc19hml9dgyxWgccAaPulcEIV4IiFX3pSz/0ekDBrJONZSrQXS
tiH9CyKOkL8RJXkiGbrwBf7hj0NZFRDY8/BLiPRjBZZLUdOYUWeXQEpM+8htedMlDTi5cQ
o492KNb6RENmlzRRxEqzxxuS7nX+1lGy8TpQB5iHiaBIF7zdH0Oo6wSjuiUUOzSxSotyPx
CgIY
-----END OPENSSH PRIVATE KEY-----
"""

    static let enc384Public = "04c9f3c9a3ce4cc8b15bdc09847b9272415e2afe52289d729ca52c8df982551e2e416c4973faa82e848b5d1ea39bed553e0d6307a6e377937577fd146cd6132f2edb68157d09a3d526e307b787cb24a444024f9724b5a8d1d95d72c30f5769d1e0"

    static let enc521 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABA9agZ6Ce
vgApJYiyEAgTk4AAAAAQAAAAEAAACsAAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlz
dHA1MjEAAACFBAESsLLBxf91O9spoQgLVVCmyZE7wLyzSSNDXuvMYYeFH6m9oe+njHx0jA
xya4reOswVhQJnGbmnM08skUQy8sG3UQFgqdC8SsQ9jePbF7zvGNzUk4DfnFXdEy28aQly
lGvbrDuIVZbvwTa6k78yWTxATysk7nxXkUsp3xS8XE2DimNt1QAAAQAUgmJpFE3WHwoRRI
n/eUfAMeCtlYPM60hlf7EfIbFNfDBNWcY7aFDeEYzgCrT4vNWeQ1nKmZPmGLj/+ajCPUrM
yGoht5wY6fclCaXZlAm8NtfiHBaeorFB6XOadRaW5mwgPalNfLr4BO9JXTjA0U8nVUGnD5
rC7N5pyJAAVI3LdB4pHxQWzZhRQI9pgeIAy48ILn+P4epxWmJZkmSTuIEz4l/NhlIfIS44
4iRf78tg4uFqwc5HXfiHejI0SM26vRv6e0myZlAhWj2I6asIMo1Bab3DMCQ2GZ55zrXesX
Y6ymXst39wsnDz9vArCbW1FEHvzjS76txM1uM8wiEJM2Dv
-----END OPENSSH PRIVATE KEY-----
"""

    static let enc521Public = "040112b0b2c1c5ff753bdb29a1080b5550a6c9913bc0bcb34923435eebcc6187851fa9bda1efa78c7c748c0c726b8ade3acc1585026719b9a7334f2c914432f2c1b7510160a9d0bc4ac43d8de3db17bcef18dcd49380df9c55dd132dbc690972946bdbac3b885596efc136ba93bf32593c404f2b24ee7c57914b29df14bc5c4d838a636dd5"

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
