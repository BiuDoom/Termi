import Testing
import CryptoKit
import Foundation
@testable import Termi

// MARK: - AES-256-GCM Encryption

@Test func encryptDecryptRoundtrip() async throws {
    let crypto = CryptoService.shared
    let key = SymmetricKey(size: .bits256)
    let plaintext = Data("Hello, Termi!".utf8)

    let encrypted = try crypto.encrypt(plaintext, using: key)
    let decrypted = try crypto.decrypt(encrypted, using: key)

    #expect(decrypted == plaintext)
    #expect(encrypted != plaintext) // Ciphertext should differ from plaintext
}

@Test func encryptDecryptStringRoundtrip() async throws {
    let crypto = CryptoService.shared
    let key = SymmetricKey(size: .bits256)
    let original = "SSH password: s3cr3t!@#"

    let encrypted = try crypto.encryptString(original, using: key)
    let decrypted = try crypto.decryptString(encrypted, using: key)

    #expect(decrypted == original)
    #expect(encrypted != original)
}

@Test func encryptDecryptEmptyData() async throws {
    let crypto = CryptoService.shared
    let key = SymmetricKey(size: .bits256)
    let empty = Data()

    let encrypted = try crypto.encrypt(empty, using: key)
    let decrypted = try crypto.decrypt(encrypted, using: key)

    #expect(decrypted == empty)
}

@Test func encryptDecryptEmptyString() async throws {
    let crypto = CryptoService.shared
    let key = SymmetricKey(size: .bits256)

    let encrypted = try crypto.encryptString("", using: key)
    let decrypted = try crypto.decryptString(encrypted, using: key)

    #expect(decrypted == "")
}

@Test func decryptWithWrongKeyFails() async throws {
    let crypto = CryptoService.shared
    let key1 = SymmetricKey(size: .bits256)
    let key2 = SymmetricKey(size: .bits256)
    let plaintext = Data("secret data".utf8)

    let encrypted = try crypto.encrypt(plaintext, using: key1)

    #expect(throws: (any Error).self) {
        _ = try crypto.decrypt(encrypted, using: key2)
    }
}

@Test func decryptInvalidBase64Fails() async throws {
    let crypto = CryptoService.shared
    let key = SymmetricKey(size: .bits256)

    #expect(throws: (any Error).self) {
        _ = try crypto.decryptString("not-valid-base64!!!", using: key)
    }
}

// MARK: - Salt Generation

@Test func generateSaltIs32Bytes() async {
    let crypto = CryptoService.shared
    let salt = crypto.generateSalt()
    #expect(salt.count == 32)
}

@Test func generateSaltIsUnique() async {
    let crypto = CryptoService.shared
    let salt1 = crypto.generateSalt()
    let salt2 = crypto.generateSalt()
    #expect(salt1 != salt2)
}

// MARK: - Key Derivation (HKDF)

@Test func deriveKeyDeterministic() async throws {
    let crypto = CryptoService.shared
    let salt = Data(repeating: 0xAB, count: 32)

    let key1 = try crypto.deriveKey(from: "password", salt: salt)
    let key2 = try crypto.deriveKey(from: "password", salt: salt)

    // Same inputs → same key
    let bytes1 = key1.withUnsafeBytes { Data($0) }
    let bytes2 = key2.withUnsafeBytes { Data($0) }
    #expect(bytes1 == bytes2)
}

@Test func deriveKeyDifferentSaltProducesDifferentKey() async throws {
    let crypto = CryptoService.shared
    let salt1 = Data(repeating: 0x01, count: 32)
    let salt2 = Data(repeating: 0x02, count: 32)

    let key1 = try crypto.deriveKey(from: "password", salt: salt1)
    let key2 = try crypto.deriveKey(from: "password", salt: salt2)

    let bytes1 = key1.withUnsafeBytes { Data($0) }
    let bytes2 = key2.withUnsafeBytes { Data($0) }
    #expect(bytes1 != bytes2)
}

// MARK: - Password Hashing (PBKDF2)

@Test func hashPasswordReturns64HexChars() async throws {
    let crypto = CryptoService.shared
    let salt = Data(repeating: 0xCC, count: 32)

    let hash = try crypto.hashPassword("mypassword", salt: salt)

    #expect(hash.count == 64)
    // All characters should be hex digits
    let hexCharSet = CharacterSet(charactersIn: "0123456789abcdef")
    #expect(hash.unicodeScalars.allSatisfy { hexCharSet.contains($0) })
}

@Test func verifyPasswordCorrect() async throws {
    let crypto = CryptoService.shared
    let salt = Data(repeating: 0xDD, count: 32)

    let hash = try crypto.hashPassword("correctpassword", salt: salt)
    let verified = try crypto.verifyPassword("correctpassword", salt: salt, hash: hash)

    #expect(verified == true)
}

@Test func verifyPasswordWrong() async throws {
    let crypto = CryptoService.shared
    let salt = Data(repeating: 0xEE, count: 32)

    let hash = try crypto.hashPassword("correctpassword", salt: salt)
    let verified = try crypto.verifyPassword("wrongpassword", salt: salt, hash: hash)

    #expect(verified == false)
}
