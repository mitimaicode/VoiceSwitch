import AppKit
import Combine
import SwiftUI

enum HUDPhase: Equatable {
    case hidden
    case recording(startedAt: Date)
    case transcribing(startedAt: Date, engine: String)
    case success(message: String)
    case failure(message: String)
}

final class HUDModel: ObservableObject {
    @Published private(set) var phase: HUDPhase = .hidden

    fileprivate func update(_ phase: HUDPhase) {
        self.phase = phase
    }
}

final class HUDController {
    private let model: HUDModel
    private let panel: NSPanel
    private var pendingHide: DispatchWorkItem?

    init(model: HUDModel) {
        self.model = model

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView: HUDOverlayView(model: model))
        self.panel = panel
    }

    func showRecording() {
        present(.recording(startedAt: Date()))
    }

    func showTranscribing(engine: String) {
        present(.transcribing(startedAt: Date(), engine: engine))
    }

    func showSuccess(_ message: String) {
        present(.success(message: message))
        scheduleHide(after: 1.25)
    }

    func showFailure(_ message: String) {
        present(.failure(message: message))
        scheduleHide(after: 2.0)
    }

    func hideImmediately() {
        pendingHide?.cancel()
        pendingHide = nil
        panel.orderOut(nil)
        panel.alphaValue = 0
        model.update(.hidden)
    }

    private func present(_ phase: HUDPhase) {
        pendingHide?.cancel()
        pendingHide = nil
        model.update(phase)
        positionPanel()

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut() {
        pendingHide = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.model.update(.hidden)
        }
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let screen else { return }

        let frame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - panelSize.width / 2,
            y: frame.maxY - panelSize.height - 34
        )
        panel.setFrameOrigin(origin)
    }
}

struct MenuBarStatusIcon: View {
    @ObservedObject var model: HUDModel

    @ViewBuilder
    var body: some View {
        switch model.phase {
        case .recording:
            Image(systemName: "mic.fill")
                .symbolEffect(.pulse, options: .repeating)
        case .transcribing:
            Image(systemName: "ellipsis.circle")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .success:
            Image(systemName: "checkmark.circle.fill")
        case .failure:
            Image(systemName: "exclamationmark.circle.fill")
        case .hidden:
            Image(systemName: "waveform.circle")
        }
    }
}

private struct HUDOverlayView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            HStack(spacing: 12) {
                glyph(at: context.date)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let startedAt {
                    Text(elapsed(from: startedAt, to: context.date))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(width: 330, height: 64)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(borderColor.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
            .padding(4)
        }
    }

    @ViewBuilder
    private func glyph(at date: Date) -> some View {
        switch model.phase {
        case .recording:
            let pulse = 1 + 0.09 * sin(date.timeIntervalSinceReferenceDate * 5)
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 38, height: 38)
                    .scaleEffect(pulse)
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.red)
            }
        case .transcribing:
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.16))
                    .frame(width: 38, height: 38)
                ProgressView()
                    .controlSize(.small)
                    .tint(.indigo)
            }
        case .success:
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.green)
            }
        case .failure:
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.17))
                    .frame(width: 38, height: 38)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.orange)
            }
        case .hidden:
            EmptyView()
        }
    }

    private var title: String {
        switch model.phase {
        case .recording:
            return "Идёт запись"
        case .transcribing:
            return "Распознаю речь"
        case .success(let message), .failure(let message):
            return message
        case .hidden:
            return ""
        }
    }

    private var detail: String {
        switch model.phase {
        case .recording:
            return "fn + ⌥ — остановить"
        case .transcribing(_, let engine):
            return "\(engine) · дождитесь завершения"
        case .success:
            return "Готово"
        case .failure:
            return "Проверьте меню VoiceSwitch"
        case .hidden:
            return ""
        }
    }

    private var startedAt: Date? {
        switch model.phase {
        case .recording(let date), .transcribing(let date, _):
            return date
        default:
            return nil
        }
    }

    private var borderColor: Color {
        switch model.phase {
        case .recording:
            return .red
        case .transcribing:
            return .indigo
        case .success:
            return .green
        case .failure:
            return .orange
        case .hidden:
            return .clear
        }
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
