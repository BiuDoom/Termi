#if DEBUG
import AppKit
import ObjectiveC

/// Screenshots are taken with the screen locked, where no window can become key and AppKit
/// draws every control in its inactive state: grey primary buttons, grey switches, grey
/// selection. `-debugActive YES` makes the app and its windows report themselves as active,
/// so that a screenshot shows what a person sitting at the Mac sees. Debug builds only.
@MainActor
enum DebugActiveAppearance {
    static func installIfRequested() {
        guard AppProfile.arguments.bool(forKey: "debugActive") else { return }
        exchange(NSWindow.self, #selector(getter: NSWindow.isKeyWindow), #selector(NSWindow.debugIsKeyWindow))
        exchange(NSWindow.self, #selector(getter: NSWindow.isMainWindow), #selector(NSWindow.debugIsMainWindow))
        // What controls and materials ask; not in the headers, so looked up by name.
        exchange(NSWindow.self, NSSelectorFromString("hasKeyAppearance"), #selector(NSWindow.debugIsKeyWindow))
        exchange(NSWindow.self, NSSelectorFromString("hasMainAppearance"), #selector(NSWindow.debugIsMainWindow))
        exchange(NSApplication.self, #selector(getter: NSApplication.isActive), #selector(NSApplication.debugIsActive))
    }

    private static func exchange(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let method = class_getInstanceMethod(type, original),
              let other = class_getInstanceMethod(type, replacement) else { return }
        method_setImplementation(method, method_getImplementation(other))
    }
}

extension NSWindow {
    @objc fileprivate func debugIsKeyWindow() -> Bool { true }
    @objc fileprivate func debugIsMainWindow() -> Bool { true }
}

extension NSApplication {
    @objc fileprivate func debugIsActive() -> Bool { true }
}
#endif
