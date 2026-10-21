import SwiftUI

/// Lock screen — covers the whole window (opaque) until the master password is verified.
struct LockScreenView: View {
    @Bindable var securityVM: SecurityViewModel

    /// Optional: the lock screen also covers windows whose root has not passed the model on.
    @Environment(AppViewModel.self) private var appViewModel: AppViewModel?
    @State private var password = ""
    @State private var failedAttempts = 0
    @State private var focusPassword = false
    @State private var contentShown = false
    @State private var didUnlock = false
    @State private var capsLock = CapsLockWatcher()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let fieldWidth: CGFloat = 300
    private static let fieldHeight: CGFloat = 46
    // The icon image has a margin of its own: the drawn tile is about 120.
    private static let iconSide: CGFloat = 148
    private static let badgeSide: CGFloat = 38

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Termi"
    }

    /// Connected SSH sessions of this window: they stay up behind the lock. Only the number —
    /// which hosts is not for whoever stands in front of a locked app.
    private var liveSessionCount: Int {
        #if DEBUG
        // -debugLockSessions 3: the line without connecting anything, for screenshots.
        let sample = AppProfile.arguments.integer(forKey: "debugLockSessions")
        if sample > 0 { return sample }
        #endif
        return appViewModel?.liveSSHSessionCount ?? 0
    }

    private var isCapsLockOn: Bool {
        #if DEBUG
        if AppProfile.arguments.bool(forKey: "debugLockCaps") { return true }
        #endif
        return capsLock.isOn
    }

    var body: some View {
        VStack(spacing: 0) {
            appIcon

            Text(verbatim: appName)
                .font(.system(size: 30, weight: .bold))
                .padding(.top, DS.Space.xl)

            subtitle
                .frame(height: 18)
                .padding(.top, DS.Space.sm)

            passwordField
                .padding(.top, 30)
                // A wrong password shakes the field once and comes to rest where it started.
                .phaseAnimator([0, -8, 8, -5, 5, 0] as [CGFloat], trigger: failedAttempts) { field, offset in
                    field.offset(x: offset)
                } animation: { _ in
                    .linear(duration: 0.06)
                }

            // Wrong password / "try again in …" from the view model. The line keeps its space, so
            // the form does not jump when it comes or goes. (Caps Lock is a mark in the field.)
            Text(verbatim: securityVM.error ?? " ")
                .font(.callout)
                .foregroundStyle(DS.Palette.danger.mix(with: .primary, by: 0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.fieldWidth + DS.Space.xxxl * 2)
                .frame(minHeight: 34, alignment: .top)
                .padding(.top, DS.Space.sm)
                .opacity(securityVM.error == nil ? 0 : 1)
                .accessibilityHidden(securityVM.error == nil)
        }
        .padding(DS.Space.xxxl)
        // The backdrop is opaque from the first frame; only the form eases in.
        .opacity(contentShown ? 1 : 0)
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        // The window's wash of the accent, over an opaque base (below).
        .dsStageBackground()
        // Opaque: nothing of the window's content shows through, and no click reaches it.
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
                // The title bar goes with the toolbar (below): the window moves by its background.
                .gesture(WindowDragGesture())
        }
        // The toolbar's items (search, page actions) belong to the content behind the lock.
        .toolbar(.hidden, for: .windowToolbar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Termi is Locked"))
        .accessibilityAddTraits(.isModal)
        // The keyboard goes to the password field once the lock screen is in its window. Asked
        // any earlier (`onAppear`), the field may have no window yet and the request is lost.
        .background {
            WindowArrival { focusPassword = true }
                .frame(width: 0, height: 0)
        }
        .onAppear {
            capsLock.start()
            #if DEBUG
            // -debugLockTyped YES: the field with something typed (the submit button enabled),
            // for screenshots. Not a password: nothing is submitted.
            if AppProfile.arguments.bool(forKey: "debugLockTyped") { password = "screenshot-only" }
            #endif
            withAnimation(.easeOut(duration: 0.2)) { contentShown = true }
        }
        .onDisappear {
            capsLock.stop()
        }
        // The monitor only hears keys pressed while the app is active.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            capsLock.refresh()
        }
    }

    // MARK: - Parts

    /// The app's icon over a glow of the accent, with the lock in a glass badge at its corner.
    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: Self.iconSide, height: Self.iconSide)
            .shadow(color: DS.Palette.accent.opacity(0.34), radius: 28, x: 0, y: 18)
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: didUnlock ? "lock.open" : "lock")
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: failedAttempts)
                    .frame(width: Self.badgeSide, height: Self.badgeSide)
                    .dsGlass(.circle)
                    .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                    // The icon image has a margin of its own: the badge sits on the corner of
                    // the drawn shape, not of the frame.
                    .offset(x: -5, y: -5)
                    .accessibilityHidden(true)
            }
    }

    /// What is behind the lock. With nothing running there is nothing to say: the field's
    /// placeholder already asks for the master password.
    @ViewBuilder
    private var subtitle: some View {
        if liveSessionCount > 0 {
            HStack(spacing: DS.Space.sm) {
                DSStatusDot(color: DS.Palette.success, size: 8)
                    .shadow(color: DS.Palette.success.opacity(0.8), radius: 5)
                Text("\(liveSessionCount) sessions stay connected in the background")
                    .monospacedDigit()
            }
            .font(DS.Font.body)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    /// One glass capsule: the field and, inside it, the Caps Lock mark and the round button
    /// that submits it.
    private var passwordField: some View {
        HStack(spacing: DS.Space.card) {
            ASCIISecureField("Master Password", text: $password, requestFocus: $focusPassword, isBezeled: false) {
                attemptUnlock()
            }
            .controlSize(.large)
            .background { LeadingSecureFieldAlignment().frame(width: 0, height: 0) }

            // Where the eye is while typing; it can be seen together with an error below.
            if isCapsLockOn {
                Image(systemName: "capslock")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.Palette.warning)
                    .help("Caps Lock is on")
                    .accessibilityLabel(Text("Caps Lock is on"))
                    .transition(.opacity)
            }

            submitButton
        }
        .padding(.leading, 18)
        .padding(.trailing, 7)
        .frame(width: Self.fieldWidth, height: Self.fieldHeight)
        .dsGlass(.capsule)
        // The field draws no focus ring of its own inside the glass: the capsule carries it.
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(DS.Palette.accent.opacity(0.42), lineWidth: 3.5)
                .padding(-3.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 20, x: 0, y: 14)
    }

    private var submitButton: some View {
        let isDisabled = password.isEmpty || securityVM.isVerifying
        return Button(action: attemptUnlock) {
            ZStack {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
                    .opacity(securityVM.isVerifying ? 0 : 1)
                if securityVM.isVerifying {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .foregroundStyle(.white)
            .frame(width: DS.Height.control, height: DS.Height.control)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // The one primary action of the screen. A plain accent disc, not tinted glass: it sits
        // inside the capsule's glass, and glass on glass loses its tint.
        .background(DS.Palette.accent.gradient, in: Circle())
        .shadow(color: DS.Palette.accent.opacity(isDisabled ? 0 : 0.45), radius: 6, x: 0, y: 2)
        .opacity(isDisabled && !securityVM.isVerifying ? 0.4 : 1)
        .keyboardShortcut(.defaultAction)
        .disabled(isDisabled)
        .help("Unlock")
        .accessibilityLabel(Text("Unlock"))
    }

    private func attemptUnlock() {
        guard !password.isEmpty, !securityVM.isVerifying else { return }
        Task {
            let success = await securityVM.unlock(password)
            if success {
                // The badge opens while the screen fades out.
                didUnlock = true
            } else {
                password = ""
                if !reduceMotion {
                    failedAttempts += 1
                }
                if let error = securityVM.error {
                    AccessibilityNotification.Announcement(error).post()
                }
                focusPassword = true
            }
        }
    }
}

/// Whether Caps Lock is on, kept current while the lock screen is up.
@Observable
@MainActor
private final class CapsLockWatcher {
    private(set) var isOn = false
    @ObservationIgnored private var monitor: Any?

    func refresh() {
        isOn = NSEvent.modifierFlags.contains(.capsLock)
    }

    func start() {
        refresh()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { @Sendable [weak self] event in
            let isOn = event.modifierFlags.contains(.capsLock)
            // Captured again: a weak capture is a `var`, which the task may not share.
            Task { @MainActor [weak self] in
                self?.isOn = isOn
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

/// `ASCIISecureField` without a bezel right-aligns its text (it was made for form rows). In the
/// capsule the password starts at the leading edge: once in the window, this finds the secure
/// field it sits behind and changes its alignment.
private struct LeadingSecureFieldAlignment: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After the update that put the views in the window.
            Task { @MainActor [weak self] in
                guard let self, let root = self.window?.contentView else { return }
                // Its own field is the one whose frame contains this probe.
                let origin = self.convert(NSPoint.zero, to: nil)
                let field = Self.secureFields(in: root)
                    .first { $0.convert($0.bounds, to: nil).insetBy(dx: -1, dy: -1).contains(origin) }
                field?.alignment = .natural
                #if DEBUG
                // -debugLockTyped fills the field after it took the keyboard, which leaves the
                // sample selected; typing never does. Screenshots show it as typed.
                if AppProfile.arguments.bool(forKey: "debugLockTyped") {
                    try? await Task.sleep(for: .milliseconds(900))
                    if let field, let editor = field.currentEditor() {
                        editor.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
                    }
                }
                #endif
            }
        }

        private static func secureFields(in view: NSView) -> [NSSecureTextField] {
            var found: [NSSecureTextField] = []
            if let field = view as? NSSecureTextField { found.append(field) }
            for subview in view.subviews {
                found += secureFields(in: subview)
            }
            return found
        }
    }
}

/// Zero-size NSView that calls back once, when it is in a window and the update that put it
/// there is over (so the views that came with it are in the window too).
private struct WindowArrival: NSViewRepresentable {
    let onArrival: () -> Void

    func makeNSView(context: Context) -> NSView {
        WindowArrivalView(onArrival: onArrival)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowArrivalView: NSView {
    private let onArrival: () -> Void
    private var hasArrived = false

    init(onArrival: @escaping () -> Void) {
        self.onArrival = onArrival
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Once: asked again while the password is being typed, the field would select it all.
        guard window != nil, !hasArrived else { return }
        hasArrived = true

        Task { @MainActor in
            self.onArrival()
        }
    }
}

/// Sets the master password (first-time configuration, from Settings › General › Security).
struct MasterPasswordSetupView: View {
    @Bindable var securityVM: SecurityViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var isSaving = false
    @State private var focusPassword = true
    @State private var focusConfirm = false

    private var isValid: Bool {
        password.count >= 8 && password == confirmPassword
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("New Password") {
                    ASCIISecureField("At least 8 characters", text: $password, requestFocus: $focusPassword, isBezeled: false) {
                        focusConfirm = true
                    }
                }
                LabeledContent("Confirm Password") {
                    ASCIISecureField("Retype Password", text: $confirmPassword, requestFocus: $focusConfirm, isBezeled: false) {
                        save()
                    }
                }
            } header: {
                DSSheetTitle("Set Master Password")
            } footer: {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Text("The master password encrypts your saved passwords and SSH keys. It cannot be recovered if you forget it.")
                        .foregroundStyle(.secondary)

                    // Nothing while the entry can still become valid: the length is checked once the
                    // confirmation is started, a mismatch only when the confirmation is no longer the
                    // beginning of the password.
                    if !confirmPassword.isEmpty && password.count < 8 {
                        hint("Password must be at least 8 characters", color: DS.Palette.warning)
                    } else if !confirmPassword.isEmpty && !password.hasPrefix(confirmPassword) {
                        hint("Passwords don't match", color: DS.Palette.danger)
                    }
                    if let error {
                        DSMessage(verbatim: error)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Set Password") { save() }
                    .disabled(!isValid || isSaving)
            }
        }
    }

    /// Live validation line under the fields: symbol + text, so it does not rely on colour alone.
    private func hint(_ text: LocalizedStringKey, color: Color) -> some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
        }
    }

    private func save() {
        guard isValid, !isSaving else { return }
        isSaving = true
        Task {
            let success = await securityVM.setupMasterPassword(password)
            isSaving = false
            if success {
                dismiss()
            } else {
                error = securityVM.error
            }
        }
    }
}
