import Foundation

final class ASRService {
    typealias Completion = (Result<TranscriptionResult, Error>) -> Void

    private let queue = DispatchQueue(label: "VoiceSwitch.ASRService")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var currentEngine: ASREngine?
    private var pending: [String: Completion] = [:]
    private let appleSpeechService = AppleSpeechService()

    var onWorkerEvent: ((String) -> Void)?

    func transcribe(
        audioURL: URL,
        duration: Double,
        engine: ASREngine,
        prompt: String,
        completion: @escaping Completion
    ) {
        let requestID = UUID().uuidString

        if engine == .apple {
            let started = Date()
            appleSpeechService.transcribe(
                audioURL: audioURL,
                context: prompt
            ) { result in
                switch result {
                case .success(let appleResult):
                    completion(.success(
                        TranscriptionResult(
                            requestID: requestID,
                            engine: .apple,
                            text: appleResult.text,
                            latency: Date().timeIntervalSince(started),
                            audioDuration: duration,
                            detectedLanguage: appleResult.language
                        )
                    ))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureWorker(for: engine)
                self.pending[requestID] = completion

                let payload: [String: Any] = [
                    "id": requestID,
                    "audio": audioURL.path,
                    "duration": duration,
                    "prompt": prompt
                ]
                var data = try JSONSerialization.data(withJSONObject: payload)
                data.append(0x0A)
                try self.inputHandle?.write(contentsOf: data)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func prewarm(engine: ASREngine) {
        if engine == .apple {
            onWorkerEvent?("Подготавливаю русскую модель Apple…")
            appleSpeechService.prepare { [weak self] result in
                switch result {
                case .success:
                    self?.onWorkerEvent?("Apple SpeechAnalyzer готов.")
                case .failure(let error):
                    self?.onWorkerEvent?(error.localizedDescription)
                }
            }
            return
        }

        queue.async { [weak self] in
            do {
                try self?.ensureWorker(for: engine)
            } catch {
                self?.emit("Ошибка запуска: \(error.localizedDescription)")
            }
        }
    }

    func switchEngine(to engine: ASREngine) {
        if engine != .apple {
            appleSpeechService.shutdown()
        }
        queue.async { [weak self] in
            guard let self, self.currentEngine != engine else { return }
            self.stopWorker(reason: "Модель переключена.")
        }
    }

    func shutdown() {
        appleSpeechService.shutdown()
        queue.sync {
            stopWorker(reason: "Приложение завершено.")
        }
    }

    private func ensureWorker(for engine: ASREngine) throws {
        guard engine != .apple else {
            throw VoiceSwitchError.workerFailed(
                "Apple SpeechAnalyzer не использует Python worker."
            )
        }
        if let component = engine.runtimeComponent,
           !RuntimePaths.isInstalled(component) {
            throw VoiceSwitchError.runtimeMissing(
                "Модель \(component.title) ещё не установлена. Выберите её в меню VoiceSwitch."
            )
        }
        if let process, process.isRunning, currentEngine == engine {
            return
        }

        stopWorker(reason: "Перезапуск движка.")

        let python = RuntimePaths.pythonExecutable
        let worker = RuntimePaths.workerScript
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw VoiceSwitchError.runtimeMissing(
                "Локальные модели не установлены. Откройте меню VoiceSwitch и нажмите «Установить модели»."
            )
        }
        guard FileManager.default.fileExists(atPath: worker.path) else {
            throw VoiceSwitchError.runtimeMissing(
                "Не найден Python‑модуль распознавания: \(worker.path)"
            )
        }

        try FileManager.default.createDirectory(
            at: RuntimePaths.modelCache,
            withIntermediateDirectories: true
        )

        let newProcess = Process()
        let newInput = Pipe()
        let newOutput = Pipe()
        newProcess.executableURL = python
        newProcess.arguments = [
            worker.path,
            "--serve",
            "--engine", engine.rawValue,
            "--cache", RuntimePaths.modelCache.path
        ]
        newProcess.standardInput = newInput
        newProcess.standardOutput = newOutput
        newProcess.standardError = newOutput

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HOME"] = RuntimePaths.modelCache
            .appendingPathComponent("huggingface", isDirectory: true).path
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["PYTHONPATH"] = RuntimePaths.pythonPackages.path
        newProcess.environment = environment

        newOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consume(data)
            }
        }

        newProcess.terminationHandler = { [weak self, weak newProcess] terminated in
            self?.queue.async {
                guard let self, self.process === newProcess else { return }
                let message = "Движок остановлен (код \(terminated.terminationStatus))."
                self.failAllPending(with: VoiceSwitchError.workerFailed(message))
                self.clearWorkerReferences()
                self.emit(message)
            }
        }

        emit("Загрузка \(engine.shortTitle)…")
        try newProcess.run()
        process = newProcess
        inputHandle = newInput.fileHandleForWriting
        outputPipe = newOutput
        currentEngine = engine
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8) else {
                continue
            }
            handleLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func handleLine(_ line: String) {
        let marker = "__VOICESWITCH_JSON__"
        guard line.hasPrefix(marker) else {
            if !line.isEmpty {
                NSLog("VoiceSwitch worker: \(line)")
            }
            return
        }

        let jsonText = String(line.dropFirst(marker.count))
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            emit("Некорректный ответ движка.")
            return
        }

        switch type {
        case "ready":
            let engine = (json["engine"] as? String)
                .flatMap(ASREngine.init(rawValue:))
            emit("\(engine?.shortTitle ?? "Модель") готова.")
        case "loading":
            emit(json["message"] as? String ?? "Загрузка модели…")
        case "result":
            handleResult(json)
        case "error":
            handleError(json)
        default:
            if let message = json["message"] as? String {
                emit(message)
            }
        }
    }

    private func handleResult(_ json: [String: Any]) {
        guard let id = json["id"] as? String,
              let engineName = json["engine"] as? String,
              let engine = ASREngine(rawValue: engineName),
              let text = json["text"] as? String,
              let latency = json["latency"] as? Double,
              let duration = json["duration"] as? Double else {
            return
        }

        let result = TranscriptionResult(
            requestID: id,
            engine: engine,
            text: text,
            latency: latency,
            audioDuration: duration,
            detectedLanguage: json["language"] as? String
        )
        guard let completion = pending.removeValue(forKey: id) else { return }
        DispatchQueue.main.async {
            completion(.success(result))
        }
    }

    private func handleError(_ json: [String: Any]) {
        guard let id = json["id"] as? String,
              let completion = pending.removeValue(forKey: id) else {
            emit(json["message"] as? String ?? "Ошибка движка.")
            return
        }
        let message = json["message"] as? String ?? "Неизвестная ошибка движка."
        DispatchQueue.main.async {
            completion(.failure(VoiceSwitchError.workerFailed(message)))
        }
    }

    private func stopWorker(reason: String) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        failAllPending(with: VoiceSwitchError.workerFailed(reason))
        clearWorkerReferences()
    }

    private func clearWorkerReferences() {
        try? inputHandle?.close()
        process = nil
        inputHandle = nil
        outputPipe = nil
        currentEngine = nil
        outputBuffer.removeAll(keepingCapacity: true)
    }

    private func failAllPending(with error: Error) {
        let completions = pending.values
        pending.removeAll()
        for completion in completions {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
        }
    }

    private func emit(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onWorkerEvent?(message)
        }
    }

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
    }
}
