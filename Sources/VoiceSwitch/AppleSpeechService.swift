import AVFoundation
import Foundation
import Speech

final class AppleSpeechService {
    typealias Completion = (Result<(text: String, language: String), Error>) -> Void

    private var activeTask: Task<Void, Never>?

    func transcribe(
        audioURL: URL,
        context: String,
        completion: @escaping Completion
    ) {
        activeTask?.cancel()
        activeTask = Task {
            do {
                guard #available(macOS 26.0, *) else {
                    throw VoiceSwitchError.workerFailed(
                        "Apple SpeechAnalyzer доступен только в macOS 26 или новее."
                    )
                }
                try await Self.ensureAuthorization()
                let text = try await Self.transcribeFile(
                    at: audioURL,
                    context: context
                )
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async {
                    completion(.success((text, "ru")))
                }
            } catch {
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func prepare(completion: @escaping (Result<Void, Error>) -> Void) {
        activeTask?.cancel()
        activeTask = Task {
            do {
                guard #available(macOS 26.0, *) else {
                    throw VoiceSwitchError.workerFailed(
                        "Apple SpeechAnalyzer доступен только в macOS 26 или новее."
                    )
                }
                try await Self.ensureAuthorization()
                _ = try await Self.makeRussianTranscriber()
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func shutdown() {
        activeTask?.cancel()
        activeTask = nil
    }

    @available(macOS 26.0, *)
    private static func ensureAuthorization() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
        case let existing:
            status = existing
        }

        guard status == .authorized else {
            throw VoiceSwitchError.workerFailed(
                "Нет доступа к распознаванию речи Apple. Разрешите его в настройках конфиденциальности macOS."
            )
        }
    }

    @available(macOS 26.0, *)
    private static func makeRussianTranscriber(
        preset: DictationTranscriber.Preset = .shortDictation
    ) async throws -> DictationTranscriber {
        let requestedLocale = Locale(identifier: "ru-RU")
        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            throw VoiceSwitchError.workerFailed(
                "На этом Mac недоступна локальная русская модель Apple."
            )
        }

        let transcriber = DictationTranscriber(
            locale: locale,
            preset: preset
        )
        if let installation = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await installation.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        return transcriber
    }

    @available(macOS 26.0, *)
    private static func transcribeFile(
        at url: URL,
        context: String
    ) async throws -> String {
        let audioFile = try AVAudioFile(forReading: url)
        let duration = audioFile.fileFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.fileFormat.sampleRate
            : 0
        let preset: DictationTranscriber.Preset =
            duration >= 30 ? .longDictation : .shortDictation
        let transcriber = try await makeRussianTranscriber(preset: preset)
        let analysisContext = AnalysisContext()

        let hints = context
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !hints.isEmpty {
            analysisContext.contextualStrings[.general] = hints
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .lingering
            )
        )

        let resultTask = Task { () throws -> String in
            var parts: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parts.append(text)
                }
            }
            return parts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        do {
            try await analyzer.setContext(analysisContext)
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await resultTask.value
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}
