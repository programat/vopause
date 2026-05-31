import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusBlock
            deviceBlock
            controls
            footer
        }
        .padding(VopausePalette.surfacePadding)
        .frame(width: 380)
        .background(
            VopausePalette.popoverBackground,
            in: RoundedRectangle(cornerRadius: VopausePalette.popoverCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: VopausePalette.popoverCornerRadius, style: .continuous)
                .strokeBorder(VopausePalette.hairline, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: VopausePalette.controlCornerRadius, style: .continuous)
                    .fill(model.isMicActive ? VopausePalette.activeFill : VopausePalette.surfaceFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: VopausePalette.controlCornerRadius, style: .continuous)
                            .strokeBorder(model.isMicActive ? VopausePalette.activeBorder : VopausePalette.hairline)
                    }

                Image(systemName: model.menuBarSystemImage)
                    .font(.title3)
                    .foregroundStyle(model.isMicActive ? .green : .primary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Vopause")
                    .font(.title3.weight(.semibold))

                Text(model.modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: model.refreshAudioDevices) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 30, height: 30)
                    .background(VopausePalette.surfaceFill, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Refresh audio devices")
        }
        .padding(.horizontal, 4)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(model.micLabel, systemImage: model.isMicActive ? "waveform" : "waveform.slash")
                    .font(.headline)
                Spacer()
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if model.monitorHealth != .ok {
                Label(model.monitorHealth.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusFill, in: RoundedRectangle(cornerRadius: VopausePalette.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: VopausePalette.cornerRadius)
                .strokeBorder(statusBorder, lineWidth: 1)
        }
    }

    private var statusFill: Color {
        if model.monitorHealth != .ok {
            return VopausePalette.warningFill
        }
        if model.isMicActive {
            return VopausePalette.activeFill
        }
        return VopausePalette.surfaceFill
    }

    private var statusBorder: Color {
        if model.monitorHealth != .ok {
            return VopausePalette.warningBorder
        }
        if model.isMicActive {
            return VopausePalette.activeBorder
        }
        return VopausePalette.hairline
    }

    private var deviceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inputs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if model.inputDevices.isEmpty {
                Text("No input devices")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.inputDevices.prefix(5)) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.isRunning ? "record.circle.fill" : "circle")
                            .foregroundStyle(device.isRunning ? .green : .secondary)
                            .frame(width: 16)

                        Text(device.name)
                            .font(.callout)
                            .lineLimit(1)

                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VopausePalette.surfaceFill, in: RoundedRectangle(cornerRadius: VopausePalette.cornerRadius))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("Enabled", systemImage: "power")
                    .font(.callout.weight(.medium))

                Spacer(minLength: 12)

                Toggle("Enabled", isOn: $model.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            HStack(spacing: 8) {
                Button(action: { model.snooze(for: 15 * 60) }) {
                    Label("15 min", systemImage: "pause.circle")
                }
                .buttonStyle(MenuActionButtonStyle(fillsWidth: true))

                Button(action: { model.snooze(for: 60 * 60) }) {
                    Label("1 hour", systemImage: "clock")
                }
                .buttonStyle(MenuActionButtonStyle(fillsWidth: true))

                Button(action: model.resumeUtilityNow) {
                    Label("Resume", systemImage: "play.circle")
                }
                .buttonStyle(MenuActionButtonStyle(fillsWidth: true))
                .disabled(!model.isSnoozed)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VopausePalette.surfaceFill, in: RoundedRectangle(cornerRadius: VopausePalette.cornerRadius))
    }

    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(MenuActionButtonStyle())

            Spacer()

            Button(role: .destructive, action: quitApp) {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(MenuActionButtonStyle(tone: .secondary))
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

private struct MenuActionButtonStyle: ButtonStyle {
    enum Tone {
        case primary
        case secondary
    }

    var tone: Tone = .primary
    var fillsWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(foreground(isPressed: configuration.isPressed))
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(border(isPressed: configuration.isPressed), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.55)
    }

    private func foreground(isPressed: Bool) -> Color {
        switch tone {
        case .primary:
            .primary
        case .secondary:
            isPressed ? .primary : .secondary
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch tone {
        case .primary:
            isPressed ? VopausePalette.elevatedFill : VopausePalette.surfaceFill
        case .secondary:
            isPressed ? VopausePalette.surfaceFill : .clear
        }
    }

    private func border(isPressed: Bool) -> Color {
        switch tone {
        case .primary:
            VopausePalette.hairline
        case .secondary:
            isPressed ? VopausePalette.hairline : .clear
        }
    }
}
