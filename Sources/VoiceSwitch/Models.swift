import Foundation

enum ASREngine: String, CaseIterable, Identifiable, Codable {
    case gigaam
    case whisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gigaam:
            return "GigaAM v3 E2E RNNT"
        case .whisper:
            return "Whisper Large V3 Turbo"
        }
    }

    var shortTitle: String {
        switch self {
        case .gigaam:
            return "GigaAM"
        case .whisper:
            return "Whisper"
        }
    }

    var detail: String {
        switch self {
        case .gigaam:
            return "Приоритет: русская речь и пунктуация"
        case .whisper:
            return "Приоритет: смешанная русско-английская речь"
        }
    }
}

struct TranscriptionResult {
    let requestID: String
    let engine: ASREngine
    let text: String
    let latency: Double
    let audioDuration: Double
    let detectedLanguage: String?
}

enum VoiceSwitchError: LocalizedError {
    case runtimeMissing(String)
    case workerFailed(String)
    case invalidResponse
    case microphoneDenied
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing(let message):
            return message
        case .workerFailed(let message):
            return message
        case .invalidResponse:
            return "Движок вернул некорректный ответ."
        case .microphoneDenied:
            return "Нет доступа к микрофону."
        case .recordingFailed(let message):
            return "Не удалось записать звук: \(message)"
        }
    }
}
