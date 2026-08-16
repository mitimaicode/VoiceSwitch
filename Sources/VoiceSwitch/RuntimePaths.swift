import Foundation

enum RuntimePaths {
    static let expectedRuntimeVersion = 4

    static var distributionRoot: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
    }

    static var applicationSupportRoot: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("VoiceSwitch", isDirectory: true)
    }

    static var runtimeRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["VOICESWITCH_RUNTIME"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }

        let legacyDistribution = distributionRoot
            .appendingPathComponent("Runtime", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyDistribution.path) {
            return legacyDistribution
        }

        return applicationSupportRoot.appendingPathComponent("Runtime", isDirectory: true)
    }

    static var pythonExecutable: URL {
        if let custom = ProcessInfo.processInfo.environment["VOICESWITCH_PYTHON"] {
            return URL(fileURLWithPath: custom)
        }

        let virtualEnvironment = runtimeRoot
            .appendingPathComponent("venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3")
        if FileManager.default.isExecutableFile(atPath: virtualEnvironment.path) {
            return virtualEnvironment
        }

        return runtimeRoot
            .appendingPathComponent("Python", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3")
    }

    static var pythonPackages: URL {
        runtimeRoot
            .appendingPathComponent("venv", isDirectory: true)
            .appendingPathComponent("lib", isDirectory: true)
            .appendingPathComponent("python3.12", isDirectory: true)
            .appendingPathComponent("site-packages", isDirectory: true)
    }

    static var workerScript: URL {
        if let custom = ProcessInfo.processInfo.environment["VOICESWITCH_WORKER"] {
            return URL(fileURLWithPath: custom)
        }

        if let bundled = Bundle.main.url(forResource: "asr_worker", withExtension: "py") {
            return bundled
        }

        return applicationSupportRoot.appendingPathComponent("asr_worker.py")
    }

    static var textWorkerScript: URL {
        if let custom = ProcessInfo.processInfo.environment["VOICESWITCH_TEXT_WORKER"] {
            return URL(fileURLWithPath: custom)
        }

        if let bundled = Bundle.main.url(forResource: "text_worker", withExtension: "py") {
            return bundled
        }

        return applicationSupportRoot.appendingPathComponent("text_worker.py")
    }

    static var installerScript: URL? {
        Bundle.main.url(forResource: "install_runtime", withExtension: "sh")
    }

    static var isRuntimeReady: Bool {
        guard FileManager.default.isExecutableFile(atPath: pythonExecutable.path),
              let marker = installMarkerContents else {
            return false
        }
        return marker.contains("runtime_version=\(expectedRuntimeVersion)")
    }

    static var installedComponents: Set<RuntimeComponent> {
        guard isRuntimeReady, let marker = installMarkerContents else {
            return []
        }

        let explicitComponents = Set(
            marker
                .split(separator: "\n")
                .compactMap { line -> RuntimeComponent? in
                    let prefix = "component="
                    guard line.hasPrefix(prefix) else { return nil }
                    return RuntimeComponent(rawValue: String(line.dropFirst(prefix.count)))
                }
        )

        if marker.contains("selective_install=1") {
            return explicitComponents.union(componentMarkerComponents)
        }

        // Runtime v4 до выборочной установки всегда загружал все четыре модели.
        // Считаем его полным, чтобы обновление приложения не заставляло людей
        // повторно скачивать уже существующие веса.
        return Set(RuntimeComponent.allCases)
    }

    static func isInstalled(_ component: RuntimeComponent) -> Bool {
        installedComponents.contains(component)
    }

    static var installMarker: URL {
        runtimeRoot.appendingPathComponent("install-complete.txt")
    }

    static var componentMarkersRoot: URL {
        runtimeRoot.appendingPathComponent("components", isDirectory: true)
    }

    static func componentMarker(_ component: RuntimeComponent) -> URL {
        componentMarkersRoot.appendingPathComponent("\(component.rawValue).ready")
    }

    private static var installMarkerContents: String? {
        try? String(contentsOf: installMarker, encoding: .utf8)
    }

    private static var componentMarkerComponents: Set<RuntimeComponent> {
        Set(
            RuntimeComponent.allCases.filter {
                FileManager.default.fileExists(atPath: componentMarker($0).path)
            }
        )
    }

    static var modelCache: URL {
        runtimeRoot.appendingPathComponent("Models", isDirectory: true)
    }

    static var logFile: URL {
        applicationSupportRoot
            .appendingPathComponent("comparison.jsonl")
    }

    static var installLogFile: URL {
        runtimeRoot.appendingPathComponent("install.log")
    }
}
