// swiftlint:disable line_length
import SwiftUI
import AppKit

/// Behaviour for the settings panel: loading remote config, debounced applies, EDID pushes,
/// streamer draft commits, and the `GLKVMSystemConfig` bindings the section views drive.
///
/// Ticket 05: `WebUISettingsPanel` was split into per-section subviews, and every section needs the
/// same load/apply/binding logic. Rather than threading a dozen closures through each section, the
/// behaviour lives here in one small value type that just holds references (the panel model plus
/// the three environment managers). Constructing it is free, and the section views can stay narrow.
///
/// Isolation matches the original panel methods exactly: `WebUISettingsPanel` conformed to `View`,
/// which inferred `@MainActor` for the whole type, so the methods that lived there were already
/// main-actor isolated. This type is explicitly `@MainActor` for the same reason — the `async`
/// device calls it awaits are `nonisolated`, so they still run off the main thread.
@MainActor
struct WebUISettingsActions {
    typealias StreamerField = WebUISettingsPanelModel.StreamerField

    let model: WebUISettingsPanelModel
    let webRTCManager: WebRTCManager
    let inputManager: InputManager
    let kvmDeviceManager: KVMDeviceManager

    /// Resolution presets offered by the streamer resolution picker. `static` so the binding's
    /// getter does not rebuild a `Set` on every evaluation.
    static let streamerResolutionPresets: Set<String> = ["1920x1080", "1600x900", "1280x720", "1024x768"]

    var streamerFeatures: GLKVMStreamerState.Features? { model.streamerState?.features }
    var streamerLimits: GLKVMStreamerState.Limits? { model.streamerState?.limits }

    // MARK: - Focus mirroring

    /// The streamer text fields own a `@FocusState` (which cannot live in an `ObservableObject`);
    /// they mirror it here so the apply/sync logic can keep honouring "don't clobber what the user
    /// is typing" exactly as it did when the focus state lived on the panel view itself.
    func setFocusedStreamerField(_ field: StreamerField?) {
        model.focusedStreamerField = field
    }
}

/// Loading and applying remote device state.
extension WebUISettingsActions {
    // MARK: - Load

    func load() async {
        guard let client = kvmDeviceManager.glkvmClient else {
            await MainActor.run {
                model.config = nil
                model.keymaps = nil
                model.streamerState = nil
                model.currentEdid = ""
                model.selectedEdidOption = EDIDCatalog.customOptionID
                model.customEdidDraft = ""
                model.selectedVideoQualityPreset = 1
            }
            return
        }
        await MainActor.run {
            model.isLoading = true
        }
        do {
            async let keymapsRequest = client.getHidKeymaps()
            async let streamer = client.getStreamerState()
            let loadedConfig = try await client.getSystemConfig()
            let km = try await keymapsRequest
            let st = try await streamer
            let edidValue = try await client.getEDID()
            await MainActor.run {
                model.config = loadedConfig
                inputManager.applyConfiguredMouseMode(isAbsolute: loadedConfig.isAbsoluteMouse)
                webRTCManager.setPreferLowLatencyPlayout(loadedConfig.videoProcessing == "low_latency_first")
                model.keymaps = km
                model.streamerState = st
                model.currentEdid = edidValue
                syncEdidSelectionFromCurrent()
                if let params = st.params,
                   params.h264Bitrate == 20000,
                   params.h264Gop == 60,
                   params.quality == 100 {
                    model.selectedVideoQualityPreset = WebUISettingsPanelModel.videoQualityInsaneTag
                } else if (0...3).contains(loadedConfig.streamQuality) {
                    model.selectedVideoQualityPreset = loadedConfig.streamQuality
                } else {
                    model.selectedVideoQualityPreset = WebUISettingsPanelModel.videoQualityCustomTag
                }
                syncStreamerDraft(from: st)
                model.isLoading = false
            }
        } catch {
            await MainActor.run {
                model.isLoading = false
                recordError("Failed to load settings: \(error)")
            }
        }
    }

    // MARK: - Errors

    func recordError(_ message: String) {
        model.errorMessage = message
        model.errorHistory.insert(WebUISettingsPanelModel.ErrorEntry(date: Date(), message: message), at: 0)
        if model.errorHistory.count > 50 {
            model.errorHistory.removeLast(model.errorHistory.count - 50)
        }
    }

    // MARK: - Keyboard

    func availableKeymaps() -> [String] {
        if let loadedKeymaps = model.keymaps {
            let list = loadedKeymaps.keymaps.available
            if let current = model.config?.keymap, !current.isEmpty, !list.contains(current) {
                return [current] + list
            }
            return list
        }
        if let current = model.config?.keymap, !current.isEmpty {
            return [current]
        }
        return ["en-us"]
    }

    // MARK: - Video quality presets

    func applyVideoQualityPreset(_ preset: Int) async {
        guard preset != WebUISettingsPanelModel.videoQualityCustomTag else { return }
        guard let client = kvmDeviceManager.glkvmClient else { return }

        var params: [String: String] = [:]
        var streamQuality: Int? = nil

        switch preset {
        case 0:
            params = ["h264_bitrate": "500", "h264_gop": "30"]
            streamQuality = 0
        case 1:
            params = ["h264_bitrate": "2000", "h264_gop": "30"]
            streamQuality = 1
        case 2:
            params = ["h264_bitrate": "5000", "h264_gop": "60"]
            streamQuality = 2
        case 3:
            params = ["h264_bitrate": "8000", "h264_gop": "60"]
            streamQuality = 3
        case WebUISettingsPanelModel.videoQualityInsaneTag:
            params = ["quality": "100", "h264_bitrate": "20000", "h264_gop": "60"]
            streamQuality = 3
        default:
            return
        }

        await MainActor.run {
            model.isApplyingStreamer = true
        }

        do {
            try await client.setStreamerParams(params)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let st = try? await client.getStreamerState()
            await MainActor.run {
                model.streamerState = st
                syncStreamerDraft(from: st)
            }
        } catch {
            await MainActor.run {
                recordError("Failed to apply quality preset: \(error)")
            }
        }

        await MainActor.run {
            model.isApplyingStreamer = false
            if let streamQuality {
                updateConfig { $0.streamQuality = streamQuality }
            }
        }
    }

    // MARK: - EDID

    func normalizedEdid(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    func syncEdidSelectionFromCurrent() {
        model.isProgrammaticEdidSelectionUpdate = true
        defer {
            Task { @MainActor in
                await Task.yield()
                model.isProgrammaticEdidSelectionUpdate = false
            }
        }

        let normalizedCurrent = normalizedEdid(model.currentEdid)
        if normalizedCurrent.isEmpty {
            model.selectedEdidOption = EDIDCatalog.customOptionID
            model.customEdidDraft = ""
            return
        }

        if let match = EDIDCatalog.options.first(where: { opt in
            guard let edid = EDIDCatalog.resolvedEdid(for: opt) else { return false }
            return normalizedEdid(edid) == normalizedCurrent
        }) {
            model.selectedEdidOption = match.id
            model.customEdidDraft = model.currentEdid
            return
        }

        model.selectedEdidOption = EDIDCatalog.customOptionID
        model.customEdidDraft = model.currentEdid
    }

    func applyEdid(_ value: String) async {
        guard let client = kvmDeviceManager.glkvmClient else { return }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        model.isApplyingEdid = true

        do {
            try await client.setEDID(trimmed)
            let updated = try await client.getEDID()
            model.currentEdid = updated
            syncEdidSelectionFromCurrent()
            model.isApplyingEdid = false
        } catch {
            model.isApplyingEdid = false
            recordError("Failed to apply EDID: \(error)")
        }
    }
}

/// Streamer parameter drafts, debounced apply, and commit-on-blur.
extension WebUISettingsActions {
    // MARK: - Streamer params

    func syncStreamerDraft(from state: GLKVMStreamerState?) {
        guard let params = state?.params else { return }

        if model.focusedStreamerField != nil { return }

        model.isProgrammaticStreamerDraftUpdate = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            model.isProgrammaticStreamerDraftUpdate = false
        }

        if let desiredFps = params.desiredFps { model.streamerDesiredFps = desiredFps }
        if let quality = params.quality { model.streamerQuality = quality }
        if let bitrate = params.h264Bitrate { model.streamerH264Bitrate = bitrate }
        if let gop = params.h264Gop { model.streamerH264Gop = gop }
        if let zeroDelay = params.zeroDelay { model.streamerZeroDelay = zeroDelay }
        if let resolution = params.resolution { model.streamerResolution = resolution }

        model.streamerDesiredFpsText = String(model.streamerDesiredFps)
        model.streamerQualityText = String(model.streamerQuality)
        model.streamerH264BitrateText = String(model.streamerH264Bitrate)
        model.streamerH264GopText = String(model.streamerH264Gop)
    }

    func scheduleStreamerApply() {
        guard model.isProgrammaticStreamerDraftUpdate == false else { return }
        model.applyStreamerTask?.cancel()
        model.applyStreamerTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await applyStreamerParams()
        }
    }

    func applyStreamerParams() async {
        guard let client = kvmDeviceManager.glkvmClient else { return }
        guard model.streamerState != nil else { return }

        guard model.isProgrammaticStreamerDraftUpdate == false else { return }

        model.isApplyingStreamer = true

        let features = streamerFeatures

        let desiredFpsMin = streamerLimits?.desiredFps.min ?? 1
        let desiredFpsMax = streamerLimits?.desiredFps.max ?? 60
        let bitrateMin = streamerLimits?.h264Bitrate.min ?? 100
        let bitrateMax = streamerLimits?.h264Bitrate.max ?? 20000
        let gopMin = streamerLimits?.h264Gop.min ?? 1
        let gopMax = streamerLimits?.h264Gop.max ?? 300

        let clampedFps = clamp(model.streamerDesiredFps, min: desiredFpsMin, max: desiredFpsMax)
        let clampedQuality = clamp(model.streamerQuality, min: 0, max: 100)
        let clampedBitrate = clamp(model.streamerH264Bitrate, min: bitrateMin, max: bitrateMax)
        let clampedGop = clamp(model.streamerH264Gop, min: gopMin, max: gopMax)

        var params: [String: String] = [:]
        params["desired_fps"] = String(clampedFps)

        if features?.quality != false {
            params["quality"] = String(clampedQuality)
        }

        if features?.h264 != false {
            params["h264_bitrate"] = String(clampedBitrate)
            params["h264_gop"] = String(clampedGop)
        }

        if features?.zeroDelay != false {
            params["zero_delay"] = model.streamerZeroDelay ? "true" : "false"
        }

        if features?.resolution != false {
            let trimmed = model.streamerResolution.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                params["resolution"] = trimmed
            }
        }

        do {
            try await client.setStreamerParams(params)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let st = try? await client.getStreamerState()
            model.streamerState = st
            syncStreamerDraft(from: st)
            model.isApplyingStreamer = false
        } catch {
            model.isApplyingStreamer = false
            recordError("Failed to apply streamer params: \(error)")
        }
    }

    func commitStreamerEditsAndApplyIfNeeded() {
        guard model.isProgrammaticStreamerDraftUpdate == false else { return }

        model.isProgrammaticStreamerDraftUpdate = true
        defer {
            Task { @MainActor in
                await Task.yield()
                model.isProgrammaticStreamerDraftUpdate = false
            }
        }

        let desiredFpsMin = streamerLimits?.desiredFps.min ?? 1
        let desiredFpsMax = streamerLimits?.desiredFps.max ?? 60
        let bitrateMin = streamerLimits?.h264Bitrate.min ?? 100
        let bitrateMax = streamerLimits?.h264Bitrate.max ?? 20000
        let gopMin = streamerLimits?.h264Gop.min ?? 1
        let gopMax = streamerLimits?.h264Gop.max ?? 300

        let parsedFps = Int(model.streamerDesiredFpsText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? model.streamerDesiredFps
        let parsedQuality = Int(model.streamerQualityText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? model.streamerQuality
        let parsedBitrate = Int(model.streamerH264BitrateText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? model.streamerH264Bitrate
        let parsedGop = Int(model.streamerH264GopText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? model.streamerH264Gop

        let nextFps = clamp(parsedFps, min: desiredFpsMin, max: desiredFpsMax)
        let nextQuality = clamp(parsedQuality, min: 0, max: 100)
        let nextBitrate = clamp(parsedBitrate, min: bitrateMin, max: bitrateMax)
        let nextGop = clamp(parsedGop, min: gopMin, max: gopMax)

        if nextFps != model.streamerDesiredFps { model.streamerDesiredFps = nextFps }
        if nextQuality != model.streamerQuality { model.streamerQuality = nextQuality }
        if nextBitrate != model.streamerH264Bitrate { model.streamerH264Bitrate = nextBitrate }
        if nextGop != model.streamerH264Gop { model.streamerH264Gop = nextGop }

        model.streamerDesiredFpsText = String(model.streamerDesiredFps)
        model.streamerQualityText = String(model.streamerQuality)
        model.streamerH264BitrateText = String(model.streamerH264Bitrate)
        model.streamerH264GopText = String(model.streamerH264Gop)

        // Apply once after commit.
        Task { @MainActor in
            await Task.yield()
            scheduleStreamerApply()
        }
    }

    var streamerResolutionSelection: Binding<String> {
        Binding(
            get: {
                let trimmed = model.streamerResolution.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return "" }
                if Self.streamerResolutionPresets.contains(trimmed) {
                    return trimmed
                }
                return "custom"
            },
            set: { newValue in
                if newValue == "custom" {
                    return
                }
                model.streamerResolution = newValue
                scheduleStreamerApply()
            }
        )
    }

    func setPreferLowLatencyPlayout(_ prefer: Bool) {
        webRTCManager.setPreferLowLatencyPlayout(prefer)
    }

    // MARK: - Misc actions

    func clamp(_ value: Int, min: Int, max: Int) -> Int {
        if value < min { return min }
        if value > max { return max }
        return value
    }

    func refreshAudioDevices() {
        model.audioInputDevices = CoreAudioDevices.listInputDevices()
        model.audioOutputDevices = CoreAudioDevices.listOutputDevices()
    }

    func reconnectWebRTC() async {
        guard let device = kvmDeviceManager.connectedDevice else { return }

        await webRTCManager.reconnect(to: device, reason: "Stream settings changed")
        if let reason = webRTCManager.lastDisconnectReason {
            recordError("Failed to reconnect WebRTC: \(reason)")
        }
    }

    func resetKVM() async {
        guard let client = kvmDeviceManager.glkvmClient else { return }
        do {
            try await client.resetHid()
            try await client.resetStreamer()
        } catch {
            await MainActor.run {
                recordError("Failed to reset: \(error)")
            }
        }
    }

}

/// `GLKVMSystemConfig` plumbing: debounced writes and the bindings the section views drive.
extension WebUISettingsActions {
    // MARK: - Config plumbing

    func updateConfig(_ mutate: (inout GLKVMSystemConfig) -> Void) {
        guard var next = model.config else { return }
        let previous = next
        mutate(&next)
        model.config = next
        scheduleApply(next, switchesMouseMode: next.isAbsoluteMouse != previous.isAbsoluteMouse)
    }

    func scheduleApply(_ newConfig: GLKVMSystemConfig, switchesMouseMode: Bool = false) {
        model.applyTask?.cancel()
        model.applyTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            await apply(newConfig, switchesMouseMode: switchesMouseMode)
        }
    }

    func apply(_ newConfig: GLKVMSystemConfig, switchesMouseMode: Bool = false) async {
        guard let client = kvmDeviceManager.glkvmClient else { return }
        await MainActor.run { model.isApplying = true }
        do {
            let updated = try await client.setSystemConfig(newConfig)
            // The config only records the WebUI's preference; the device's HID gadget is switched
            // through hid/set_params, and it reports the result in a `hid` event. Without this the
            // toggle changed which reports Overlook sent, not which ones the device accepted.
            if switchesMouseMode {
                try await client.setHIDParams(["mouse_output": updated.isAbsoluteMouse ? "usb" : "usb_rel"])
            }
            await MainActor.run {
                model.config = updated
                inputManager.setGLKVMAbsoluteMouseMode(updated.isAbsoluteMouse)
                model.isApplying = false
            }
        } catch {
            await MainActor.run {
                model.isApplying = false
                recordError("Failed to apply settings: \(error)")
            }
        }
    }

    // MARK: - Config bindings

    func bindingString(
        get: @escaping (GLKVMSystemConfig) -> String,
        set: @escaping (inout GLKVMSystemConfig, String) -> Void,
        defaultValue: String
    ) -> Binding<String> {
        Binding(
            get: { model.config.map(get) ?? defaultValue },
            set: { newValue in
                guard model.config != nil, !model.isLoading, !model.isApplying else { return }
                updateConfig { set(&$0, newValue) }
            }
        )
    }

    func bindingInt(
        get: @escaping (GLKVMSystemConfig) -> Int,
        set: @escaping (inout GLKVMSystemConfig, Int) -> Void,
        defaultValue: Int
    ) -> Binding<Int> {
        Binding(
            get: { model.config.map(get) ?? defaultValue },
            set: { newValue in
                guard model.config != nil, !model.isLoading, !model.isApplying else { return }
                updateConfig { set(&$0, newValue) }
            }
        )
    }

    func bindingBool(
        get: @escaping (GLKVMSystemConfig) -> Bool,
        set: @escaping (inout GLKVMSystemConfig, Bool) -> Void,
        defaultValue: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { model.config.map(get) ?? defaultValue },
            set: { newValue in
                guard model.config != nil, !model.isLoading, !model.isApplying else { return }
                updateConfig { set(&$0, newValue) }
            }
        )
    }

    func bindingIntValue(get: @escaping (GLKVMSystemConfig) -> Int, defaultValue: Int) -> Int {
        model.config.map(get) ?? defaultValue
    }
}
