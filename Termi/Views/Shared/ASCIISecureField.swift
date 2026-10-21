import SwiftUI

/// Secure text field that forces ASCII input — prevents CJK IME
/// from intercepting keystrokes in password / passphrase fields.
///
/// Uses AppKit `NSSecureTextField`. When the field begins editing
/// the coordinator restricts `NSTextInputContext.current` to
/// Roman-only input sources; on end-editing it restores the
/// user's previous locale setting.
///
/// Usage:
/// ```swift
/// ASCIISecureField("Password", text: $password) { connect() }
///     .frame(width: 250)
/// ```
struct ASCIISecureField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// Toggle this binding to `true` to programmatically focus the field.
    /// The field resets it to `false` once focus is acquired.
    var requestFocus: Binding<Bool>?
    /// `false` inside a grouped `Form` row, where fields are borderless and trailing-aligned.
    var isBezeled = true
    var onSubmit: (() -> Void)?

    // MARK: - Initializers

    /// - Parameter placeholder: looked up in the string catalog.
    init(
        _ placeholder: String.LocalizationValue,
        text: Binding<String>,
        requestFocus: Binding<Bool>? = nil,
        isBezeled: Bool = true,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = String(localized: placeholder)
        self._text = text
        self.requestFocus = requestFocus
        self.isBezeled = isBezeled
        self.onSubmit = onSubmit
    }

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = FocusableSecureTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        if isBezeled {
            // `isBordered` would switch the bezel off again and draw a plain square frame.
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.focusRingType = .exterior
        } else {
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.alignment = .right
        }
        field.lineBreakMode = .byClipping
        field.cell?.sendsActionOnEndEditing = false
        applyControlSize(context.environment.controlSize, to: field)

        return field
    }

    /// Follows SwiftUI's `.controlSize(_:)`, like the native `SecureField`.
    private func applyControlSize(_ size: ControlSize, to field: NSSecureTextField) {
        let nsSize: NSControl.ControlSize = switch size {
        case .mini: .mini
        case .small: .small
        case .large, .extraLarge: .large
        default: .regular
        }
        guard field.controlSize != nsSize || field.font == nil else { return }
        field.controlSize = nsSize
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: nsSize))
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        // Sync text → AppKit (avoid feedback loop)
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }

        // Keep coordinator's callback up-to-date
        context.coordinator.onSubmit = onSubmit
        applyControlSize(context.environment.controlSize, to: nsView)

        // Programmatic focus request (deferred to next runloop cycle)
        if requestFocus?.wrappedValue == true {
            Task { @MainActor in
                if let window = nsView.window {
                    window.makeFirstResponder(nsView)
                } else {
                    // Not in a window yet (a sheet still opening): the request waits for it.
                    (nsView as? FocusableSecureTextField)?.focusOnArrival = true
                }
                requestFocus?.wrappedValue = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: (() -> Void)?

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            _text = text
            self.onSubmit = onSubmit
        }

        // Force ASCII input when the field editor starts
        func controlTextDidBeginEditing(_ obj: Notification) {
            NSTextInputContext.current?.allowedInputSourceLocales = [
                NSAllRomanInputSourcesLocaleIdentifier
            ]
        }

        // Restore unrestricted input when done
        func controlTextDidEndEditing(_ obj: Notification) {
            NSTextInputContext.current?.allowedInputSourceLocales = nil
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // No handler: the field ends editing as usual, so Return reaches the sheet's
                // default button.
                guard let onSubmit else { return false }
                onSubmit()
                return true
            }
            return false
        }
    }
}

/// Takes the keyboard as soon as it is in a window, when it was asked to before that.
private final class FocusableSecureTextField: NSSecureTextField {
    var focusOnArrival = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnArrival, let window else { return }
        focusOnArrival = false
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
}
