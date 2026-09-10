// swiftlint:disable file_length line_length
import SwiftUI
import AppKit

// Ticket 05: one struct per `DisclosureGroup` section of the settings panel.
//
// The panel body used to be a single ~450-line expression, so any change anywhere in it (a keystroke
// in a streamer field, a device list refresh, an expansion toggle) re-evaluated every picker in
// every section. Each section is its own view now, taking only what it needs: the expansion
// binding, the shared `WebUISettingsActions` (behaviour), the panel model when it renders model
// state, and an `@EnvironmentObject` only for the managers whose published state it actually reads.
//
// All option tables and formatters are `static let` so instantiating a section allocates nothing
// beyond the struct itself.

// MARK: - Video

struct VideoSettingsSection: View {
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    private static let processingOptions: [(String, String)] = [
        ("low_latency_first", "Low latency"),
        ("quality_first", "Smart"),
    ]

    var body: some View {
        DisclosureGroup("Video", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                let modeBinding = actions.bindingString(
                    get: { $0.videoProcessing },
                    set: { $0.videoProcessing = $1 },
                    defaultValue: "low_latency_first"
                )
                Picker("Mode", selection: modeBinding) {
                    ForEach(Self.processingOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .onChange(of: modeBinding.wrappedValue) { _, newValue in
                    actions.setPreferLowLatencyPlayout(newValue == "low_latency_first")
                }

                Picker("Quality", selection: $model.selectedVideoQualityPreset) {
                    Text("Low").tag(0)
                    Text("Medium").tag(1)
                    Text("High").tag(2)
                    Text("Ultra-high").tag(3)
                    Text("Insane").tag(WebUISettingsPanelModel.videoQualityInsaneTag)
                    Text("Custom").tag(WebUISettingsPanelModel.videoQualityCustomTag)
                }
                .disabled(kvmDeviceManager.glkvmClient == nil || model.isLoading || model.isApplying || model.isApplyingStreamer || model.isApplyingEdid)
                .onChange(of: model.selectedVideoQualityPreset) { _, newValue in
                    guard model.isLoading == false else { return }
                    Task { await actions.applyVideoQualityPreset(newValue) }
                }

                Picker("EDID", selection: $model.selectedEdidOption) {
                    ForEach(EDIDCatalog.options, id: \.id) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                .disabled(kvmDeviceManager.glkvmClient == nil || model.isLoading || model.isApplyingEdid)
                .onChange(of: model.selectedEdidOption) { _, newValue in
                    guard model.isProgrammaticEdidSelectionUpdate == false else { return }
                    guard newValue != EDIDCatalog.customOptionID else { return }
                    guard let edid = EDIDCatalog.resolvedEdid(forID: newValue) else { return }
                    Task { await actions.applyEdid(edid) }
                }

                if model.selectedEdidOption == EDIDCatalog.customOptionID {
                    TextEditor(text: $model.customEdidDraft)
                        .font(.body)
                        .frame(minHeight: 90, maxHeight: 160)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                        .disabled(kvmDeviceManager.glkvmClient == nil || model.isApplyingEdid)

                    HStack {
                        Button("Apply custom EDID") {
                            Task { await actions.applyEdid(model.customEdidDraft) }
                        }
                        .disabled(
                            kvmDeviceManager.glkvmClient == nil ||
                                model.isApplyingEdid ||
                                model.customEdidDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )

                        Spacer()
                    }
                }

                Picker("Orientation", selection: actions.bindingInt(
                    get: { $0.orientation },
                    set: { $0.orientation = $1 },
                    defaultValue: 0
                )) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }

                Toggle("Show Cursor", isOn: actions.bindingBool(
                    get: { $0.showCursor },
                    set: { $0.showCursor = $1 },
                    defaultValue: true
                ))

                if model.selectedVideoQualityPreset == WebUISettingsPanelModel.videoQualityCustomTag {
                    StreamerParamsSection(model: model, actions: actions)
                }
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Streamer params (nested inside Video)

/// The custom-quality streamer controls. Split out from `VideoSettingsSection` because it owns the
/// `@FocusState` for the numeric text fields; that focus is mirrored into the panel model so the
/// apply/sync logic can keep skipping updates while the user is typing.
struct StreamerParamsSection: View {
    @ObservedObject var model: WebUISettingsPanelModel
    let actions: WebUISettingsActions

    @FocusState private var focusedStreamerField: WebUISettingsPanelModel.StreamerField?

    private var streamerFeatures: GLKVMStreamerState.Features? { actions.streamerFeatures }
    private var streamerLimits: GLKVMStreamerState.Limits? { actions.streamerLimits }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Streamer")
                .font(.subheadline)

            HStack {
                Text("FPS")
                Spacer()
                TextField("", text: $model.streamerDesiredFpsText)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedStreamerField, equals: .fps)
                    .onSubmit {
                        focusedStreamerField = nil
                    }
                Stepper(
                    "",
                    value: $model.streamerDesiredFps,
                    in: (streamerLimits?.desiredFps.min ?? 1)...(streamerLimits?.desiredFps.max ?? 60)
                )
                .labelsHidden()
                .disabled(focusedStreamerField == .fps)
            }
            .disabled(model.streamerState == nil)
            .onChange(of: model.streamerDesiredFps) { _, _ in
                guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                model.streamerDesiredFpsText = String(model.streamerDesiredFps)
                actions.scheduleStreamerApply()
            }

            HStack {
                Text("Quality")
                Spacer()
                TextField("", text: $model.streamerQualityText)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedStreamerField, equals: .quality)
                    .onSubmit {
                        focusedStreamerField = nil
                    }
                Stepper("", value: $model.streamerQuality, in: 0...100)
                    .labelsHidden()
                    .disabled(focusedStreamerField == .quality)
            }
            .disabled(model.streamerState == nil || streamerFeatures?.quality == false)
            .onChange(of: model.streamerQuality) { _, _ in
                guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                model.streamerQualityText = String(model.streamerQuality)
                actions.scheduleStreamerApply()
            }

            HStack {
                Text("Bitrate")
                Spacer()
                TextField("", text: $model.streamerH264BitrateText)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedStreamerField, equals: .bitrate)
                    .onSubmit {
                        focusedStreamerField = nil
                    }
                Stepper(
                    "",
                    value: $model.streamerH264Bitrate,
                    in: (streamerLimits?.h264Bitrate.min ?? 100)...(streamerLimits?.h264Bitrate.max ?? 20000)
                )
                .labelsHidden()
                .disabled(focusedStreamerField == .bitrate)
            }
            .disabled(model.streamerState == nil || streamerFeatures?.h264 == false)
            .onChange(of: model.streamerH264Bitrate) { _, _ in
                guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                model.streamerH264BitrateText = String(model.streamerH264Bitrate)
                actions.scheduleStreamerApply()
            }

            HStack {
                Text("GOP")
                Spacer()
                TextField("", text: $model.streamerH264GopText)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedStreamerField, equals: .gop)
                    .onSubmit {
                        focusedStreamerField = nil
                    }
                Stepper(
                    "",
                    value: $model.streamerH264Gop,
                    in: (streamerLimits?.h264Gop.min ?? 1)...(streamerLimits?.h264Gop.max ?? 300)
                )
                .labelsHidden()
                .disabled(focusedStreamerField == .gop)
            }
            .disabled(model.streamerState == nil || streamerFeatures?.h264 == false)
            .onChange(of: model.streamerH264Gop) { _, _ in
                guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                model.streamerH264GopText = String(model.streamerH264Gop)
                actions.scheduleStreamerApply()
            }

            Toggle("Zero delay", isOn: $model.streamerZeroDelay)
                .disabled(model.streamerState == nil || streamerFeatures?.zeroDelay == false)
                .onChange(of: model.streamerZeroDelay) { _, _ in
                    guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                    actions.scheduleStreamerApply()
                }

            Picker("Resolution", selection: actions.streamerResolutionSelection) {
                Text("Auto").tag("")
                Text("1920x1080").tag("1920x1080")
                Text("1600x900").tag("1600x900")
                Text("1280x720").tag("1280x720")
                Text("1024x768").tag("1024x768")
                Text("Custom").tag("custom")
            }
            .disabled(model.streamerState == nil || streamerFeatures?.resolution == false)

            if actions.streamerResolutionSelection.wrappedValue == "custom" {
                TextField("Custom resolution (e.g. 1920x1080)", text: $model.streamerResolution)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.streamerState == nil || streamerFeatures?.resolution == false)
                    .onChange(of: model.streamerResolution) { _, _ in
                        guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                        guard focusedStreamerField == nil else { return }
                        actions.scheduleStreamerApply()
                    }
                    .focused($focusedStreamerField, equals: .resolution)
                    .onSubmit {
                        focusedStreamerField = nil
                    }
            }
        }
        .onChange(of: focusedStreamerField) { old, new in
            actions.setFocusedStreamerField(new)
            if old != nil, new == nil {
                actions.commitStreamerEditsAndApplyIfNeeded()
            }
        }
        // The mirror lives on the model, which outlives this view (ticket 03), so clear it on the
        // way out: `@FocusState` resets itself on unmount, and a stale non-nil mirror would make
        // `syncStreamerDraft` skip a later load.
        .onDisappear {
            actions.setFocusedStreamerField(nil)
        }
    }
}

// MARK: - Remote device

struct RemoteSettingsSection: View {
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    private static let integerFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .none
        nf.generatesDecimalNumbers = false
        return nf
    }()

    private static let reverseScrollingOptions: [(String, String)] = [
        ("STANDARD", "Standard"),
        ("VERTICAL", "Vertical"),
        ("HORIZONTAL", "Horizontal"),
        ("BOTH", "Both"),
    ]

    var body: some View {
        DisclosureGroup("Remote device settings", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Mouse Control", isOn: actions.bindingBool(
                    get: { $0.mouseControl },
                    set: { $0.mouseControl = $1 },
                    defaultValue: true
                ))

                Toggle("Keyboard Control", isOn: actions.bindingBool(
                    get: { $0.keyboardControl },
                    set: { $0.keyboardControl = $1 },
                    defaultValue: true
                ))

                HStack {
                    Text("Mouse Polling")
                    Spacer()
                    let polling = actions.bindingInt(
                        get: { $0.mousePolling },
                        set: { $0.mousePolling = $1 },
                        defaultValue: 10
                    )
                    TextField("", value: polling, formatter: Self.integerFormatter)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: polling, in: 1...60)
                        .labelsHidden()
                }

                HStack {
                    Text("Sensitivity")
                    Spacer()
                    let sensitivity = actions.bindingInt(
                        get: { $0.relativeSense },
                        set: { $0.relativeSense = $1 },
                        defaultValue: 10
                    )
                    TextField("", value: sensitivity, formatter: Self.integerFormatter)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: sensitivity, in: 1...60)
                        .labelsHidden()
                }

                HStack {
                    Text("Scroll rate")
                    Spacer()
                    let scrollRate = actions.bindingInt(
                        get: { $0.scrollRate },
                        set: { $0.scrollRate = $1 },
                        defaultValue: 5
                    )
                    TextField("", value: scrollRate, formatter: Self.integerFormatter)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: scrollRate, in: 1...30)
                        .labelsHidden()
                }

                Picker("Scroll direction", selection: actions.bindingString(
                    get: { $0.reverseScrolling },
                    set: { $0.reverseScrolling = $1 },
                    defaultValue: "STANDARD"
                )) {
                    ForEach(Self.reverseScrollingOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }

                Toggle("Mouse Jiggle", isOn: actions.bindingBool(
                    get: { $0.mouseJiggle },
                    set: { $0.mouseJiggle = $1 },
                    defaultValue: false
                ))

                Picker("Mouse mode", selection: actions.bindingBool(
                    get: { $0.isAbsoluteMouse },
                    set: { $0.isAbsoluteMouse = $1 },
                    defaultValue: true
                )) {
                    Text("Relative").tag(false)
                    Text("Absolute").tag(true)
                }

                LocalRelativeMouseSettings()

                Stepper(
                    "Fingerbot strength: \(actions.bindingIntValue(get: { $0.fingerbotStrength }, defaultValue: 0))",
                    value: actions.bindingInt(
                        get: { $0.fingerbotStrength },
                        set: { $0.fingerbotStrength = $1 },
                        defaultValue: 0
                    ),
                    in: 0...100
                )
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Relative mouse mode (local)

/// Overlook-side relative-mode controls: they live on `InputManager`, not in the device config,
/// so they get their own observer and do not re-evaluate the rest of the remote section.
struct LocalRelativeMouseSettings: View {
    @EnvironmentObject var inputManager: InputManager

    var body: some View {
        Group {
            Divider()
                .padding(.vertical, 2)

            Text("Relative mode on this Mac")
                .font(.subheadline.weight(.semibold))

            HStack {
                Text("Local sensitivity")
                Spacer()
                Text(String(format: "%.2f×", inputManager.relativeSensitivity))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            Slider(value: $inputManager.relativeSensitivity, in: 0.25...4.0, step: 0.05)
                .help("Multiplier on mouse movement while the pointer is captured. At 1.00× the remote cursor travels the same on-screen distance your local cursor would have — or, with unaccelerated input on, the target receives your mouse's raw counts unchanged.")

            Toggle("Unaccelerated input (experimental)", isOn: $inputManager.useUnacceleratedRelativeInput)
                .help("Send the mouse's raw movement counts instead of macOS-accelerated movement, so the target applies its own pointer settings once, as with a directly attached mouse. Falls back to accelerated movement when the system does not provide counts. Expect to re-tune sensitivity.")

            Text("Click the video to capture the pointer; press ⌃⌥ to release it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Keyboard

struct KeyboardSettingsSection: View {
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    var body: some View {
        DisclosureGroup("Keyboard settings", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Keymap", selection: actions.bindingString(
                    get: { $0.keymap },
                    set: { $0.keymap = $1 },
                    defaultValue: "en-us"
                )) {
                    ForEach(actions.availableKeymaps(), id: \.self) { keymap in
                        Text(keymap).tag(keymap)
                    }
                }

                if let shortcuts = model.config?.shortcuts, !shortcuts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shortcuts")
                            .font(.subheadline)

                        ForEach(shortcuts, id: \.self) { shortcut in
                            HStack(alignment: .firstTextBaseline) {
                                Text(shortcut.label)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(shortcut.keys.joined(separator: "+"))
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Audio

struct AudioSettingsSection: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    @AppStorage("overlook.audio.inputDeviceUID") private var audioInputDeviceUID: String = ""
    @AppStorage("overlook.audio.outputDeviceUID") private var audioOutputDeviceUID: String = ""

    var body: some View {
        DisclosureGroup("Audio", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Audio", isOn: $webRTCManager.audioEnabled)
                Toggle("Microphone", isOn: $webRTCManager.micEnabled)

                Picker("Microphone device", selection: $audioInputDeviceUID) {
                    Text("System Default").tag("")
                    if !audioInputDeviceUID.isEmpty,
                       model.audioInputDevices.contains(where: { $0.uid == audioInputDeviceUID }) == false {
                        Text("Unavailable").tag(audioInputDeviceUID)
                    }
                    ForEach(model.audioInputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                Picker("Output device", selection: $audioOutputDeviceUID) {
                    Text("System Default").tag("")
                    if !audioOutputDeviceUID.isEmpty,
                       model.audioOutputDevices.contains(where: { $0.uid == audioOutputDeviceUID }) == false {
                        Text("Unavailable").tag(audioOutputDeviceUID)
                    }
                    ForEach(model.audioOutputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                Text("Reconnect required")
                    .foregroundColor(.secondary)
                    .font(.caption)

                Button("Reconnect WebRTC") {
                    Task { await actions.reconnectWebRTC() }
                }
                .disabled(kvmDeviceManager.connectedDevice == nil)
            }
            .padding(.top, 6)
            .onAppear { actions.refreshAudioDevices() }
            .onChange(of: isExpanded) { _, _ in actions.refreshAudioDevices() }
        }
    }
}

// MARK: - System

struct SystemSettingsSection: View {
    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    @AppStorage("overlook.appAppearance") private var appAppearance: String = "system"

    private static let appAppearanceOptions: [(String, String)] = [
        ("system", "System"),
        ("light", "Light"),
        ("dark", "Dark"),
    ]

    private static let themeOptions: [(String, String)] = [
        ("0", "Light"),
        ("1", "Dark"),
    ]

    var body: some View {
        DisclosureGroup("System", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("App appearance", selection: $appAppearance) {
                    ForEach(Self.appAppearanceOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }

                Picker("Color mode", selection: actions.bindingString(
                    get: { $0.themeMode },
                    set: { $0.themeMode = $1 },
                    defaultValue: "0"
                )) {
                    ForEach(Self.themeOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }

                NotImplementedRow(title: "Language")
                NotImplementedRow(title: "Timezone")
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Network

struct NetworkSettingsSection: View {
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup("Network", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                NotImplementedRow(title: "Modify")
                NotImplementedRow(title: "Wi-Fi")
                NotImplementedRow(title: "Ethernet")
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsSection: View {
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    var body: some View {
        DisclosureGroup("Advanced", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Button("Reset KVM") {
                    Task { await actions.resetKVM() }
                }
                .disabled(kvmDeviceManager.glkvmClient == nil)
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Shared rows

struct NotImplementedRow: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("Not implemented yet")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .opacity(0.7)
        .allowsHitTesting(false)
    }
}
