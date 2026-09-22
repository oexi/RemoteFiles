import CryptoKit
import Foundation

/// OpenBSD `bcrypt_pbkdf`, the key-derivation function OpenSSH uses for
/// passphrase-protected private keys ("openssh-key-v1" with kdf "bcrypt").
///
/// Citadel implements this internally but does not expose it, and only for
/// Ed25519/RSA keys; RemoteFiles needs it to decrypt ECDSA keys.
enum BCryptPBKDF {
    private static let hashSize = 32

    static func deriveKey(password: Data, salt: Data, keyLength: Int, rounds: Int) -> Data {
        precondition(keyLength > 0 && rounds > 0)
        let sha2pass = Array(SHA512.hash(data: password))
        let stride = (keyLength + hashSize - 1) / hashSize
        var amount = (keyLength + stride - 1) / stride
        var key = [UInt8](repeating: 0, count: keyLength)
        var remaining = keyLength
        var count: UInt32 = 1

        while remaining > 0 {
            var countSalt = salt
            withUnsafeBytes(of: count.bigEndian) { countSalt.append(contentsOf: $0) }
            var sha2salt = Array(SHA512.hash(data: countSalt))
            var temporary = bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
            var output = temporary
            if rounds > 1 {
                for _ in 1..<rounds {
                    sha2salt = Array(SHA512.hash(data: temporary))
                    temporary = bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
                    for index in output.indices { output[index] ^= temporary[index] }
                }
            }

            amount = min(amount, remaining)
            var written = 0
            for index in 0..<amount {
                let destination = index * stride + Int(count - 1)
                if destination >= keyLength { break }
                key[destination] = output[index]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return Data(key)
    }

    static func bcryptHash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        var state = Blowfish()
        state.expandState(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            state.expandZeroState(key: sha2salt)
            state.expandZeroState(key: sha2pass)
        }

        let ciphertext = Array("OxychromaticBlowfishSwatDynamite".utf8)
        var words = [UInt32](repeating: 0, count: 8)
        var position = 0
        for index in 0..<8 {
            words[index] = Blowfish.streamToWord(ciphertext, &position)
        }
        for _ in 0..<64 {
            for block in Swift.stride(from: 0, to: 8, by: 2) {
                (words[block], words[block + 1]) = state.encipher(words[block], words[block + 1])
            }
        }

        // bcrypt_pbkdf deliberately emits each word little-endian.
        var output = [UInt8](repeating: 0, count: hashSize)
        for index in 0..<8 {
            output[4 * index + 3] = UInt8(truncatingIfNeeded: words[index] >> 24)
            output[4 * index + 2] = UInt8(truncatingIfNeeded: words[index] >> 16)
            output[4 * index + 1] = UInt8(truncatingIfNeeded: words[index] >> 8)
            output[4 * index + 0] = UInt8(truncatingIfNeeded: words[index])
        }
        return output
    }

    struct Blowfish {
        var p: [UInt32] = BCryptPBKDF.initialP
        var s: [UInt32] = BCryptPBKDF.initialS.flatMap { $0 }

        static func streamToWord(_ data: [UInt8], _ position: inout Int) -> UInt32 {
            var word: UInt32 = 0
            for _ in 0..<4 {
                if position >= data.count { position = 0 }
                word = (word << 8) | UInt32(data[position])
                position += 1
            }
            return word
        }

        @inline(__always)
        private func f(_ x: UInt32) -> UInt32 {
            let a = s[Int(x >> 24)]
            let b = s[256 + Int((x >> 16) & 0xff)]
            let c = s[512 + Int((x >> 8) & 0xff)]
            let d = s[768 + Int(x & 0xff)]
            return ((a &+ b) ^ c) &+ d
        }

        func encipher(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
            var xl = left ^ p[0]
            var xr = right
            for round in Swift.stride(from: 1, to: 17, by: 2) {
                xr ^= f(xl) ^ p[round]
                xl ^= f(xr) ^ p[round + 1]
            }
            return (xr ^ p[17], xl)
        }

        mutating func expandState(data: [UInt8], key: [UInt8]) {
            var position = 0
            for index in 0..<18 {
                p[index] ^= Self.streamToWord(key, &position)
            }
            position = 0
            var left: UInt32 = 0
            var right: UInt32 = 0
            for index in Swift.stride(from: 0, to: 18, by: 2) {
                left ^= Self.streamToWord(data, &position)
                right ^= Self.streamToWord(data, &position)
                (left, right) = encipher(left, right)
                p[index] = left
                p[index + 1] = right
            }
            for index in Swift.stride(from: 0, to: 1024, by: 2) {
                left ^= Self.streamToWord(data, &position)
                right ^= Self.streamToWord(data, &position)
                (left, right) = encipher(left, right)
                s[index] = left
                s[index + 1] = right
            }
        }

        mutating func expandZeroState(key: [UInt8]) {
            var position = 0
            for index in 0..<18 {
                p[index] ^= Self.streamToWord(key, &position)
            }
            var left: UInt32 = 0
            var right: UInt32 = 0
            for index in Swift.stride(from: 0, to: 18, by: 2) {
                (left, right) = encipher(left, right)
                p[index] = left
                p[index + 1] = right
            }
            for index in Swift.stride(from: 0, to: 1024, by: 2) {
                (left, right) = encipher(left, right)
                s[index] = left
                s[index + 1] = right
            }
        }
    }
}
