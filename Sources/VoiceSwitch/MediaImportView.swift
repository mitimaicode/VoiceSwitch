import SwiftUI

struct MediaImportView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "film.stack")
                    .foregroundStyle(.indigo)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Локальная расшифровка файла")
                        .font(.subheadline.weight(.semibold))
                    Text("Аудиодорожка обрабатывается на Mac блоками по 60 секунд. Изображение видео не анализируется.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if state.isTranscribingMedia {
                if let progress = state.mediaProgress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                if !state.mediaSourceName.isEmpty {
                    Text(state.mediaSourceName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(state.mediaStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                Button("Остановить задачу") {
                    state.cancelMediaTranscription()
                }
                .controlSize(.small)
            } else {
                Button {
                    state.chooseMediaFile()
                } label: {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                        Text("Выбрать аудио или видео…")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(!state.selectedEngineReady || state.selectedEngine == .apple)

                if !state.mediaStatus.isEmpty {
                    Text(state.mediaStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if state.lastMediaOutputDirectory != nil &&
                    (!state.hasMediaResult || state.lastText.isEmpty) {
                    Button("Показать папку задачи") {
                        state.openLastMediaOutputFolder()
                    }
                    .controlSize(.small)
                }

                if state.selectedEngine == .apple {
                    Text("Для файлов выберите GigaAM, Whisper или Qwen. Apple пока работает только с диктовкой.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("Результат: обычный текст и субтитры SRT/VTT с временными метками по блокам.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .background(Color.indigo.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
