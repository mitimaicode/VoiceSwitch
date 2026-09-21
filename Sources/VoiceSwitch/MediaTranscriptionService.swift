import Darwin
import Foundation

final class MediaTranscriptionService {
    typealias Completion = (Result<MediaTranscriptionResult, Error>) -> Void

    private let queue = DispatchQueue(label: "VoiceSwitch.MediaTranscriptionService")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var completion: Completion?
    private var pendingTerminalResult: Result<MediaTranscriptionResult, Error>?
    private var activeEngine: ASREngine?
    private var activeRequestID: String?
    private var activeGeneration: UUID?
    private var activeOutputDirectory: URL?
    private var cancellationRequested = false
    private var outputReachedEOF = false
    private var terminationStatus: Int32?

    var onProgress: ((MediaProgress) -> Void)?

    func transcribe(
        sourceURL: URL,
        outputDirectory: URL,
        engine: ASREngine,
        prompt: String,
        completion: @escaping Completion
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.completion == nil else {
                self.completeOnMain(
                    completion,
                    with: .failure(
                        VoiceSwitchError.workerFailed(
                            "Уже выполняется расшифровка другого файла."
                        )
                    )
                )
                return
            }

            do {
                try self.start(
                    sourceURL: sourceURL,
                    outputDirectory: outputDirectory,
                    engine: engine,
                    prompt: prompt,
                    completion: completion
                )
            } catch {
                if let process = self.process, process.isRunning {
                    process.terminate()
                    if process.isRunning {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL)
                        process.waitUntilExit()
                    }
                }
                self.removeActiveWorkDirectory()
                self.completion = nil
                self.clearProcessReferences()
                self.completeOnMain(completion, with: .failure(error))
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, self.completion != nil else { return }
            self.cancellationRequested = true
            if let process = self.process, process.isRunning {
                process.terminate()
                self.queue.asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }

    func shutdown() {
        queue.sync {
            guard completion != nil else { return }
            cancellationRequested = true
            if let process, process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(0.25)
                while process.isRunning, Date() < deadline {
                    usleep(20_000)
                }
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }
            removeActiveWorkDirectory()
            finish(.failure(VoiceSwitchError.mediaCancelled))
        }
    }

    private func start(
        sourceURL: URL,
        outputDirectory: URL,
        engine: ASREngine,
        prompt: String,
        completion: @escaping Completion
    ) throws {
        guard engine != .apple else {
            throw VoiceSwitchError.unsupportedMedia(
                "Apple SpeechAnalyzer пока доступен только для диктовки."
            )
        }
        if let component = engine.runtimeComponent,
           !RuntimePaths.isInstalled(component) {
            throw VoiceSwitchError.runtimeMissing(
                "Модель \(component.title) ещё не установлена."
            )
        }

        let python = RuntimePaths.pythonExecutable
        let worker = RuntimePaths.mediaWorkerScript
        let ffmpeg = RuntimePaths.ffmpegExecutable
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw VoiceSwitchError.runtimeMissing(
                "Локальное Python-окружение не установлено."
            )
        }
        guard FileManager.default.fileExists(atPath: worker.path) else {
            throw VoiceSwitchError.runtimeMissing(
                "Не найден модуль расшифровки файлов: \(worker.path)"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
            throw VoiceSwitchError.runtimeMissing(
                "Локальный ffmpeg не установлен. Продолжите установку моделей."
            )
        }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw VoiceSwitchError.unsupportedMedia("файл недоступен для чтения.")
        }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let requestID = UUID().uuidString
        let generation = UUID()
        let newProcess = Process()
        let newInput = Pipe()
        let newOutput = Pipe()
        newProcess.executableURL = python
        newProcess.arguments = [worker.path]
        newProcess.standardInput = newInput
        newProcess.standardOutput = newOutput
        newProcess.standardError = newOutput

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HOME"] = RuntimePaths.modelCache
            .appendingPathComponent("huggingface", isDirectory: true).path
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["PYTHONPATH"] = RuntimePaths.pythonPackages.path
        let runtimeBin = RuntimePaths.runtimeRoot
            .appendingPathComponent("bin", isDirectory: true).path
        environment["PATH"] = "\(runtimeBin):\(environment["PATH"] ?? "/usr/bin:/bin")"
        newProcess.environment = environment

        newOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async {
                guard let self,
                      self.activeGeneration == generation else {
                    return
                }
                if data.isEmpty {
                    self.consumeBufferedTail()
                    self.outputReachedEOF = true
                    self.finishTerminatedProcessIfReady()
                } else {
                    self.consume(data)
                }
            }
        }

        newProcess.terminationHandler = { [weak self, weak newProcess] terminated in
            self?.queue.async {
                guard let self,
                      self.process === newProcess else {
                    return
                }
                self.terminationStatus = terminated.terminationStatus
                self.finishTerminatedProcessIfReady()
            }
        }

        self.completion = completion
        activeEngine = engine
        activeRequestID = requestID
        activeGeneration = generation
        activeOutputDirectory = outputDirectory
        cancellationRequested = false
        outputReachedEOF = false
        terminationStatus = nil
        pendingTerminalResult = nil
        outputBuffer.removeAll(keepingCapacity: true)

        try newProcess.run()
        process = newProcess
        inputHandle = newInput.fileHandleForWriting
        outputPipe = newOutput

        let payload: [String: Any] = [
            "id": requestID,
            "input": sourceURL.path,
            "output_dir": outputDirectory.path,
            "cache": RuntimePaths.modelCache.path,
            "engine": engine.rawValue,
            "prompt": prompt,
            "chunk_seconds": 60.0,
            "overlap_seconds": 1.5
        ]
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try inputHandle?.write(contentsOf: data)
        try inputHandle?.close()
        inputHandle = nil
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

    private func consumeBufferedTail() {
        guard !outputBuffer.isEmpty else { return }
        guard let line = String(data: outputBuffer, encoding: .utf8) else {
            outputBuffer.removeAll(keepingCapacity: true)
            return
        }
        outputBuffer.removeAll(keepingCapacity: true)
        handleLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func handleLine(_ line: String) {
        let marker = "__VOICESWITCH_JSON__"
        guard line.hasPrefix(marker) else {
            if !line.isEmpty {
                NSLog("VoiceSwitch media worker: \(line)")
            }
            return
        }

        let jsonText = String(line.dropFirst(marker.count))
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "phase", "progress":
            handleProgress(json)
        case "result":
            handleResult(json)
        case "error":
            handleError(json)
        default:
            break
        }
    }

    private func handleProgress(_ json: [String: Any]) {
        let phase = (json["phase"] as? String)
            .flatMap(MediaJobPhase.init(rawValue:)) ?? .preparing
        let completed = (json["completed"] as? NSNumber)?.intValue ?? 0
        let total = (json["total"] as? NSNumber)?.intValue ?? 0
        let fraction = (json["fraction"] as? NSNumber)?.doubleValue
        let progress = MediaProgress(
            phase: phase,
            message: json["message"] as? String ?? phase.title,
            completedChunks: completed,
            totalChunks: total,
            fraction: fraction
        )
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(progress)
        }
    }

    private func handleResult(_ json: [String: Any]) {
        guard let requestID = json["id"] as? String,
              requestID == activeRequestID,
              let engine = activeEngine,
              let text = json["text"] as? String,
              let duration = (json["duration"] as? NSNumber)?.doubleValue,
              let latency = (json["latency"] as? NSNumber)?.doubleValue,
              let outputPath = json["output_dir"] as? String else {
            pendingTerminalResult = .failure(VoiceSwitchError.invalidResponse)
            finishTerminatedProcessIfReady()
            return
        }

        let rawFiles = json["files"] as? [String: String] ?? [:]
        let files = rawFiles.mapValues { URL(fileURLWithPath: $0) }
        let result = MediaTranscriptionResult(
            requestID: requestID,
            engine: engine,
            sourceName: json["source_name"] as? String ?? "Медиафайл",
            text: text,
            latency: latency,
            mediaDuration: duration,
            segmentCount: (json["segment_count"] as? NSNumber)?.intValue ?? 0,
            outputDirectory: URL(fileURLWithPath: outputPath, isDirectory: true),
            files: files
        )
        pendingTerminalResult = .success(result)
        finishTerminatedProcessIfReady()
    }

    private func handleError(_ json: [String: Any]) {
        let message = json["message"] as? String ?? "Неизвестная ошибка обработки файла."
        switch json["code"] as? String {
        case "cancelled":
            pendingTerminalResult = .failure(VoiceSwitchError.mediaCancelled)
        case "no_audio":
            pendingTerminalResult = .failure(VoiceSwitchError.noAudio)
        case "unsupported_media":
            pendingTerminalResult = .failure(VoiceSwitchError.unsupportedMedia(message))
        default:
            pendingTerminalResult = .failure(VoiceSwitchError.workerFailed(message))
        }
        finishTerminatedProcessIfReady()
    }

    private func finishTerminatedProcessIfReady() {
        guard completion != nil,
              outputReachedEOF,
              let terminationStatus else {
            return
        }
        removeActiveWorkDirectory()

        if cancellationRequested {
            finish(.failure(VoiceSwitchError.mediaCancelled))
        } else if let pendingTerminalResult {
            if case .success(_) = pendingTerminalResult, terminationStatus != 0 {
                finish(
                    .failure(
                        VoiceSwitchError.workerFailed(
                            "Worker вернул результат, но завершился с кодом \(terminationStatus)."
                        )
                    )
                )
            } else {
                finish(pendingTerminalResult)
            }
        } else {
            finish(
                .failure(
                    VoiceSwitchError.workerFailed(
                        "Обработка файла остановилась до результата (код \(terminationStatus))."
                    )
                )
            )
        }
    }

    private func finish(_ result: Result<MediaTranscriptionResult, Error>) {
        guard let completion else { return }
        self.completion = nil
        clearProcessReferences()
        completeOnMain(completion, with: result)
    }

    private func completeOnMain(
        _ completion: @escaping Completion,
        with result: Result<MediaTranscriptionResult, Error>
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func clearProcessReferences() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputHandle?.close()
        process = nil
        inputHandle = nil
        outputPipe = nil
        activeEngine = nil
        activeRequestID = nil
        activeGeneration = nil
        activeOutputDirectory = nil
        pendingTerminalResult = nil
        outputReachedEOF = false
        terminationStatus = nil
        outputBuffer.removeAll(keepingCapacity: true)
    }

    private func removeActiveWorkDirectory() {
        guard let activeOutputDirectory else { return }
        let workDirectory = activeOutputDirectory
            .appendingPathComponent(".work", isDirectory: true)
        try? FileManager.default.removeItem(at: workDirectory)
    }

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        removeActiveWorkDirectory()
    }
}
