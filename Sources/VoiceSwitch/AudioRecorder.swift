import AVFoundation
import Foundation

final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func start() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceswitch-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.delegate = self
            newRecorder.isMeteringEnabled = true
            guard newRecorder.prepareToRecord(), newRecorder.record() else {
                throw VoiceSwitchError.recordingFailed("AVAudioRecorder не начал запись.")
            }
            recorder = newRecorder
            currentURL = url
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() -> (url: URL, duration: Double)? {
        guard let recorder, let url = currentURL else {
            return nil
        }

        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.currentURL = nil
        return (url, duration)
    }

    func cancel() {
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        self.currentURL = nil
        try? FileManager.default.removeItem(at: url)
    }
}
