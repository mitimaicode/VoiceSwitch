import AppKit
import Foundation

final class GlobalHotKey {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false

    var onPress: (() -> Void)?
    func start() {
        stop()

        let mask: NSEvent.EventTypeMask = [.flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        isPressed = false
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chordIsPressed = modifiers.contains(.function)
            && modifiers.contains(.option)
            && !modifiers.contains(.command)
            && !modifiers.contains(.control)
            && !modifiers.contains(.shift)

        guard chordIsPressed != isPressed else { return }
        isPressed = chordIsPressed

        if chordIsPressed {
            DispatchQueue.main.async { [weak self] in
                self?.onPress?()
            }
        }
    }

    deinit {
        stop()
    }
}
