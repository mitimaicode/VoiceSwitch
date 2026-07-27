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
        rating: String
    ) {
        let formatter = ISO8601DateFormatter()
        let record: [String: Any] = [
            "timestamp": formatter.string(from: Date()),
            "type": "evaluation",
            "request_id": requestID,
            "engine": engine.rawValue,
            "rating": rating
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
