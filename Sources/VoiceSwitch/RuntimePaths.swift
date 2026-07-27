import Foundation

enum RuntimePaths {
    static let expectedRuntimeVersion = 2

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

    static var installerScript: URL? {
        Bundle.main.url(forResource: "install_runtime", withExtension: "sh")
    }

    static var isRuntimeReady: Bool {
        guard FileManager.default.isExecutableFile(atPath: pythonExecutable.path),
              let marker = try? String(
                contentsOf: runtimeRoot.appendingPathComponent("install-complete.txt"),
                encoding: .utf8
              ) else {
            return false
        }
        return marker.contains("runtime_version=\(expectedRuntimeVersion)")
    }

    static var modelCache: URL {
        runtimeRoot.appendingPathComponent("Models", isDirectory: true)
    }

    static var logFile: URL {
        applicationSupportRoot
            .appendingPathComponent("comparison.jsonl")
    }
}
