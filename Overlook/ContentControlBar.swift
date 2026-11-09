import SwiftUI

struct ContentControlBar: View {
    @Binding var selectedDevice: KVMDevice?

    let devices: [KVMDevice]
    let isScanning: Bool
    let isConnected: Bool
    let isOCRModeEnabled: Bool

    @Binding var showingSettings: Bool
    @Binding var showingManualConnect: Bool

    let onDeviceChanged: (KVMDevice?) -> Void
    let onScan: () -> Void
    let onToggleOCR: () -> Void
    let onToggleConnection: () -> Void

    var body: some View {
        HStack {
            Picker("Device", selection: $selectedDevice) {
                Text("Select Device").tag(nil as KVMDevice?)
                ForEach(devices) { device in
                    Text(device.displayName).tag(device as KVMDevice?)
                }
            }
            .frame(width: 200)
            .onChange(of: selectedDevice) { _, newDevice in
                onDeviceChanged(newDevice)
            }

            Button("Scan") {
                onScan()
            }
            .disabled(isScanning)
            .help("Scan for devices on the network")

            Button("Manual Connect…") {
                showingManualConnect = true
            }
            .help("Manually enter a device host/IP")

            Spacer()

            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showingSettings.toggle() } }) {
                Image(systemName: "gearshape")
            }
            .disabled(!isConnected)
            .help("Settings")

            Button(action: onToggleOCR) {
                Image(systemName: isOCRModeEnabled ? "text.viewfinder" : "doc.text")
            }
            .disabled(!isConnected)
            .help(isOCRModeEnabled ? "Disable OCR Selection" : "Enable OCR Selection")

            Button(action: onToggleConnection) {
                Image(systemName: isConnected ? "personalhotspot.slash" : "personalhotspot")
            }
            .disabled(selectedDevice == nil)
            .help(isConnected ? "Disconnect" : "Connect")
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}
