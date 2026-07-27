import Foundation

final class RuntimeInstaller {
    typealias StatusHandler = (String) -> Void
    typealias Completion = (Result<Void, Error>) -> Void

    private let queue = DispatchQueue(label: "VoiceSwitch.RuntimeInstaller")
    private var process: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()

    var isRunning: Bool {
        queue.sync {
            process?.isRunning == true
        }
    }

    func install(
        status: @escaping StatusHandler,
        completion: @escaping Completion
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.process?.isRunning != true else { return }

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
                    RuntimePaths.workerScript.path
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

                        DispatchQueue.main.async {
                            if terminated.terminationStatus == 0,
                               RuntimePaths.isRuntimeReady {
                                completion(.success(()))
                            } else {
                                completion(.failure(
                                    VoiceSwitchError.runtimeMissing(
                                        "Установка завершилась с кодом \(terminated.terminationStatus)."
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
            let marker = "__VOICESWITCH_SETUP__"
            if trimmed.hasPrefix(marker) {
                let message = String(trimmed.dropFirst(marker.count))
                DispatchQueue.main.async {
                    status(message)
                }
            } else if !trimmed.isEmpty {
                NSLog("VoiceSwitch setup: \(trimmed)")
            }
        }
    }

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
    }
}
