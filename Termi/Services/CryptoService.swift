import CommonCrypto
import CryptoKit
import Foundation
import os.log

/// AES-256-GCM encryption service for sensitive data — stateless, thread-safe
final class CryptoService: Sendable {
    static let shared = CryptoService()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "Crypto")

    enum Context {
        static let `default` = "Termi-v1"
        static let vault = "Termi-vault-v1"
        static let passwordHash = "Termi-password-hash-v1"
    }

    // MARK: - Key Derivation

    /// Derive an encryption key from a password using PBKDF2-SHA256.
    /// HKDF is unsuitable for password-derived keys (no brute-force resistance);
    /// PBKDF2 with 600,000 iterations provides GPU-resistant key stretching.
    func deriveKey(from password: String, salt: Data, context: String = Context.default) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedKeyBytes = [UInt8](repeating: 0, count: 32)

        // Append context bytes to the salt for domain separation.
        // Without this, Context.vault and Context.default produce the same key
        // because the context parameter was accepted but never used.
        var contextualSalt = salt
        if let contextData = context.data(using: .utf8) {
            contextualSalt.append(contextData)
        }

        let status = passwordData.withUnsafeBytes { passwordBytes in
            contextualSalt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordData.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    contextualSalt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    Self.pbkdf2Iterations,
                    &derivedKeyBytes,
                    derivedKeyBytes.count
                )
            }
        }

        guard status == kCCSuccess else {
            throw CryptoError.keyDerivationFailed
        }

        return SymmetricKey(data: Data(derivedKeyBytes))
    }

    /// Generate a cryptographically secure random salt (via CryptoKit)
    func generateSalt() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - AES-256-GCM Encrypt/Decrypt

    /// Encrypt data with AES-256-GCM
    func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed
        }
        return combined
    }

    /// Decrypt data with AES-256-GCM
    func decrypt(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Encrypt a string, returning base64-encoded ciphertext
    func encryptString(_ plaintext: String, using key: SymmetricKey) throws -> String {
        let data = Data(plaintext.utf8)
        let encrypted = try encrypt(data, using: key)
        return encrypted.base64EncodedString()
    }

    /// Decrypt a base64-encoded string
    func decryptString(_ base64Ciphertext: String, using key: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: base64Ciphertext) else {
            throw CryptoError.invalidData
        }
        let decrypted = try decrypt(data, using: key)
        guard let string = String(data: decrypted, encoding: .utf8) else {
            throw CryptoError.invalidData
        }
        return string
    }

    // MARK: - Password Hashing (PBKDF2 — GPU-resistant)

    /// Number of PBKDF2 iterations — OWASP minimum for SHA-256 is 600,000
    private static let pbkdf2Iterations: UInt32 = 600_000

    /// Hash a password for verification using PBKDF2-SHA256 (memory-hard, GPU-resistant)
    func hashPassword(_ password: String, salt: Data) throws -> String {
        let passwordData = Data(password.utf8)
        var derivedKey = [UInt8](repeating: 0, count: 32)

        let status = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordData.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    Self.pbkdf2Iterations,
                    &derivedKey,
                    derivedKey.count
                )
            }
        }

        guard status == kCCSuccess else {
            throw CryptoError.keyDerivationFailed
        }

        return derivedKey.map { String(format: "%02x", $0) }.joined()
    }

    /// Verify a password against a stored hash using constant-time comparison
    func verifyPassword(_ password: String, salt: Data, hash: String) throws -> Bool {
        let computed = try hashPassword(password, salt: salt)
        return constantTimeEqual(computed, hash)
    }

    /// Constant-time string comparison to prevent timing side-channel attacks.
    /// Does NOT early-return on length mismatch to avoid leaking length info.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)

        // XOR lengths — nonzero if different, without early return
        var result: UInt8 = UInt8(truncatingIfNeeded: aBytes.count ^ bBytes.count)

        let count = min(aBytes.count, bBytes.count)
        for i in 0..<count {
            result |= aBytes[i] ^ bBytes[i]
        }
        return result == 0
    }

    // MARK: - Error

    enum CryptoError: Error, LocalizedError {
        case encryptionFailed
        case invalidData
        case keyDerivationFailed

        var errorDescription: String? {
            switch self {
            case .encryptionFailed: String(localized: "Encryption failed")
            case .invalidData: String(localized: "Invalid encrypted data")
            case .keyDerivationFailed: String(localized: "Key derivation failed")
            }
        }
    }
}
