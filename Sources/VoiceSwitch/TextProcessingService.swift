import Foundation

final class TextProcessingService {
    typealias Completion = (Result<TextProcessingResult, Error>) -> Void

    private let queue = DispatchQueue(label: "VoiceSwitch.TextProcessingService")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var pending: [String: Completion] = [:]

    var onWorkerEvent: ((String) -> Void)?

    func process(
        text: String,
        mode: TextProcessingMode,
        completion: @escaping Completion
    ) {
        let requestID = UUID().uuidString
        guard mode.usesLocalModel else {
            completion(.success(
                TextProcessingResult(
                    requestID: requestID,
                    mode: .verbatim,
                    text: text,
                    latency: 0
                )
            ))
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureWorker()
                self.pending[requestID] = completion

                let payload: [String: Any] = [
                    "id": requestID,
                    "mode": mode.rawValue,
                    "text": text
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

    func prewarm() {
        queue.async { [weak self] in
            do {
                try self?.ensureWorker()
            } catch {
                self?.emit("Ошибка редактора: \(error.localizedDescription)")
            }
        }
    }

    func shutdown() {
        queue.sync {
            stopWorker(reason: "Локальный редактор остановлен.")
        }
    }

    private func ensureWorker() throws {
        if let process, process.isRunning {
            return
        }

        stopWorker(reason: "Перезапуск локального редактора.")

        let python = RuntimePaths.pythonExecutable
        let worker = RuntimePaths.textWorkerScript
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw VoiceSwitchError.runtimeMissing(
                "Локальные модели не установлены. Откройте меню VoiceSwitch и нажмите «Установить модели»."
            )
        }
        guard FileManager.default.fileExists(atPath: worker.path) else {
            throw VoiceSwitchError.runtimeMissing(
                "Не найден модуль локального редактора: \(worker.path)"
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
                let message = "Редактор остановлен (код \(terminated.terminationStatus))."
                self.failAllPending(with: VoiceSwitchError.workerFailed(message))
                self.clearWorkerReferences()
                self.emit(message)
            }
        }

        emit("Загружаю локальный редактор Qwen3-4B…")
        try newProcess.run()
        process = newProcess
        inputHandle = newInput.fileHandleForWriting
        outputPipe = newOutput
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
                NSLog("VoiceSwitch text worker: \(line)")
            }
            return
        }

        let jsonText = String(line.dropFirst(marker.count))
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            emit("Некорректный ответ локального редактора.")
            return
        }

        switch type {
        case "ready":
            emit("Локальный редактор Qwen3-4B готов.")
        case "loading":
            emit(json["message"] as? String ?? "Загрузка редактора…")
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
              let modeName = json["mode"] as? String,
              let mode = TextProcessingMode(rawValue: modeName),
              let text = json["text"] as? String,
              let latency = json["latency"] as? Double,
              let completion = pending.removeValue(forKey: id) else {
            return
        }

        let result = TextProcessingResult(
            requestID: id,
            mode: mode,
            text: text,
            latency: latency
        )
        DispatchQueue.main.async {
            completion(.success(result))
        }
    }

    private func handleError(_ json: [String: Any]) {
        guard let id = json["id"] as? String,
              let completion = pending.removeValue(forKey: id) else {
            emit(json["message"] as? String ?? "Ошибка локального редактора.")
            return
        }
        let message = json["message"] as? String ?? "Неизвестная ошибка редактора."
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
