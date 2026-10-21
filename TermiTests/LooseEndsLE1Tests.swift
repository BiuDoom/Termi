import Testing
import CryptoKit
import Foundation
@testable import Termi

// Loose ends of the click acceptance — shell, terminal, SFTP: a stored secret that does not
// decrypt is said in words, a cancelled prompt is not a failure, the folded transfer bar is
// not higher than the unfolded one.

/// The error a real decryption with the wrong vault key ends in.
private func wrongKeyError() -> Error? {
    let crypto = CryptoService()
    let stored = try? crypto.encryptString("-----BEGIN OPENSSH PRIVATE KEY-----", using: SymmetricKey(size: .bits256))
    guard let stored else { return nil }
    do {
        _ = try crypto.decryptString(stored, using: SymmetricKey(size: .bits256))
        return nil
    } catch {
        return error
    }
}

@Test func le1SecretThatDoesNotDecryptBecomesTheTypedError() throws {
    let raw = try #require(wrongKeyError())
    let replacement = SSHService.SSHServiceError.privateKeyUnreadable(key: "deploy")
    let mapped = SSHService.unreadableSecret(raw, as: replacement) as? SSHService.SSHServiceError
    #expect(mapped == replacement)

    // Not base64 at all: the stored value is damaged.
    let damaged = SSHService.unreadableSecret(CryptoService.CryptoError.invalidData, as: replacement)
        as? SSHService.SSHServiceError
    #expect(damaged == replacement)
}

@Test func le1UnreadableSecretSaysWhatToDoNotTheRawError() throws {
    let raw = try #require(wrongKeyError())
    let key = SSHService.unreadableSecret(raw, as: SSHService.SSHServiceError.privateKeyUnreadable(key: "deploy"))
    let keyText = key.localizedDescription
    #expect(keyText.contains("deploy"))
    #expect(!keyText.contains("CryptoKit"))
    #expect(keyText != raw.localizedDescription)

    let password = SSHService.SSHServiceError.identityPasswordUnreadable(identity: "ops")
    let passwordText = password.localizedDescription
    #expect(passwordText.contains("ops"))
    #expect(!passwordText.contains("CryptoKit"))
}

@Test func le1OtherVaultErrorsStayWhatTheyAre() {
    let replacement = SSHService.SSHServiceError.privateKeyUnreadable(key: "deploy")
    // A locked vault has its own message.
    let locked = SSHService.unreadableSecret(SecureStoreService.SecureStoreError.vaultLocked, as: replacement)
    #expect(locked is SecureStoreService.SecureStoreError)
    // The vault key file cannot be read while the screen is locked: this one is retried.
    let noPermission = SSHService.unreadableSecret(CocoaError(.fileReadNoPermission), as: replacement)
    let code = (noPermission as? CocoaError)?.code
    #expect(code == .fileReadNoPermission)
}

@Test func le1CancelledPromptIsTheUsersCancelNotAFailure() {
    #expect(TerminalSession.isUserCancel(SSHError.cancelled))
    #expect(TerminalSession.isUserCancel(CancellationError()))
    #expect(!TerminalSession.isUserCancel(SSHError.disconnected))
    #expect(!TerminalSession.isUserCancel(SSHError.authenticationFailed(host: "a", detail: "")))
    #expect(!TerminalSession.isUserCancel(SSHService.SSHServiceError.privateKeyUnreadable(key: "k")))
}

@Test func le1FoldedTransferBarIsNotHigherThanOneFinishedRow() {
    let folded = TransferQueueView.foldedHeight
    let oneFinished = TransferQueueView.rowsHeight(running: 0, finished: 1)
    let oneRunning = TransferQueueView.rowsHeight(running: 1, finished: 0)
    #expect(folded <= oneFinished)
    #expect(folded <= oneRunning)
}
