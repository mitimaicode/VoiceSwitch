import AppKit
import ApplicationServices
import Foundation

final class FrontmostApplicationTracker {
    private(set) var lastExternalPID: pid_t?
    private var observer: NSObjectProtocol?

    init() {
        update(with: NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.update(with: app)
        }
    }

    private func update(with app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        lastExternalPID = app.processIdentifier
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}

enum TextInjector {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func paste(_ text: String, into targetPID: pid_t?) -> Bool {
        copy(text)
        guard Permissions.accessibilityAuthorized else {
            return false
        }

        if let targetPID,
           let target = NSRunningApplication(processIdentifier: targetPID) {
            target.activate(options: [])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let keyDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0x09,
                    keyDown: true
                  ),
                  let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0x09,
                    keyDown: false
                  ) else {
                return
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return true
    }
}
