import AVFoundation
import ApplicationServices
import Foundation

enum Permissions {
    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneStatusText: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "Микрофон: разрешён"
        case .denied, .restricted:
            return "Микрофон: нет доступа"
        case .notDetermined:
            return "Микрофон: ещё не запрошен"
        @unknown default:
            return "Микрофон: неизвестный статус"
        }
    }

    static var accessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    static func showAccessibilityRequest() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
