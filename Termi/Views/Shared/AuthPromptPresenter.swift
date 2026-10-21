import AppKit
import SwiftUI

/// Presents SSH authentication questions (passwords, key passphrases, 2FA codes, new host
/// keys) as native sheets on the key window. Prompts are shown one at a time; a prompt whose
/// connection is cancelled or closed is dismissed automatically.
@MainActor
final class AuthPromptPresenter {
    static let shared = AuthPromptPresenter()

    private var isPresenting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var currentAlert: NSAlert?
    private var currentSheetParent: NSWindow?
    /// While the app is locked no question is put in front of the lock screen.
    private var isAppLocked = false

    /// Called by every window when the app locks or unlocks.
    func appLockChanged(_ locked: Bool) {
        isAppLocked = locked
        if locked { dismissCurrent() }
    }

    func present(_ prompt: SSHPrompt) async -> SSHPromptResponse {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return .cancel }
        // Asked while locked (a reconnect after wake): answered as cancelled, the session
        // offers Reconnect once the app is unlocked.
        guard !isAppLocked else { return prompt.kind == .confirmation ? .reject : .cancel }
        return await withTaskCancellationHandler {
            await show(prompt)
        } onCancel: {
            Task { @MainActor in AuthPromptPresenter.shared.dismissCurrent() }
        }
    }

    // MARK: - Serialization

    private func acquire() async {
        if !isPresenting {
            isPresenting = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isPresenting = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    #if DEBUG
    /// The serialized path of `present`, with a key on record.
    fileprivate func debugShow(_ prompt: SSHPrompt, savedFingerprint: String?) async -> SSHPromptResponse {
        await acquire()
        defer { release() }
        return await show(prompt, savedFingerprint: savedFingerprint)
    }
    #endif

    private func dismissCurrent() {
        guard let alert = currentAlert else { return }
        if let parent = currentSheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        } else {
            NSApp.stopModal(withCode: .cancel)
        }
    }

    // MARK: - Alerts

    /// Width shared by everything under the alert text: the answer field, the "save" checkbox
    /// and the host key details.
    private static let accessoryWidth: CGFloat = 280

    /// `savedFingerprint`: the key this app has on record for the host, when the question is
    /// about a key that differs from it. ssh itself refuses a changed key without asking
    /// (`SSHError.hostKeyChanged`), so today's prompts never carry one.
    private func show(_ prompt: SSHPrompt, savedFingerprint: String? = nil) async -> SSHPromptResponse {
        let alert = NSAlert()
        let hostName = prompt.hopDisplayName ?? prompt.connectionName
        let endpoint = prompt.hopEndpoint ?? hostName
        // "name (user@address)"; a host known only by its address is not named twice.
        let origin = hostName == endpoint ? endpoint : "\(hostName) (\(endpoint))"
        var field: NSTextField?
        var saveCheckbox: NSButton?

        switch prompt.kind {
        case .hostKey(_, let keyType, let fingerprint):
            alert.alertStyle = .warning
            let isChanged = HostKeyDetails.isChange(from: savedFingerprint, to: fingerprint)
            if isChanged {
                alert.messageText = String(localized: "The host key of “\(hostName)” has changed")
                alert.informativeText = endpoint
            } else {
                alert.messageText = String(localized: "Trust the host key of “\(hostName)”?")
                alert.informativeText = String(localized: "This is the first connection to \(endpoint). Make sure the fingerprint matches the one on the server before you trust it.")
            }
            let details = HostKeyDetails(
                keyType: keyType, fingerprint: fingerprint, savedFingerprint: isChanged ? savedFingerprint : nil,
                changedMessage: isChanged ? SSHError.hostKeyChanged(host: hostName, detail: "").errorDescription : nil,
                rawText: prompt.message, width: Self.accessoryWidth)
            let hosting = NSHostingView(rootView: details)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            alert.accessoryView = hosting
            alert.addButton(withTitle: String(localized: "Trust & Connect"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if isChanged {
                // Return must not trust a key that differs from the one on record.
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[1].keyEquivalent = "\r"
            }

        case .confirmation:
            alert.messageText = prompt.message
            alert.informativeText = origin
            alert.addButton(withTitle: String(localized: "Allow"))
            alert.addButton(withTitle: String(localized: "Deny"))

        case .password:
            alert.messageText = String(localized: "Password for \(hostName)")
            // The title already names the host.
            alert.informativeText = Self.informativeText(origin: hostName == endpoint ? nil : endpoint,
                                                         details: prompt.details)
            field = Self.answerField(isSecret: true, placeholder: String(localized: "Password"))
            alert.addButton(withTitle: String(localized: "Connect"))
            alert.addButton(withTitle: String(localized: "Cancel"))

        case .passphrase:
            alert.messageText = String(localized: "Passphrase for the private key")
            alert.informativeText = Self.informativeText(origin: origin, details: prompt.details)
            field = Self.answerField(isSecret: true, placeholder: String(localized: "Passphrase"))
            alert.addButton(withTitle: String(localized: "Unlock"))
            alert.addButton(withTitle: String(localized: "Cancel"))

        case .keyboardInteractive(_, let question):
            let lowered = question.lowercased()
            let secret = ["password", "passphrase", "pin", "密码"].contains { lowered.contains($0) }
            alert.messageText = question.isEmpty ? String(localized: "Response required") : question
            alert.informativeText = Self.informativeText(origin: origin, details: prompt.details)
            field = Self.answerField(isSecret: secret)
            alert.addButton(withTitle: String(localized: "Continue"))
            alert.addButton(withTitle: String(localized: "Cancel"))

        case .other:
            alert.messageText = prompt.message.isEmpty ? String(localized: "Response required") : prompt.message
            alert.informativeText = Self.informativeText(origin: origin, details: prompt.details)
            field = Self.answerField(isSecret: prompt.isSecret)
            alert.addButton(withTitle: String(localized: "Continue"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        }

        if let field {
            field.setAccessibilityLabel(alert.messageText)
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            field.frame = NSRect(x: 0, y: 0, width: Self.accessoryWidth, height: 24)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: Self.accessoryWidth).isActive = true
            stack.addArrangedSubview(field)
            if prompt.canSave {
                let checkbox = NSButton(checkboxWithTitle: String(localized: "Save to vault"), target: nil, action: nil)
                checkbox.state = .off
                stack.addArrangedSubview(checkbox)
                saveCheckbox = checkbox
            }
            stack.frame = NSRect(x: 0, y: 0, width: Self.accessoryWidth, height: prompt.canSave ? 52 : 24)
            alert.accessoryView = stack
            alert.window.initialFirstResponder = field
        }

        let parent = Self.sheetParent()
        currentAlert = alert
        currentSheetParent = parent
        defer {
            currentAlert = nil
            currentSheetParent = nil
        }

        let response: NSApplication.ModalResponse
        if let parent {
            if let field {
                DispatchQueue.main.async { alert.window.makeFirstResponder(field) }
            }
            response = await alert.beginSheetModal(for: parent)
        } else {
            NSApp.activate()
            response = alert.runModal()
        }

        guard response == .alertFirstButtonReturn else {
            return prompt.kind == .confirmation ? .reject : .cancel
        }
        switch prompt.kind {
        case .hostKey, .confirmation:
            return .accept
        default:
            return .text(field?.stringValue ?? "", save: saveCheckbox?.state == .on)
        }
    }

    /// Masked answers go through a field that keeps the keyboard on a Roman input source.
    private static func answerField(isSecret: Bool, placeholder: String? = nil) -> NSTextField {
        let field: NSTextField = isSecret ? ASCIISecureTextField() : NSTextField()
        field.placeholderString = placeholder
        return field
    }

    /// Where the question comes from, then what ssh printed before asking (banner, instructions).
    /// ssh's own notice about a rejected answer is given in the app's language; what the
    /// server wrote stays as it came.
    static func informativeText(origin: String?, details: String?) -> String {
        var parts: [String] = []
        if let origin, !origin.isEmpty { parts.append(origin) }
        if let details, !details.isEmpty {
            let text = details.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0 == SSHMasterConnection.retryNotice ? String(localized: "That was not accepted. Try again.") : String($0) }
                .joined(separator: "\n")
            parts.append(text.count > 800 ? String(text.prefix(800)) + "…" : text)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Key window (or the sheet currently attached to it, so prompts appear above open forms).
    private static func sheetParent() -> NSWindow? {
        let candidate = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.canBecomeKey }
        guard var window = candidate else { return nil }
        while let sheet = window.attachedSheet {
            window = sheet
        }
        return window
    }
}

// MARK: - Secure field

/// Secure field for alerts that forces ASCII input while it is edited, so a CJK input method
/// cannot intercept the keystrokes of a password or passphrase (same rule as `ASCIISecureField`).
private final class ASCIISecureTextField: NSSecureTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            // The field editor is in place now: restrict it before the first keystroke.
            currentEditor()?.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        }
        return accepted
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        NSTextInputContext.current?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
    }

    override func textDidEndEditing(_ notification: Notification) {
        // Restore unrestricted input for whatever is edited next.
        (notification.object as? NSView)?.inputContext?.allowedInputSourceLocales = nil
        NSTextInputContext.current?.allowedInputSourceLocales = nil
        super.textDidEndEditing(notification)
    }
}

// MARK: - Host key details

/// What to compare before trusting a host key: its fingerprint image (the picture
/// `ssh-keygen -lv` prints on the server), the key type and the fingerprint in a quiet box with
/// a button to copy it. A key that differs from the one on record is shown next to it. ssh's own
/// wording stays one hover away (tooltip); it is shown in place only if no fingerprint could be
/// read — and then there is no image either, never a placeholder.
private struct HostKeyDetails: View {
    let keyType: String?
    let fingerprint: String?
    /// The key on record, when the received one differs from it.
    var savedFingerprint: String?
    /// What a changed key means; shown under the two images.
    var changedMessage: String?
    let rawText: String
    let width: CGFloat

    /// A key is on record and the received one is another.
    static func isChange(from saved: String?, to received: String?) -> Bool {
        guard let saved, !saved.isEmpty, let received, !received.isEmpty else { return false }
        return saved != received
    }

    private var parsed: String? {
        fingerprint.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func canDraw(_ fingerprint: String?) -> Bool {
        fingerprint.flatMap { Randomart(fingerprint: $0) } != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let parsed {
                if Self.canDraw(parsed) {
                    if let savedFingerprint, Self.canDraw(savedFingerprint) {
                        HStack(alignment: .top, spacing: DS.Space.md) {
                            image("Saved", fingerprint: savedFingerprint)
                            image("Received Now", fingerprint: parsed)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        DSRandomart(fingerprint: parsed, cell: 8)
                            .frame(maxWidth: .infinity)
                    }
                }
                fingerprintBox(parsed)
                if let changedMessage {
                    DSMessage(verbatim: changedMessage)
                }
            } else {
                Text(verbatim: rawText)
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .quaternarySystemFill),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(width: width, alignment: .leading)
        .help(Text(verbatim: parsed == nil ? "" : rawText))
    }

    private func image(_ title: LocalizedStringKey, fingerprint: String) -> some View {
        VStack(spacing: DS.Space.xs) {
            Text(title)
                .font(.system(size: NSFont.smallSystemFontSize, weight: .medium))
                .foregroundStyle(.secondary)
            DSRandomart(fingerprint: fingerprint, cell: 7)
        }
    }

    private func fingerprintBox(_ fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: String(localized: "\(keyType ?? "SSH") key fingerprint"))
                .font(.system(size: NSFont.smallSystemFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .center, spacing: 6) {
                Text(verbatim: fingerprint)
                    .font(.system(size: NSFont.smallSystemFontSize, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DSCopyButton(help: "Copy Fingerprint") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fingerprint, forType: .string)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

#if DEBUG
extension AuthPromptPresenter {
    /// Debug builds only (`-debugHostKeyPrompt new|changed` on the Known Hosts page): the host
    /// key question with sample data, for screenshots. The answer goes nowhere.
    func debugPresentHostKey(fingerprint: String?, savedFingerprint: String?) async {
        let received = fingerprint ?? "SHA256:uoegvOcHoxvYxLIoqq0BN/NyAxhtIDI9PGfffjrss0E"
        let prompt = SSHPrompt(
            kind: .hostKey(alias: nil, keyType: "ED25519", fingerprint: received),
            hopDisplayName: "web-01",
            hopEndpoint: "deploy@10.0.12.4",
            connectionName: "web-01",
            message: "The authenticity of host '10.0.12.4 (10.0.12.4)' can't be established.\nED25519 key fingerprint is \(received).",
            details: nil,
            canSave: false,
            isSecret: false
        )
        _ = await debugShow(prompt, savedFingerprint: savedFingerprint)
    }
}
#endif
