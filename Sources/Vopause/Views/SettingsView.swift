import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.stackSpacing) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $model.isEnabled) {
                            Label("Enabled", systemImage: "power")
                        }
                        .toggleStyle(.switch)

                        Toggle(isOn: $model.autoResume) {
                            Label("Auto Resume", systemImage: "play.circle")
                        }
                        .toggleStyle(.switch)

                        HStack {
                            Label("Start at Login", systemImage: "arrow.clockwise.circle")
                            Spacer()
                            Text(model.launchAtLoginStatus)
                                .foregroundStyle(.secondary)
                            Button(model.launchAtLoginEnabled ? "Turn Off" : "Turn On") {
                                model.toggleLaunchAtLogin()
                            }
                        }
                    }
                }

                SettingsCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Stepper(
                            value: $model.activationDebounceMilliseconds,
                            in: 0...1_000,
                            step: 20
                        ) {
                            settingRow(
                                title: "Mic Start Debounce",
                                value: "\(model.activationDebounceMilliseconds) ms"
                            )
                        }

                        Stepper(
                            value: $model.deactivationGraceMilliseconds,
                            in: 0...3_000,
                            step: 50
                        ) {
                            settingRow(
                                title: "Mic Stop Grace",
                                value: "\(model.deactivationGraceMilliseconds) ms"
                            )
                        }
                    }
                }

                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        settingRow(title: "Monitor", value: model.monitorHealth.message)
                        settingRow(title: "Inputs", value: "\(model.inputDevices.count)")
                        settingRow(title: "Mode", value: model.modeLabel)
                        settingRow(title: "Accessibility", value: model.accessibilityTrusted ? "On" : "Off")

                        HStack {
                            Button(action: model.refreshAudioDevices) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }

                            Button(action: model.openAccessibilitySettings) {
                                Label("Accessibility", systemImage: "hand.raised")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, SettingsLayout.horizontalPadding)
            .padding(.vertical, SettingsLayout.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: SettingsLayout.idealWidth, height: SettingsLayout.idealHeight)
        .onAppear {
            model.refreshLaunchAtLoginStatus()
            model.refreshAccessibilityStatus()
        }
    }

    private func settingRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            Text(value)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
