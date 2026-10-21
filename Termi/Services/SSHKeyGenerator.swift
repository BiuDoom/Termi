import Foundation
import os.log
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// SSH Key generation using ssh-keygen
actor SSHKeyGenerator {
    static let shared = SSHKeyGenerator()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "SSHKeyGen")
    private let keygenPath: String
    /// Executable that ssh-keygen runs as SSH_ASKPASS (the app binary itself, see main.swift).
    private let askpassExecutable: String

    /// The executables are parameters so that tests can observe how ssh-keygen is started.
    init(
        keygenPath: String = "/usr/bin/ssh-keygen",
        askpassExecutable: String = Bundle.main.executablePath ?? CommandLine.arguments[0]
    ) {
        self.keygenPath = keygenPath
        self.askpassExecutable = askpassExecutable
    }

    enum KeyType: String, CaseIterable, Sendable {
        case ed25519
        case rsa

        var displayName: String {
            switch self {
            case .ed25519: "Ed25519 (Recommended)"
            case .rsa: "RSA (4096-bit)"
            }
        }

        var sshKeygenType: String {
            switch self {
            case .ed25519: "ed25519"
            case .rsa: "rsa"
            }
        }
    }

    struct GeneratedKey: Sendable {
        let publicKey: String
        let privateKey: String
        let fingerprint: String
        let type: String
    }

    /// Generate a new SSH key pair using ssh-keygen
    func generateKey(type: KeyType, comment: String = "", passphrase: String = "") async throws -> GeneratedKey {
        guard Self.askpassCanCarry(passphrase) else {
            throw KeyGenError.generationFailed(Self.unsupportedPassphraseMessage)
        }
        let tempDir = try Self.makeWorkDirectory()

        let keyPath = tempDir.appendingPathComponent("id_key").path
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Build ssh-keygen command. A passphrase is not an argument (see `runKeygen`): without
        // -N ssh-keygen asks for it.
        var args = [
            "-t", type.sshKeygenType,
            "-f", keyPath,
            "-C", comment,
        ]
        if passphrase.isEmpty {
            args += ["-N", ""]
        }

        if type == .rsa {
            args += ["-b", "4096"]
        }

        let (status, output) = try await runKeygen(args, answering: passphrase, in: tempDir)

        guard status == 0 else {
            logger.error("ssh-keygen failed: \(output)")
            throw KeyGenError.generationFailed(output)
        }

        if !passphrase.isEmpty {
            // ssh-keygen takes an askpass helper that fails for an empty answer and writes the
            // key unprotected, with exit status 0: the new key must not open without a passphrase.
            let (unprotected, _) = try await runProcess(keygenPath, arguments: ["-y", "-P", "", "-f", keyPath])
            guard unprotected != 0 else {
                logger.error("ssh-keygen wrote the key without the passphrase")
                throw KeyGenError.passphraseNotSet
            }
        }

        // Read generated files
        let publicKey = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKey = try String(contentsOfFile: keyPath, encoding: .utf8)

        // Get fingerprint
        let fingerprint = try await getFingerprint(keyPath: keyPath + ".pub")

        logger.info("Generated \(type.rawValue) key: \(fingerprint)")

        return GeneratedKey(
            publicKey: publicKey,
            privateKey: privateKey,
            fingerprint: fingerprint,
            type: type.rawValue
        )
    }

    /// Import an existing private key file
    func importKey(from path: String) async throws -> GeneratedKey {
        let privateKey = try String(contentsOfFile: path, encoding: .utf8)
        guard Self.isPrivateKeyText(privateKey) else {
            throw KeyGenError.importFailed(String(localized: "This is not a private key"))
        }

        // Extract public key from private key. The work directory is 0700 and the key file is
        // created 0600 — an atomic write into a default-mode directory left the PEM at 0644
        // until chmod, in a temp folder other accounts can read.
        let tempDir = try Self.makeWorkDirectory()
        let tempKeyPath = tempDir.appendingPathComponent("key").path
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try SSHRuntime.writePrivateFile(privateKey, to: URL(fileURLWithPath: tempKeyPath))

        let (status, output) = try await runProcess(keygenPath, arguments: ["-y", "-f", tempKeyPath])

        let publicKey: String
        if status == 0 {
            publicKey = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Passphrase-protected key: ssh-keygen cannot derive the public key without the
            // passphrase, so use the .pub file next to it (as ssh itself does).
            publicKey = ((try? String(contentsOfFile: path + ".pub", encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Get fingerprint
        let fingerprint: String
        if !publicKey.isEmpty {
            let pubPath = tempKeyPath + ".pub"
            try publicKey.write(toFile: pubPath, atomically: true, encoding: .utf8)
            fingerprint = (try? await getFingerprint(keyPath: pubPath)) ?? ""
        } else {
            fingerprint = ""
        }

        return GeneratedKey(
            publicKey: publicKey,
            privateKey: privateKey,
            fingerprint: fingerprint,
            type: Self.keyType(publicKey: publicKey, privateKey: privateKey)
        )
    }

    /// Import a key from pasted text (private key required, public key optional)
    func importKeyFromText(privateKeyText: String, publicKeyText: String = "", passphrase: String = "") async throws -> GeneratedKey {
        let trimmedPrivate = privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrivate.isEmpty else {
            throw KeyGenError.importFailed(String(localized: "Private key text is empty"))
        }
        guard Self.isPrivateKeyText(trimmedPrivate) else {
            throw KeyGenError.importFailed(String(localized: "This is not a private key"))
        }
        guard Self.askpassCanCarry(passphrase) else {
            throw KeyGenError.importFailed(Self.unsupportedPassphraseMessage)
        }

        // Write private key to temp file for ssh-keygen operations
        let tempDir = try Self.makeWorkDirectory()
        let tempKeyPath = tempDir.appendingPathComponent("key").path
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // ssh-keygen rejects an OpenSSH-format key whose END line has no trailing newline.
        try SSHRuntime.writePrivateFile(trimmedPrivate + "\n", to: URL(fileURLWithPath: tempKeyPath))

        // Use provided public key or derive from private key
        let publicKey: String
        let trimmedPublic = publicKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPublic.isEmpty {
            publicKey = trimmedPublic
        } else {
            // Derive public key with ssh-keygen -y, which asks for the passphrase of a
            // protected key (see `runKeygen`)
            let (status, output) = try await runKeygen(["-y", "-f", tempKeyPath], answering: passphrase, in: tempDir)
            if status == 0 {
                publicKey = output.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                publicKey = ""
                logger.warning("Could not derive public key: \(output)")
            }
        }

        // Get fingerprint
        let fingerprint: String
        if !publicKey.isEmpty {
            let pubPath = tempKeyPath + ".pub"
            try publicKey.write(toFile: pubPath, atomically: true, encoding: .utf8)
            fingerprint = (try? await getFingerprint(keyPath: pubPath)) ?? ""
        } else {
            fingerprint = ""
        }

        return GeneratedKey(
            publicKey: publicKey,
            privateKey: trimmedPrivate,
            fingerprint: fingerprint,
            type: Self.keyType(publicKey: publicKey, privateKey: trimmedPrivate)
        )
    }

    /// Whether the text carries a private key: a "-----BEGIN … PRIVATE KEY-----" line (OpenSSH
    /// and PEM keys alike). The public key of a protected key cannot be derived without its
    /// passphrase, so a failed `ssh-keygen -y` does not tell a key from any other text — without
    /// this check a public key file or a note was stored as a key that can never sign in.
    static func isPrivateKeyText(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("-----BEGIN ") && trimmed.hasSuffix("PRIVATE KEY-----")
        }
    }

    /// Key type shown in the UI ("ed25519", "rsa", "ecdsa", "dsa" or "unknown").
    ///
    /// The public key line names the algorithm. The private key header only does for legacy PEM
    /// keys ("BEGIN RSA PRIVATE KEY"): every OpenSSH-format key starts with "BEGIN OPENSSH PRIVATE KEY".
    static func keyType(publicKey: String, privateKey: String) -> String {
        let algorithm = publicKey.split(separator: " ").first.map(String.init) ?? ""
        switch algorithm {
        case "ssh-ed25519", "sk-ssh-ed25519@openssh.com":
            return "ed25519"
        case "ssh-rsa":
            return "rsa"
        case "ssh-dss":
            return "dsa"
        default:
            if algorithm.hasPrefix("ecdsa-sha2-") || algorithm.hasPrefix("sk-ecdsa-sha2-") {
                return "ecdsa"
            }
        }
        if privateKey.contains("BEGIN RSA PRIVATE KEY") { return "rsa" }
        if privateKey.contains("BEGIN EC PRIVATE KEY") { return "ecdsa" }
        if privateKey.contains("BEGIN DSA PRIVATE KEY") { return "dsa" }
        return "unknown"
    }

    private func getFingerprint(keyPath: String) async throws -> String {
        let (_, output) = try await runProcess(keygenPath, arguments: ["-lf", keyPath])

        // ssh-keygen -lf output: "256 SHA256:xxxx comment (ED25519)"
        let parts = output.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[1])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Passphrase

    /// Run ssh-keygen with `passphrase`, when there is one, as the answer to its passphrase
    /// prompts.
    ///
    /// The passphrase is never an argument (-N / -P) or an environment variable: every local
    /// user can read those with ps while ssh-keygen runs. ssh-keygen asks through SSH_ASKPASS
    /// instead — the app's own executable, as for ssh — and an askpass server started for
    /// this one process answers over a private Unix socket in `directory`.
    private func runKeygen(
        _ arguments: [String],
        answering passphrase: String,
        in directory: URL
    ) async throws -> (status: Int32, output: String) {
        guard !passphrase.isEmpty else {
            return try await runProcess(keygenPath, arguments: arguments)
        }

        let server = AskpassServer(socketPath: directory.appendingPathComponent("a").path)
        try server.start()
        defer { server.stop() }
        let token = UUID().uuidString
        server.register(token: token) { request in
            // The passphrase is the only thing ssh-keygen asks for here; a question about
            // anything else is not answered with it.
            request.prompt.range(of: "passphrase", options: .caseInsensitive) != nil ? .answer(passphrase) : .cancel
        }

        // Like `SSHRuntime.environment`: nothing of the app's own environment but the basics.
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": parent["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": parent["HOME"] ?? NSHomeDirectory(),
            "USER": parent["USER"] ?? NSUserName(),
            "LANG": parent["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8",
            "SSH_ASKPASS": askpassExecutable,
            "SSH_ASKPASS_REQUIRE": "force",
            AskpassClient.modeVariable: "1",
            AskpassClient.socketVariable: server.socketPath,
            AskpassClient.tokenVariable: token
        ]
        if let tmp = parent["TMPDIR"] { environment["TMPDIR"] = tmp }
        return try await runProcess(keygenPath, arguments: arguments, environment: environment)
    }

    /// ssh reads the answer of an askpass helper as one line of at most 1023 bytes: a
    /// passphrase beyond that would be cut short without a word, and the key protected by
    /// something else than what the user entered.
    private static func askpassCanCarry(_ passphrase: String) -> Bool {
        passphrase.utf8.count < 1024 && !passphrase.utf8.contains { $0 == 0x0A || $0 == 0x0D || $0 == 0 }
    }

    private static var unsupportedPassphraseMessage: String {
        String(localized: "The passphrase cannot contain line breaks or be longer than 1023 bytes.")
    }

    /// A private directory for the key files and the askpass socket, removed by the caller.
    /// The name is short because the path of a Unix socket is limited to about 100 bytes.
    /// Creating with `withIntermediateDirectories: false` still fails if the name is taken.
    /// `createDirectory`'s mode is masked by umask; the chmod afterwards is what makes it 0700.
    private static func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termi-key-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, 0o700) == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw SSHError.invalidConfiguration("Cannot secure \(url.lastPathComponent)")
        }
        return url
    }

    // MARK: - Async Process Runner

    /// Run a process via ProcessRunner (deadlock-safe pipe drain).
    /// On success returns stdout; on failure returns stderr (or stdout if stderr is empty).
    private func runProcess(
        _ executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> (status: Int32, output: String) {
        let result = try await ProcessRunner.run(executablePath, arguments: arguments, environment: environment)
        let output = result.exitCode == 0
            ? result.stdout
            : (result.stderr.isEmpty ? result.stdout : result.stderr)
        return (result.exitCode, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    enum KeyGenError: Error, LocalizedError {
        case generationFailed(String)
        case importFailed(String)
        case passphraseNotSet

        var errorDescription: String? {
            switch self {
            case .generationFailed(let msg): String(localized: "Key generation failed: \(msg)")
            case .importFailed(let msg): String(localized: "Key import failed: \(msg)")
            case .passphraseNotSet: String(localized: "Key generation failed: the passphrase could not be set on the new key.")
            }
        }
    }
}
