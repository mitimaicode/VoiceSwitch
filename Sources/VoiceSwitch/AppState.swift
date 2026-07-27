import AppKit
import AVFoundation
import Combine
import Foundation

final class AppState: ObservableObject {
    @Published var selectedEngine: ASREngine {
        didSet {
            UserDefaults.standard.set(selectedEngine.rawValue, forKey: "selectedEngine")
            asrService.switchEngine(to: selectedEngine)
            if (selectedEngine.requiresRuntime || textProcessingMode.usesLocalModel),
               !runtimeReady {
                status = "Для \(selectedEngine.shortTitle) обновите локальные модели."
            } else {
                status = "Выбрана \(selectedEngine.shortTitle). Модель подготовится при первой записи."
            }
        }
    }
    @Published var autoPaste: Bool {
        didSet {
            UserDefaults.standard.set(autoPaste, forKey: "autoPaste")
        }
    }
    @Published var textProcessingMode: TextProcessingMode {
        didSet {
            UserDefaults.standard.set(
                textProcessingMode.rawValue,
                forKey: "textProcessingMode"
            )
            if !textProcessingMode.usesLocalModel {
                textProcessingService.shutdown()
            }
            if textProcessingMode.usesLocalModel, !runtimeReady {
                status = "Для режима «\(textProcessingMode.title)» обновите локальные модели."
            } else {
                status = textProcessingMode.usesLocalModel
                    ? "Выбран режим «\(textProcessingMode.title)». Редактор подготовится после распознавания."
                    : "Выбран дословный режим без обработки текста."
            }
        }
    }
    @Published var recognitionContext: String {
        didSet {
            UserDefaults.standard.set(recognitionContext, forKey: "recognitionContext")
        }
    }
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isProcessingText = false
    @Published private(set) var status = "Готово к записи"
    @Published private(set) var lastText = ""
    @Published private(set) var lastMetrics = ""
    @Published private(set) var lastOutputMode: TextProcessingMode = .verbatim
    @Published private(set) var lastRating: String?
    @Published private(set) var permissionsVersion = 0
    @Published private(set) var runtimeReady = RuntimePaths.isRuntimeReady
    @Published private(set) var isInstallingRuntime = false
    @Published private(set) var runtimeInstallStatus = ""

    let hudModel: HUDModel

    private let audioRecorder = AudioRecorder()
    private let hotKey = GlobalHotKey()
    private let asrService = ASRService()
    private let textProcessingService = TextProcessingService()
    private let runtimeInstaller = RuntimeInstaller()
    private let appTracker = FrontmostApplicationTracker()
    private lazy var hudController = HUDController(model: hudModel)
    private var targetPID: pid_t?
    private var recordingSource = "button"
    private var lastResult: TranscriptionResult?

    init() {
        let savedEngine = UserDefaults.standard.string(forKey: "selectedEngine")
            .flatMap(ASREngine.init(rawValue:))
        selectedEngine = savedEngine ?? .gigaam
        let savedTextMode = UserDefaults.standard.string(forKey: "textProcessingMode")
            .flatMap(TextProcessingMode.init(rawValue:))
        textProcessingMode = savedTextMode ?? .verbatim

        if UserDefaults.standard.object(forKey: "autoPaste") == nil {
            autoPaste = true
        } else {
            autoPaste = UserDefaults.standard.bool(forKey: "autoPaste")
        }
        recognitionContext =
            UserDefaults.standard.string(forKey: "recognitionContext")
            ?? UserDefaults.standard.string(forKey: "whisperPrompt")
            ?? ""

        let hudModel = HUDModel()
        self.hudModel = hudModel

        hotKey.onPress = { [weak self] in
            self?.toggleRecording(source: "hotkey")
        }
        hotKey.start()

        asrService.onWorkerEvent = { [weak self] message in
            guard let self,
                  !self.isRecording,
                  !self.isTranscribing,
                  !self.isProcessingText else {
                return
            }
            self.status = message
        }
        textProcessingService.onWorkerEvent = { [weak self] message in
            guard let self, !self.isRecording, !self.isTranscribing else { return }
            self.status = message
        }

        if !runtimeReady,
           selectedEngine.requiresRuntime || textProcessingMode.usesLocalModel {
            status = "Установите локальные модели перед первой записью."
            runtimeInstallStatus = "Потребуется около 12 ГБ свободного места."
        }
    }

    var microphoneStatus: String {
        _ = permissionsVersion
        return Permissions.microphoneStatusText
    }

    var accessibilityStatus: String {
        _ = permissionsVersion
        return Permissions.accessibilityAuthorized
            ? "Универсальный доступ: разрешён"
            : "Универсальный доступ: требуется для горячей клавиши и автовставки"
    }

    var accessibilityAuthorized: Bool {
        _ = permissionsVersion
        return Permissions.accessibilityAuthorized
    }

    var logPath: String {
        RuntimePaths.logFile.path
    }

    var runtimePath: String {
        RuntimePaths.runtimeRoot.path
    }

    var selectedEngineReady: Bool {
        (!selectedEngine.requiresRuntime || runtimeReady)
            && (!textProcessingMode.usesLocalModel || runtimeReady)
    }

    var isBusy: Bool {
        isTranscribing || isProcessingText
    }

    func toggleRecording() {
        toggleRecording(source: "button")
    }

    private func toggleRecording(source: String) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(source: source)
        }
    }

    func startRecording(source: String) {
        guard !isRecording, !isBusy else { return }
        guard selectedEngineReady else {
            status = "Сначала обновите локальные модели."
            hudController.showFailure("Требуется установка моделей")
            return
        }

        recordingSource = source
        targetPID = appTracker.lastExternalPID

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            status = "Запрашиваю доступ к микрофону…"
            Permissions.requestMicrophone { [weak self] granted in
                guard let self else { return }
                self.refreshPermissions()
                if granted {
                    self.beginRecording()
                } else {
                    self.status = VoiceSwitchError.microphoneDenied.localizedDescription
                }
            }
        case .denied, .restricted:
            status = VoiceSwitchError.microphoneDenied.localizedDescription
            hudController.showFailure("Нет доступа к микрофону")
        @unknown default:
            status = "Неизвестный статус доступа к микрофону."
            hudController.showFailure("Ошибка доступа к микрофону")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        guard let recording = audioRecorder.stop() else {
            isRecording = false
            status = "Запись не найдена."
            hudController.showFailure("Запись не найдена")
            return
        }

        isRecording = false
        guard recording.duration >= 0.25 else {
            try? FileManager.default.removeItem(at: recording.url)
            status = "Слишком короткая запись."
            hudController.showFailure("Слишком короткая запись")
            return
        }

        isTranscribing = true
        status = "Распознаёт \(selectedEngine.shortTitle)…"
        hudController.showTranscribing(engine: selectedEngine.shortTitle)

        let engine = selectedEngine
        let source = recordingSource
        let prompt = engine.supportsContext ? recognitionContext : ""
        let pasteTarget = targetPID
        let outputMode = textProcessingMode

        asrService.transcribe(
            audioURL: recording.url,
            duration: recording.duration,
            engine: engine,
            prompt: prompt
        ) { [weak self] result in
            try? FileManager.default.removeItem(at: recording.url)
            guard let self else { return }
            self.isTranscribing = false

            switch result {
            case .success(let transcription):
                self.lastResult = transcription
                self.lastRating = nil
                self.lastMetrics = self.asrMetrics(for: transcription)
                ComparisonLogger.append(
                    result: transcription,
                    source: source,
                    prompt: prompt
                )

                guard !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.status = "Речь не обнаружена."
                    self.hudController.showFailure("Речь не обнаружена")
                    return
                }

                self.process(
                    transcription: transcription,
                    mode: outputMode,
                    pasteTarget: pasteTarget
                )
            case .failure(let error):
                self.status = error.localizedDescription
                self.hudController.showFailure("Ошибка распознавания")
            }
        }
    }

    func prewarmSelectedEngine() {
        guard !isRecording, !isBusy else { return }
        guard selectedEngineReady else {
            status = "Сначала обновите локальные модели."
            return
        }
        status = "Загружаю \(selectedEngine.shortTitle)…"
        asrService.prewarm(engine: selectedEngine)
        if textProcessingMode.usesLocalModel {
            textProcessingService.prewarm()
        }
    }

    func installRuntime() {
        guard !isInstallingRuntime, !runtimeReady else { return }

        isInstallingRuntime = true
        runtimeInstallStatus = "Подготавливаю установку…"
        status = "Установка локальных моделей…"

        runtimeInstaller.install(
            status: { [weak self] message in
                guard let self else { return }
                self.runtimeInstallStatus = message
                self.status = message
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.isInstallingRuntime = false
                switch result {
                case .success:
                    self.runtimeReady = RuntimePaths.isRuntimeReady
                    self.runtimeInstallStatus = "Распознавание и локальный редактор готовы к работе."
                    self.status = "Готово к записи"
                    self.hudController.showSuccess("Модели установлены")
                case .failure(let error):
                    self.runtimeReady = RuntimePaths.isRuntimeReady
                    self.runtimeInstallStatus = error.localizedDescription
                    self.status = "Не удалось установить модели."
                    self.hudController.showFailure("Ошибка установки")
                }
            }
        )
    }

    func cancelRuntimeInstallation() {
        guard isInstallingRuntime else { return }
        runtimeInstallStatus = "Останавливаю установку…"
        runtimeInstaller.cancel()
    }

    func openRuntimeFolder() {
        try? FileManager.default.createDirectory(
            at: RuntimePaths.runtimeRoot,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(RuntimePaths.runtimeRoot)
    }

    func rateLastResult(_ rating: String) {
        guard let lastResult else { return }
        lastRating = rating
        ComparisonLogger.appendEvaluation(
            requestID: lastResult.requestID,
            engine: lastResult.engine,
            textMode: lastOutputMode,
            rating: rating
        )
    }

    func requestAccessibility() {
        Permissions.showAccessibilityRequest()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func refreshPermissions() {
        permissionsVersion += 1
    }

    func openLogFolder() {
        let folder = RuntimePaths.logFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(folder)
    }

    func quit() {
        hudController.hideImmediately()
        runtimeInstaller.cancel()
        asrService.shutdown()
        textProcessingService.shutdown()
        NSApplication.shared.terminate(nil)
    }

    private func process(
        transcription: TranscriptionResult,
        mode: TextProcessingMode,
        pasteTarget: pid_t?
    ) {
        guard mode.usesLocalModel else {
            lastOutputMode = .verbatim
            deliver(transcription.text, into: pasteTarget)
            return
        }

        isProcessingText = true
        status = "\(mode.activityTitle) локально…"
        hudController.showEditing(mode: mode.title)

        textProcessingService.process(
            text: transcription.text,
            mode: mode
        ) { [weak self] result in
            guard let self else { return }
            self.isProcessingText = false

            switch result {
            case .success(let processed):
                self.lastOutputMode = processed.mode
                self.lastMetrics =
                    "\(self.asrMetrics(for: transcription)) · редактор \(String(format: "%.1f с", processed.latency))"
                ComparisonLogger.appendPostProcessing(
                    requestID: transcription.requestID,
                    mode: processed.mode,
                    sourceText: transcription.text,
                    outputText: processed.text,
                    latency: processed.latency
                )
                self.deliver(processed.text, into: pasteTarget)
            case .failure(let error):
                NSLog("VoiceSwitch text processing fallback: \(error.localizedDescription)")
                self.lastOutputMode = .verbatim
                self.lastMetrics =
                    "\(self.asrMetrics(for: transcription)) · редактор недоступен"
                self.deliver(
                    transcription.text,
                    into: pasteTarget,
                    fallback: true
                )
            }
        }
    }

    private func deliver(
        _ text: String,
        into pasteTarget: pid_t?,
        fallback: Bool = false
    ) {
        lastText = text
        targetPID = nil

        if autoPaste {
            let pasted = TextInjector.paste(text, into: pasteTarget)
            if fallback {
                status = pasted
                    ? "Редактор недоступен — вставлена исходная расшифровка."
                    : "Редактор недоступен — исходная расшифровка скопирована."
                hudController.showSuccess(
                    pasted ? "Вставлен исходный текст" : "Исходный текст скопирован"
                )
            } else {
                status = pasted
                    ? "Готово — текст вставлен."
                    : "Готово — текст скопирован. Разрешите универсальный доступ для автовставки."
                hudController.showSuccess(
                    pasted ? "Текст вставлен" : "Текст скопирован"
                )
            }
        } else {
            TextInjector.copy(text)
            status = fallback
                ? "Редактор недоступен — исходная расшифровка скопирована."
                : "Готово — текст скопирован."
            hudController.showSuccess(
                fallback ? "Исходный текст скопирован" : "Текст скопирован"
            )
        }
    }

    private func asrMetrics(for transcription: TranscriptionResult) -> String {
        let factor = transcription.audioDuration > 0
            ? transcription.latency / transcription.audioDuration
            : 0
        return String(
            format: "%.1f с аудио → %.1f с ASR · RTF %.2f",
            transcription.audioDuration,
            transcription.latency,
            factor
        )
    }

    private func beginRecording() {
        do {
            _ = try audioRecorder.start()
            isRecording = true
            status = "Запись… отпустите и нажмите fn + ⌥ ещё раз или «Стоп»"
            hudController.showRecording()
        } catch {
            status = error.localizedDescription
            hudController.showFailure("Не удалось начать запись")
        }
    }

    deinit {
        hotKey.stop()
    }
}
