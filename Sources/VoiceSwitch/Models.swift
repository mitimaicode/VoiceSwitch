import Foundation

enum RuntimeComponent: String, CaseIterable, Identifiable, Codable, Hashable {
    case gigaam
    case whisper
    case qwenASR = "qwen"
    case textEditor = "text"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gigaam:
            return "GigaAM"
        case .whisper:
            return "Whisper"
        case .qwenASR:
            return "Qwen3-ASR"
        case .textEditor:
            return "Редактор Qwen3-4B"
        }
    }

    var detail: String {
        switch self {
        case .gigaam:
            return "Русская речь · рекомендуемая стартовая модель"
        case .whisper:
            return "Смешанная русско-английская речь"
        case .qwenASR:
            return "Экспериментальное многоязычное распознавание"
        case .textEditor:
            return "Режимы «Исправить» и «Кратко»"
        }
    }

    var downloadSize: String {
        switch self {
        case .gigaam:
            return "≈ 0,5 ГБ + базовое окружение"
        case .whisper:
            return "≈ 1,5 ГБ"
        case .qwenASR:
            return "≈ 4,4 ГБ"
        case .textEditor:
            return "≈ 2 ГБ"
        }
    }

    var icon: String {
        switch self {
        case .gigaam:
            return "waveform"
        case .whisper:
            return "character.bubble"
        case .qwenASR:
            return "globe"
        case .textEditor:
            return "text.badge.checkmark"
        }
    }
}

enum RuntimeInstallPreset: String, CaseIterable, Identifiable {
    case russian
    case mixed
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .russian:
            return "Русская диктовка"
        case .mixed:
            return "Русский + английский"
        case .full:
            return "Все возможности"
        }
    }

    var detail: String {
        switch self {
        case .russian:
            return "Только GigaAM. Самый быстрый способ начать работу."
        case .mixed:
            return "GigaAM и Whisper для переключения языков."
        case .full:
            return "Все модели распознавания и локальный редактор."
        }
    }

    var storage: String {
        switch self {
        case .russian:
            return "около 2,5 ГБ"
        case .mixed:
            return "около 4 ГБ"
        case .full:
            return "около 10 ГБ"
        }
    }

    var components: Set<RuntimeComponent> {
        switch self {
        case .russian:
            return [.gigaam]
        case .mixed:
            return [.gigaam, .whisper]
        case .full:
            return Set(RuntimeComponent.allCases)
        }
    }
}

enum OnboardingStep {
    case welcome
    case models
    case permissions
    case ready
}

enum ASREngine: String, CaseIterable, Identifiable, Codable {
    case gigaam
    case whisper
    case qwen
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gigaam:
            return "GigaAM v3 E2E RNNT"
        case .whisper:
            return "Whisper Large V3 Turbo"
        case .qwen:
            return "Qwen3-ASR 1.7B"
        case .apple:
            return "Apple SpeechAnalyzer"
        }
    }

    var shortTitle: String {
        switch self {
        case .gigaam:
            return "GigaAM"
        case .whisper:
            return "Whisper"
        case .qwen:
            return "Qwen"
        case .apple:
            return "Apple"
        }
    }

    var detail: String {
        switch self {
        case .gigaam:
            return "Приоритет: русская речь и пунктуация"
        case .whisper:
            return "Приоритет: смешанная русско-английская речь"
        case .qwen:
            return "Приоритет: точная многоязычная речь · локально через MLX"
        case .apple:
            return "Системная диктовка Apple · русский · только macOS 26+"
        }
    }

    var requiresRuntime: Bool {
        self != .apple
    }

    var runtimeComponent: RuntimeComponent? {
        switch self {
        case .gigaam:
            return .gigaam
        case .whisper:
            return .whisper
        case .qwen:
            return .qwenASR
        case .apple:
            return nil
        }
    }

    var supportsContext: Bool {
        switch self {
        case .whisper, .qwen, .apple:
            return true
        case .gigaam:
            return false
        }
    }

    var contextPlaceholder: String {
        switch self {
        case .whisper:
            return "Контекст для Whisper: имена, термины, продукты…"
        case .qwen:
            return "Контекст для Qwen: имена, термины, продукты…"
        case .apple:
            return "Слова-подсказки для Apple: имена, термины…"
        case .gigaam:
            return ""
        }
    }
}

enum TextProcessingMode: String, CaseIterable, Identifiable, Codable {
    case verbatim
    case corrected
    case concise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verbatim:
            return "Дословно"
        case .corrected:
            return "Исправить"
        case .concise:
            return "Кратко"
        }
    }

    var detail: String {
        switch self {
        case .verbatim:
            return "Вставить расшифровку без изменений"
        case .corrected:
            return "Исправить пунктуацию, повторы и слова-паразиты без сокращения смысла"
        case .concise:
            return "Сделать короткое естественное сообщение, сохранив факты и просьбы"
        }
    }

    var activityTitle: String {
        switch self {
        case .verbatim:
            return "Подготавливаю текст"
        case .corrected:
            return "Исправляю текст"
        case .concise:
            return "Сокращаю сообщение"
        }
    }

    var usesLocalModel: Bool {
        self != .verbatim
    }

    var runtimeComponent: RuntimeComponent? {
        usesLocalModel ? .textEditor : nil
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

struct TextProcessingResult {
    let requestID: String
    let mode: TextProcessingMode
    let text: String
    let latency: Double
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
