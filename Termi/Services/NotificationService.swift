import UserNotifications
import AppKit
import os.log

/// System notification service — sends macOS notifications for SSH, SFTP, and batch events.
/// Only delivers notifications when the app is not the frontmost application.
@MainActor
final class NotificationService: NSObject, @unchecked Sendable {
    static let shared = NotificationService()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "Notification")
    private let center = UNUserNotificationCenter.current()

    // MARK: - Settings Keys (match AppSetting keys in DB)

    static let enabledKey = "notifications_enabled"
    static let sshKey = "notifications_ssh"
    static let sftpKey = "notifications_sftp"
    static let batchKey = "notifications_batch"

    // Cached preferences (loaded once, updated via SettingsViewModel)
    var isEnabled = true
    var sshEnabled = true
    var sftpEnabled = true
    var batchEnabled = true

    private override init() {
        super.init()
        center.delegate = self
    }

    // MARK: - Permission

    func requestPermission() {
        let logger = logger
        // @Sendable: UserNotifications calls completion handlers on its own queue. Without it the
        // closure would inherit this class's MainActor isolation and Swift 6's runtime check traps.
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
            if let error {
                logger.warning("Notification permission error: \(error)")
            } else {
                logger.info("Notification permission granted: \(granted)")
            }
        }
    }

    // MARK: - SSH Notifications

    func sendSSHConnected(host: String) {
        guard shouldSend, sshEnabled else { return }
        send(
            title: String(localized: "SSH Connected"),
            body: String(localized: "Connected to \(host)"),
            categoryId: "ssh"
        )
    }

    func sendSSHDisconnected(host: String) {
        guard shouldSend, sshEnabled else { return }
        send(
            title: String(localized: "SSH Disconnected"),
            body: String(localized: "Disconnected from \(host)"),
            categoryId: "ssh"
        )
    }

    func sendSSHFailed(host: String, error: String) {
        guard shouldSend, sshEnabled else { return }
        send(
            title: String(localized: "SSH Connection Failed"),
            body: "\(host): \(error)",
            categoryId: "ssh"
        )
    }

    // MARK: - SFTP Notifications

    func sendTransferComplete(fileName: String, direction: String) {
        guard shouldSend, sftpEnabled else { return }
        send(
            title: String(localized: "SFTP Transfer Complete"),
            body: "\(direction): \(fileName)",
            categoryId: "sftp"
        )
    }

    // MARK: - Batch Command Notifications

    func sendBatchComplete(hostCount: Int, successCount: Int) {
        guard shouldSend, batchEnabled else { return }
        send(
            title: String(localized: "Batch Command Complete"),
            body: String(localized: "\(successCount)/\(hostCount) hosts succeeded"),
            categoryId: "batch"
        )
    }

    // MARK: - Load Preferences

    func loadPreferences() async {
        do {
            let reader = try await DatabaseManager.shared.reader
            let settings = try await reader.read { db in
                try AppSetting.fetchAll(db)
            }
            let dict = Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0.value) })

            isEnabled = dict[Self.enabledKey] != "false"
            sshEnabled = dict[Self.sshKey] != "false"
            sftpEnabled = dict[Self.sftpKey] != "false"
            batchEnabled = dict[Self.batchKey] != "false"
        } catch {
            logger.warning("Failed to load notification preferences: \(error)")
        }
    }

    // MARK: - Private

    /// Only send when the global toggle is on AND the app is not frontmost.
    private var shouldSend: Bool {
        isEnabled && !NSApp.isActive
    }

    private func send(title: String, body: String, categoryId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryId

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        let logger = logger
        center.add(request) { @Sendable error in
            if let error {
                logger.warning("Failed to deliver notification: \(error)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show notifications even when the app is in the foreground (edge case: user has multiple monitors).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Don't show banner if app is active — the shouldSend guard already prevents
        // sending in most cases, but this is a safety net for race conditions.
        await MainActor.run {
            NSApp.isActive ? [] : [.banner, .sound]
        }
    }
}
