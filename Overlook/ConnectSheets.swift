import SwiftUI

struct ManualConnectSheet: View {
    @Binding var isPresented: Bool
    @Binding var hostPort: String
    @Binding var port: String
    @Binding var password: String
    @Binding var savePassword: Bool

    let onConnect: () -> Void

    private var canConnect: Bool {
        !hostPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canConnect else { return }
        onConnect()
        isPresented = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual Connect")
                .font(.headline)

            TextField("Host or IP (optionally host:port)", text: $hostPort)
                .textFieldStyle(.roundedBorder)

            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            Toggle("Save password for this device", isOn: $savePassword)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Connect") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .padding()
        .frame(width: 420)
        .onSubmit(submit)
    }
}

struct PasswordPromptSheet: View {
    @Binding var isPresented: Bool
    @Binding var password: String
    @Binding var savePassword: Bool

    let onCancel: () -> Void
    let onConnect: () -> Void

    private var canConnect: Bool {
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canConnect else { return }
        onConnect()
        isPresented = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password Required")
                .font(.headline)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            Toggle("Save password for this device", isOn: $savePassword)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    isPresented = false
                }
                Button("Connect") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .padding()
        .frame(width: 420)
        .onSubmit(submit)
    }
}
