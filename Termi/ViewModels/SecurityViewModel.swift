import SwiftUI
import os.log

/// ViewModel for master password and security features
@Observable
@MainActor
final class SecurityViewModel {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "SecurityVM")
    private let secureStore = SecureStoreService.shared

    var isLocked = false
    var hasMasterPassword = false
    var isVerifying = false
    var error: String?

    // Setup state
    var isSettingUp = false

    /// False until the first check has answered (even with an error). Until then it is not
    /// known whether the app is locked: windows keep their content covered and disabled.
    private(set) var isLockStateKnown = false

    /// True while a window must neither show its content nor act on it.
    var hidesContent: Bool { isLocked || !isLockStateKnown }

    /// Whether a master password existed the last time the app looked. Not a secret, only a hint
    /// for a window's first frames: expecting the lock screen, the launch cover starts without
    /// the toolbar the lock screen is about to hide.
    private static let lockHintKey = "launchLockHint"
    @ObservationIgnored let expectsLockScreen = AppProfile.defaults.bool(forKey: SecurityViewModel.lockHintKey)

    /// Every window runs the check when it opens; only the first one may lock, or ⌘N would
    /// put the lock screen back over windows that are already unlocked.
    @ObservationIgnored private var didInitialCheck = false

    /// Check if master password exists on launch
    func checkMasterPassword() async {
        do {
            hasMasterPassword = try await secureStore.hasMasterPassword()
            AppProfile.defaults.set(hasMasterPassword, forKey: Self.lockHintKey)
            if hasMasterPassword && !didInitialCheck {
                isLocked = true
            }
            didInitialCheck = true
            error = nil
        } catch {
            logger.error("Failed to check master password: \(error)")
        }
        // Together with `isLocked` (no suspension in between): the cover is lifted in the same
        // update that puts the lock screen up.
        isLockStateKnown = true
    }

    /// Set up a new master password
    func setupMasterPassword(_ password: String) async -> Bool {
        do {
            try await secureStore.configureMasterPassword(password)
            hasMasterPassword = true
            AppProfile.defaults.set(true, forKey: Self.lockHintKey)
            isLocked = false
            error = nil
            logger.info("Master password configured")
            return true
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to set master password: \(error)")
            return false
        }
    }

    /// Verify master password to unlock (with rate limiting)
    func unlock(_ password: String) async -> Bool {
        isVerifying = true
        defer { isVerifying = false }

        do {
            let isValid = try await secureStore.unlock(masterPassword: password)
            if isValid {
                isLocked = false
                error = nil
                logger.info("Unlocked successfully")
                return true
            } else {
                error = String(localized: "Incorrect password")
                // Check if a rate limit was just applied
                if let remaining = try? await secureStore.rateLimitRemainingSeconds() {
                    error = String(localized: "Incorrect password. Try again in \(remaining) seconds.")
                }
                return false
            }
        } catch SecureStoreService.SecureStoreError.rateLimited(let seconds) {
            self.error = String(localized: "Too many failed attempts. Try again in \(seconds) seconds.")
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Lock the app
    func lock() {
        guard hasMasterPassword else { return }
        isLocked = true
        Task {
            await secureStore.lockVault()
        }
        logger.info("App locked")
    }

    /// Remove master password
    func removeMasterPassword() async {
        // Never from behind the lock screen: it would unlock the app without the password.
        guard !isLocked else {
            error = String(localized: "Unlock the app before removing the master password.")
            return
        }
        do {
            try await secureStore.deleteMasterPassword()
            hasMasterPassword = false
            AppProfile.defaults.set(false, forKey: Self.lockHintKey)
            isLocked = false
            error = nil
            logger.info("Master password removed")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
