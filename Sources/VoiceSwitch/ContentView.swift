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
            textModePicker
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
                    Text("Распознавание и Qwen3-4B для редактуры · около 12 ГБ")
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
                if let installError = state.runtimeInstallError {
                    Text(installError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(6)
                        .textSelection(.enabled)
                    Text("Повторный запуск продолжит загрузку и использует уже сохранённые файлы.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Данные речи остаются на Mac. Компоненты загружаются из Astral, Hugging Face, PyPI, GigaAM и Qwen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(state.runtimeInstallError == nil ? "Установить модели" : "Продолжить установку") {
                        state.installRuntime()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    if state.runtimeInstallError != nil {
                        Button("Журнал") {
                            state.openRuntimeInstallLog()
                        }
                        .controlSize(.small)
                    }
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
                Text("Локальная диктовка и редактура текста")
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
            .disabled(state.isRecording || state.isBusy || state.isInstallingRuntime)

            Text(state.selectedEngine.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var textModePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Обработка текста")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Обработка текста", selection: $state.textProcessingMode) {
                ForEach(TextProcessingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(state.isRecording || state.isBusy || state.isInstallingRuntime)

            Text(state.textProcessingMode.detail)
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
            .disabled(state.isBusy || !state.selectedEngineReady || state.isInstallingRuntime)

            HStack(spacing: 7) {
                if state.isBusy {
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
                    Text("Последний текст")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(state.lastOutputMode.title)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.1))
                        .clipShape(Capsule())
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
                    Button("Хорошо") {
                        state.rateLastResult("accurate")
                    }
                    Button("Нужно исправить") {
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

            if state.selectedEngine.supportsContext {
                TextField(
                    state.selectedEngine.contextPlaceholder,
                    text: $state.recognitionContext
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
                Button("Подготовить модели") {
                    state.prewarmSelectedEngine()
                }
                .disabled(!state.selectedEngineReady || state.isBusy || state.isInstallingRuntime)
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
