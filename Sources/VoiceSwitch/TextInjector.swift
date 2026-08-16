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
    private static let focusRestoreDelay: TimeInterval = 0.35

    private struct AccessibilityAttempt {
        let succeeded: Bool
        let role: String
        let errorCode: Int32
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func paste(_ text: String, into targetPID: pid_t?) -> Bool {
        let accessibilityAuthorized = Permissions.accessibilityAuthorized
        let initialTargetName = targetPID
            .flatMap(NSRunningApplication.init(processIdentifier:))?
            .localizedName ?? "unknown"
        ComparisonLogger.appendInjection(
            targetPID: targetPID,
            targetName: initialTargetName,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            method: "begin",
            result: accessibilityAuthorized ? "authorized" : "permission_denied",
            focusedRole: "",
            errorCode: 0
        )

        copy(text)
        guard accessibilityAuthorized else {
            return false
        }

        let currentApplication = NSWorkspace.shared.frontmostApplication
        let currentPID = currentApplication.flatMap { application -> pid_t? in
            guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !application.isTerminated else {
                return nil
            }
            return application.processIdentifier
        }
        let validTargetPID = currentPID ?? targetPID.flatMap { pid -> pid_t? in
            guard let target = NSRunningApplication(processIdentifier: pid),
                  !target.isTerminated else {
                return nil
            }
            return pid
        }

        let targetApplication = validTargetPID.flatMap(NSRunningApplication.init(processIdentifier:))
        let targetName = targetApplication?.localizedName ?? "unknown"
        targetApplication?.activate(options: [])

        DispatchQueue.main.asyncAfter(deadline: .now() + focusRestoreDelay) {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let validTargetPID {
                let attempt = insertIntoFocusedElement(
                    text,
                    applicationPID: validTargetPID
                )
                if attempt.succeeded {
                    ComparisonLogger.appendInjection(
                        targetPID: validTargetPID,
                        targetName: targetName,
                        frontmostPID: frontmostPID,
                        method: "accessibility_selected_text",
                        result: "success",
                        focusedRole: attempt.role,
                        errorCode: attempt.errorCode
                    )
                    return
                }

                let method = frontmostPID == validTargetPID
                    ? "keyboard_global"
                    : "keyboard_target_pid"
                postPasteShortcut(
                    to: frontmostPID == validTargetPID ? nil : validTargetPID
                )
                ComparisonLogger.appendInjection(
                    targetPID: validTargetPID,
                    targetName: targetName,
                    frontmostPID: frontmostPID,
                    method: method,
                    result: "fallback_posted",
                    focusedRole: attempt.role,
                    errorCode: attempt.errorCode
                )
                return
            }

            postPasteShortcut(to: nil)
            ComparisonLogger.appendInjection(
                targetPID: nil,
                targetName: "unknown",
                frontmostPID: frontmostPID,
                method: "keyboard_global",
                result: "fallback_posted",
                focusedRole: "",
                errorCode: 0
            )
        }
        return true
    }

    private static func insertIntoFocusedElement(
        _ text: String,
        applicationPID: pid_t
    ) -> AccessibilityAttempt {
        let application = AXUIElementCreateApplication(applicationPID)
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedResult == .success, let focusedValue else {
            return AccessibilityAttempt(
                succeeded: false,
                role: "",
                errorCode: focusedResult.rawValue
            )
        }

        let focusedElement = focusedValue as! AXUIElement
        var roleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        let role = roleValue as? String ?? ""
        var selectedTextSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        )
        guard settableResult == .success, selectedTextSettable.boolValue else {
            return AccessibilityAttempt(
                succeeded: false,
                role: role,
                errorCode: settableResult.rawValue
            )
        }

        var valueBeforeInsertion: CFTypeRef?
        let valueBeforeResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &valueBeforeInsertion
        )
        let insertionResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        var valueAfterInsertion: CFTypeRef?
        let valueAfterResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &valueAfterInsertion
        )
        let valueChanged = valueBeforeResult != .success
            || valueAfterResult != .success
            || (valueBeforeInsertion as? String) != (valueAfterInsertion as? String)

        return AccessibilityAttempt(
            succeeded: insertionResult == .success && valueChanged,
            role: role,
            errorCode: insertionResult == .success && !valueChanged
                ? -1
                : insertionResult.rawValue
        )
    }

    private static func postPasteShortcut(to targetPID: pid_t?) {
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

        if let targetPID {
            keyDown.postToPid(targetPID)
        } else {
            keyDown.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            if let targetPID {
                keyUp.postToPid(targetPID)
            } else {
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }
}
