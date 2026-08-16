import Foundation

enum ComparisonLogger {
    static func append(
        result: TranscriptionResult,
        source: String,
        prompt: String
    ) {
        let url = RuntimePaths.logFile
        let directory = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let formatter = ISO8601DateFormatter()
            let record: [String: Any] = [
                "timestamp": formatter.string(from: Date()),
                "type": "transcription",
                "request_id": result.requestID,
                "engine": result.engine.rawValue,
                "engine_name": result.engine.title,
                "audio_duration_seconds": result.audioDuration,
                "latency_seconds": result.latency,
                "realtime_factor": result.audioDuration > 0
                    ? result.latency / result.audioDuration
                    : 0,
                "detected_language": result.detectedLanguage ?? "",
                "source": source,
                "prompt": prompt,
                "text": result.text
            ]

            var data = try JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys]
            )
            data.append(0x0A)

            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("VoiceSwitch log error: \(error.localizedDescription)")
        }
    }

    static func appendEvaluation(
        requestID: String,
        engine: ASREngine,
        textMode: TextProcessingMode,
        rating: String
    ) {
        let formatter = ISO8601DateFormatter()
        let record: [String: Any] = [
            "timestamp": formatter.string(from: Date()),
            "type": "evaluation",
            "request_id": requestID,
            "engine": engine.rawValue,
            "text_mode": textMode.rawValue,
            "rating": rating
        ]
        appendRaw(record)
    }

    static func appendPostProcessing(
        requestID: String,
        mode: TextProcessingMode,
        sourceText: String,
        outputText: String,
        latency: Double
    ) {
        let formatter = ISO8601DateFormatter()
        let record: [String: Any] = [
            "timestamp": formatter.string(from: Date()),
            "type": "text_processing",
            "request_id": requestID,
            "text_mode": mode.rawValue,
            "model": "Qwen/Qwen3-4B-MLX-4bit",
            "latency_seconds": latency,
            "source_text": sourceText,
            "output_text": outputText
        ]
        appendRaw(record)
    }

    static func appendInjection(
        targetPID: pid_t?,
        targetName: String,
        frontmostPID: pid_t?,
        method: String,
        result: String,
        focusedRole: String,
        errorCode: Int32
    ) {
        let formatter = ISO8601DateFormatter()
        let record: [String: Any] = [
            "timestamp": formatter.string(from: Date()),
            "type": "text_injection",
            "target_pid": targetPID ?? 0,
            "target_name": targetName,
            "frontmost_pid": frontmostPID ?? 0,
            "method": method,
            "result": result,
            "focused_role": focusedRole,
            "ax_error_code": errorCode
        ]
        appendRaw(record)
    }

    static func appendDelivery(
        autoPaste: Bool,
        accessibilityAuthorized: Bool,
        pasteTarget: pid_t?,
        frontmostPID: pid_t?
    ) {
        let formatter = ISO8601DateFormatter()
        let record: [String: Any] = [
            "timestamp": formatter.string(from: Date()),
            "type": "text_delivery",
            "auto_paste": autoPaste,
            "accessibility_authorized": accessibilityAuthorized,
            "paste_target_pid": Int(pasteTarget ?? 0),
            "frontmost_pid": Int(frontmostPID ?? 0)
        ]
        appendRaw(record)
    }

    private static func appendRaw(_ record: [String: Any]) {
        let url = RuntimePaths.logFile
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var data = try JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys]
            )
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("VoiceSwitch evaluation log error: \(error.localizedDescription)")
        }
    }
}
