import EQCore
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            presetRow
            VStack(spacing: 6) {
                EQGraphView(settings: $model.settings, isActive: model.isEnabled)
                    .frame(height: 168)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .opacity(model.isEnabled ? 1 : 0.6)
                bandLabels
            }
            preampRow
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(colors: [.accentColor.opacity(0.85), .accentColor], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Tonebar").font(.headline)
                StatusLine(state: model.engine.state, isEnabled: model.isEnabled, retry: model.retry)
            }
            Spacer()
            Toggle("Equalizer", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var presetRow: some View {
        HStack {
            Menu {
                ForEach(Preset.all) { preset in
                    Button {
                        model.settings = preset.settings
                    } label: {
                        if model.activePreset == preset {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            } label: {
                Text(model.activePreset?.name ?? "Custom")
            }
            .menuStyle(.button)
            .fixedSize()

            Spacer()

            Button("Reset") { model.settings = .flat }
                .disabled(model.settings.isFlat)
        }
        .controlSize(.small)
    }

    private var bandLabels: some View {
        HStack(spacing: 0) {
            ForEach(EQSettings.bandFrequencies.indices, id: \.self) { band in
                Text(EQGraphView.label(forBand: band))
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var preampRow: some View {
        HStack(spacing: 10) {
            Text("Preamp")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { model.settings.preamp }, set: { model.settings.setPreamp(($0 * 2).rounded() / 2) }),
                in: EQSettings.preampRange
            )
            .controlSize(.small)
            Text("\(EQGraphView.format(model.settings.preamp)) dB")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchesAtLogin($0) }))
                .toggleStyle(.checkbox)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}

private struct StatusLine: View {
    let state: SystemEqualizer.State
    let isEnabled: Bool
    let retry: () -> Void

    var body: some View {
        Group {
            switch state {
            case .off:
                Text(isEnabled ? "Starting…" : "Bypassed")
            case .running(let device, let sampleRate):
                Text("\(device) · \((sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz")
            case .needsPermission:
                HStack(spacing: 4) {
                    Text("Needs system audio access.")
                    Button("Open Settings") { NSWorkspace.shared.open(AudioCapturePermission.settingsURL) }
                        .buttonStyle(.link)
                }
            case .failed(let message):
                HStack(spacing: 4) {
                    Text(message).lineLimit(1).truncationMode(.middle).help(message)
                    Button("Retry", action: retry).buttonStyle(.link)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
