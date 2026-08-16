import Foundation

final class RuntimeInstaller {
    typealias StatusHandler = (String) -> Void
    typealias Completion = (Result<Void, Error>) -> Void

    private let queue = DispatchQueue(label: "VoiceSwitch.RuntimeInstaller")
    private var process: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var reportedFailure: String?
    private var recentDiagnostics: [String] = []
    private var wasCancelled = false

    private let statusMarker = "__VOICESWITCH_SETUP__"
    private let errorMarker = "__VOICESWITCH_SETUP_ERROR__"
    private let maximumDiagnosticLines = 16

    var isRunning: Bool {
        queue.sync {
            process?.isRunning == true
        }
    }

    func install(
        components: Set<RuntimeComponent>,
        status: @escaping StatusHandler,
        completion: @escaping Completion
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.process?.isRunning != true else { return }
            guard !components.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure(
                        VoiceSwitchError.runtimeMissing(
                            "Выберите хотя бы одну локальную модель."
                        )
                    ))
                }
                return
            }

            self.outputBuffer.removeAll()
            self.reportedFailure = nil
            self.recentDiagnostics.removeAll()
            self.wasCancelled = false

            do {
                guard let installer = RuntimePaths.installerScript else {
                    throw VoiceSwitchError.runtimeMissing(
                        "В приложении отсутствует установщик Runtime."
                    )
                }

                try FileManager.default.createDirectory(
                    at: RuntimePaths.runtimeRoot,
                    withIntermediateDirectories: true
                )

                let newProcess = Process()
                let newOutput = Pipe()
                newProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
                newProcess.arguments = [
                    installer.path,
                    RuntimePaths.runtimeRoot.path,
                    RuntimePaths.workerScript.path,
                    RuntimePaths.textWorkerScript.path,
                    components
                        .map(\.rawValue)
                        .sorted()
                        .joined(separator: ",")
                ]
                newProcess.standardOutput = newOutput
                newProcess.standardError = newOutput

                var environment = ProcessInfo.processInfo.environment
                environment["PYTHONUNBUFFERED"] = "1"
                environment["NO_COLOR"] = "1"
                newProcess.environment = environment

                newOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    self?.queue.async {
                        self?.consume(data, status: status)
                    }
                }

                newProcess.terminationHandler = { [weak self] terminated in
                    guard let self else { return }
                    self.queue.async {
                        self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                        let tail = self.outputBuffer
                        self.outputBuffer.removeAll()
                        self.process = nil
                        self.outputPipe = nil

                        if !tail.isEmpty {
                            self.consume(tail + Data([0x0A]), status: status)
                        }

                        let failureMessage = self.failureMessage(
                            terminationStatus: terminated.terminationStatus
                        )

                        DispatchQueue.main.async {
                            let allRequestedComponentsReady = components.allSatisfy {
                                RuntimePaths.isInstalled($0)
                            }
                            if terminated.terminationStatus == 0,
                               RuntimePaths.isRuntimeReady,
                               allRequestedComponentsReady {
                                completion(.success(()))
                            } else {
                                completion(.failure(
                                    VoiceSwitchError.runtimeMissing(
                                        failureMessage
                                    )
                                ))
                            }
                        }
                    }
                }

                try newProcess.run()
                self.process = newProcess
                self.outputPipe = newOutput
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, let process = self.process, process.isRunning else { return }
            self.wasCancelled = true
            process.terminate()
        }
    }

    private func consume(_ data: Data, status: @escaping StatusHandler) {
        outputBuffer.append(data)

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(statusMarker) {
                let message = String(trimmed.dropFirst(statusMarker.count))
                DispatchQueue.main.async {
                    status(message)
                }
            } else if trimmed.hasPrefix(errorMarker) {
                let message = String(trimmed.dropFirst(errorMarker.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty {
                    reportedFailure = message
                }
            } else if !trimmed.isEmpty {
                let diagnostic = trimmed
                    .replacingOccurrences(
                        of: "\\u{001B}\\[[0-9;]*[A-Za-z]",
                        with: "",
                        options: .regularExpression
                    )
                recentDiagnostics.append(diagnostic)
                if recentDiagnostics.count > maximumDiagnosticLines {
                    recentDiagnostics.removeFirst(
                        recentDiagnostics.count - maximumDiagnosticLines
                    )
                }
                NSLog("VoiceSwitch setup: \(trimmed)")
            }
        }
    }

    private func failureMessage(terminationStatus: Int32) -> String {
        if wasCancelled {
            return "Установка остановлена. Нажмите «Продолжить установку»: уже загруженные файлы сохранятся."
        }

        let primary = reportedFailure
            ?? "Установка завершилась с кодом \(terminationStatus)."
        guard let detail = recentDiagnostics.reversed().first(where: isUsefulDiagnostic) else {
            return primary
        }

        let shortened = detail.count > 260
            ? String(detail.prefix(260)) + "…"
            : detail
        if primary.localizedCaseInsensitiveContains(shortened) {
            return primary
        }
        return "\(primary)\nПричина: \(shortened)"
    }

    private func isUsefulDiagnostic(_ line: String) -> Bool {
        let normalized = line.lowercased()
        let ignoredFragments = [
            "downloading", "resolving", "prepared", "installed",
            "audited", "using python", "__voiceswitch_json__",
            "сбой на этапе"
        ]
        return !ignoredFragments.contains(where: normalized.contains)
            && !normalized.isEmpty
    }

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
    }
}
