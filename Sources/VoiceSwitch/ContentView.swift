import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !state.runtimeReady || state.isInstallingRuntime {
                runtimeSetupSection
            }
            enginePicker
            recordSection
            resultSection
            settingsSection
            footer
        }
        .padding(16)
        .frame(width: 410)
        .onAppear {
            state.refreshPermissions()
        }
    }

    private var runtimeSetupSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: state.isInstallingRuntime ? "arrow.down.circle" : "externaldrive.badge.plus")
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Установка локальных моделей")
                        .font(.subheadline.weight(.semibold))
                    Text("Python, GigaAM и Whisper · около 4 ГБ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if state.isInstallingRuntime {
                ProgressView()
                    .controlSize(.small)
                Text(state.runtimeInstallStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Button("Остановить") {
                    state.cancelRuntimeInstallation()
                }
                .controlSize(.small)
            } else {
                Text("Данные речи остаются на Mac. Компоненты загружаются из официальных репозиториев Astral, Hugging Face, PyPI и GigaAM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Установить модели") {
                        state.installRuntime()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    Button("Папка Runtime") {
                        state.openRuntimeFolder()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(11)
        .background(Color.indigo.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [.indigo, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                Image(systemName: "waveform")
                    .foregroundStyle(.white)
                    .font(.system(size: 18, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("VoiceSwitch")
                    .font(.headline)
                Text("Локальная диктовка · две модели")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Модель распознавания")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Модель", selection: $state.selectedEngine) {
                ForEach(ASREngine.allCases) { engine in
                    Text(engine.shortTitle).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            Text(state.selectedEngine.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordSection: some View {
        VStack(spacing: 9) {
            Button(action: state.toggleRecording) {
                HStack {
                    Image(systemName: state.isRecording ? "stop.fill" : "mic.fill")
                    Text(state.isRecording ? "Остановить запись" : "Начать запись")
                    Spacer()
                    Text("fn + ⌥")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(state.isRecording ? .red : .indigo)
            .disabled(state.isTranscribing || !state.runtimeReady || state.isInstallingRuntime)

            HStack(spacing: 7) {
                if state.isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Circle()
                        .fill(state.isRecording ? Color.red : Color.green)
                        .frame(width: 7, height: 7)
                }
                Text(state.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if !state.lastText.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Последний результат")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(state.lastMetrics)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ScrollView {
                    Text(state.lastText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 115)
                .padding(9)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Text("Оценка:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Точно") {
                        state.rateLastResult("accurate")
                    }
                    Button("Есть ошибки") {
                        state.rateLastResult("errors")
                    }
                    Spacer()
                    if state.lastRating != nil {
                        Label("Сохранено", systemImage: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                .controlSize(.mini)
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()

            Toggle("Автоматически вставлять текст в активное приложение", isOn: $state.autoPaste)
                .font(.caption)

            if state.selectedEngine == .whisper {
                TextField(
                    "Контекст для Whisper: имена, термины, продукты…",
                    text: $state.whisperPrompt
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 3) {
                Label(state.microphoneStatus, systemImage: "mic")
                Label(
                    state.accessibilityStatus,
                    systemImage: state.accessibilityAuthorized ? "checkmark.shield" : "exclamationmark.shield"
                )
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack {
                Button("Подготовить модель") {
                    state.prewarmSelectedEngine()
                }
                .disabled(!state.runtimeReady || state.isInstallingRuntime)
                Button("Разрешить доступ") {
                    state.requestAccessibility()
                }
                Spacer()
                Button("Журнал тестов") {
                    state.openLogFolder()
                }
            }
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack {
            Text("fn + ⌥ — начать или остановить запись")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Выход") {
                state.quit()
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
    }
}
