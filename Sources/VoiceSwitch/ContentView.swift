import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.onboardingCompleted {
                mainContent
            } else {
                onboardingContent
            }
        }
        .padding(16)
        .frame(width: 430)
        .onAppear {
            state.refreshPermissions()
            state.refreshRuntimeState()
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if state.shouldShowRuntimeSetup {
                runtimeSetupSection
            }
            enginePicker
            textModePicker
            recordSection
            resultSection
            settingsSection
            footer
        }
    }

    @ViewBuilder
    private var onboardingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            switch state.onboardingStep {
            case .welcome:
                welcomeStep
            case .models:
                modelSelectionStep
            case .permissions:
                permissionsStep
            case .ready:
                readyStep
            }
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Настроим диктовку за несколько шагов")
                .font(.title3.weight(.semibold))

            Text("VoiceSwitch работает локально: аудио и готовый текст не отправляются во внешние API.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 9) {
                onboardingFeature("1.circle.fill", "Выберем только нужные модели")
                onboardingFeature("2.circle.fill", "Разрешим микрофон и автоматическую вставку")
                onboardingFeature("3.circle.fill", "Проверим первую диктовку")
            }

            unsignedNotice

            Button("Начать настройку") {
                state.beginOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var modelSelectionStep: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Выберите стартовый комплект")
                .font(.title3.weight(.semibold))
            Text("Другие модели можно установить позже. Для начала рекомендуем GigaAM.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(RuntimeInstallPreset.allCases) { preset in
                Button {
                    state.selectInstallPreset(preset)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: state.selectedInstallPreset == preset
                            ? "checkmark.circle.fill"
                            : "circle")
                            .foregroundStyle(state.selectedInstallPreset == preset ? .indigo : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(preset.title)
                                    .font(.subheadline.weight(.semibold))
                                if preset == .russian {
                                    Text("Рекомендуется")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.indigo.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                                Spacer()
                                Text(preset.storage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(preset.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(
                    state.selectedInstallPreset == preset
                        ? Color.indigo.opacity(0.1)
                        : Color.secondary.opacity(0.06)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(state.isInstallingRuntime)
            }

            installProgress

            if !state.isInstallingRuntime {
                Button(state.runtimeInstallError == nil ? "Установить и продолжить" : "Продолжить установку") {
                    state.installRuntime()
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Разрешения macOS")
                .font(.title3.weight(.semibold))
            Text("VoiceSwitch не может включить эти разрешения самостоятельно. Они нужны только для записи и вставки текста.")
                .font(.callout)
                .foregroundStyle(.secondary)

            permissionRow(
                icon: "mic.fill",
                title: "Микрофон",
                detail: state.microphoneStatus,
                granted: state.microphoneAuthorized,
                actionTitle: "Разрешить",
                action: state.requestMicrophonePermission
            )
            permissionRow(
                icon: "checkmark.shield.fill",
                title: "Универсальный доступ",
                detail: "Горячая клавиша и автоматическая вставка",
                granted: state.accessibilityAuthorized,
                actionTitle: "Открыть настройки",
                action: state.requestAccessibility
            )

            HStack {
                Button("Проверить снова") {
                    state.refreshPermissions()
                }
                Spacer()
                Button("Продолжить") {
                    state.continueOnboardingFromPermissions()
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("VoiceSwitch готов", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)

            Text("Установлено: \(installedComponentNames). Нажмите fn + Option, скажите фразу и нажмите сочетание ещё раз.")
                .font(.callout)

            if !state.accessibilityAuthorized {
                Text("Автоматическая вставка пока недоступна. Расшифровка будет оставаться в буфере обмена, пока вы не разрешите универсальный доступ.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Открыть VoiceSwitch") {
                state.completeOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var unsignedNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Бесплатная beta без подписи Apple", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text("При первом запуске откройте VoiceSwitch через правый клик → «Открыть». После обновления macOS может попросить разрешить универсальный доступ повторно.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var runtimeSetupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: state.isInstallingRuntime ? "arrow.down.circle" : "externaldrive.badge.plus")
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Добавить локальные модели")
                        .font(.subheadline.weight(.semibold))
                    Text("Установленные модели и данные останутся на Mac")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if state.isInstallingRuntime {
                installProgress
            } else {
                ForEach(RuntimeComponent.allCases) { component in
                    modelComponentRow(component)
                }

                if let installError = state.runtimeInstallError {
                    Text(installError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }

                HStack {
                    Button(state.runtimeInstallError == nil ? "Установить выбранное" : "Продолжить установку") {
                        state.installRuntime()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(state.selectedInstallComponents.isSubset(of: state.installedComponents))
                    if state.runtimeInstallError != nil {
                        Button("Журнал") {
                            state.openRuntimeInstallLog()
                        }
                        .controlSize(.small)
                    }
                    Spacer()
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

    @ViewBuilder
    private var installProgress: some View {
        if state.isInstallingRuntime {
            VStack(alignment: .leading, spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(state.runtimeInstallStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                Button("Остановить") {
                    state.cancelRuntimeInstallation()
                }
                .controlSize(.small)
            }
        } else if let installError = state.runtimeInstallError {
            Text(installError)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(5)
                .textSelection(.enabled)
        }
    }

    private func modelComponentRow(_ component: RuntimeComponent) -> some View {
        let isInstalled = state.installedComponents.contains(component)
        let isSelected = state.selectedInstallComponents.contains(component)

        return Button {
            guard !isInstalled else { return }
            state.toggleInstallComponent(component)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: component.icon)
                    .frame(width: 18)
                    .foregroundStyle(isInstalled ? .green : .indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(component.title)
                        .font(.caption.weight(.semibold))
                    Text("\(component.detail) · \(component.downloadSize)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isInstalled {
                    Label("Установлено", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isSelected ? .indigo : .secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Button("Подготовить модель") {
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

    private var installedComponentNames: String {
        let names = RuntimeComponent.allCases
            .filter(state.installedComponents.contains)
            .map(\.title)
        return names.isEmpty ? "системный режим Apple" : names.joined(separator: ", ")
    }

    private func onboardingFeature(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.primary)
    }

    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(granted ? .green : .indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(granted ? "Разрешено" : detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
