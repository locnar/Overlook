// swiftlint:disable line_length
import SwiftUI
import AppKit

/// Chrome for the settings panel: header, the ordered list of section subviews, and the error strip.
///
/// Ticket 05: this used to be a single ~450-line body holding every option table as a per-instance
/// `let`. The tables are `static` now (see `EDIDCatalog` and the section views), the behaviour lives
/// in `WebUISettingsActions`, and each `DisclosureGroup` is its own view in
/// `WebUISettingsSections.swift`, so constructing this value is essentially free and a change in one
/// section does not re-evaluate the pickers in the others.
struct WebUISettingsPanel: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager

    @Binding var isPresented: Bool

    /// Survivable panel state, owned by `ContentView`. Ticket 03: the panel is unmounted while
    /// closed, so anything that must persist across a close lives in the model, not in `@State`.
    @ObservedObject var model: WebUISettingsPanelModel

    private typealias ErrorEntry = WebUISettingsPanelModel.ErrorEntry

    private static let panelBackground = Color(NSColor.windowBackgroundColor)

    /// Reload trigger: the panel only exists while open (ticket 03), so the connected device is
    /// the only thing that needs to re-drive `load()` for a mounted panel. Mounting itself runs
    /// `.task` once, which keeps the previous load-on-open behaviour.
    private var settingsLoadID: String {
        kvmDeviceManager.connectedDevice?.id ?? "none"
    }

    private var actions: WebUISettingsActions {
        WebUISettingsActions(
            model: model,
            webRTCManager: webRTCManager,
            inputManager: inputManager,
            kvmDeviceManager: kvmDeviceManager
        )
    }

    var body: some View {
        let actions = self.actions
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Settings")
                    .font(.headline)
                Spacer()
                if model.isLoading || model.isApplying || model.isApplyingEdid {
                    ProgressView()
                        .controlSize(.small)
                }
                if model.isApplyingStreamer {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isPresented = false } }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VideoSettingsSection(
                        model: model,
                        isExpanded: $model.isVideoExpanded,
                        actions: actions
                    )

                    RemoteSettingsSection(
                        model: model,
                        isExpanded: $model.isRemoteExpanded,
                        actions: actions
                    )

                    KeyboardSettingsSection(
                        model: model,
                        isExpanded: $model.isKeyboardExpanded,
                        actions: actions
                    )

                    AudioSettingsSection(
                        model: model,
                        isExpanded: $model.isAudioExpanded,
                        actions: actions
                    )

                    SystemSettingsSection(
                        isExpanded: $model.isSystemExpanded,
                        actions: actions
                    )

                    NetworkSettingsSection(isExpanded: $model.isNetworkExpanded)

                    AdvancedSettingsSection(
                        isExpanded: $model.isAdvancedExpanded,
                        actions: actions
                    )
                }
                .padding()
            }

            Divider()

            if let visibleError = model.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(visibleError)
                        .foregroundColor(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("History…") {
                            model.showingErrorHistory = true
                        }
                        .buttonStyle(.borderless)

                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(visibleError, forType: .string)
                        }
                        .buttonStyle(.borderless)

                        Button("Dismiss") {
                            model.errorMessage = nil
                        }
                        .buttonStyle(.borderless)

                        Spacer()
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        }
        .background(Self.panelBackground)
        .sheet(isPresented: $model.showingErrorHistory) {
            ErrorHistorySheet(entries: model.errorHistory)
        }
        .task(id: settingsLoadID) {
            await actions.load()
        }
    }

    private struct ErrorHistorySheet: View {
        let entries: [ErrorEntry]

        private static let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .medium
            return df
        }()

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Errors")
                        .font(.headline)
                    Spacer()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.dateFormatter.string(from: entry.date))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(entry.message)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                HStack {
                    Button("Copy Latest") {
                        if let latest = entries.first?.message {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(latest, forType: .string)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            .frame(minWidth: 520, minHeight: 360)
        }
    }
}
