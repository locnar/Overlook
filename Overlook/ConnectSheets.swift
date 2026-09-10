import SwiftUI

// Both sheets hand the password to `onConnect` as a value and clear the bound field on submit,
// cancel, and dismissal, so the secret does not sit in view state between prompts. A sheet can
// submit once: Enter and the Connect button can otherwise both fire for a single keystroke.

struct ManualConnectSheet: View {
    @Binding var isPresented: Bool
    @Binding var hostPort: String
    @Binding var port: String
    @Binding var password: String
    @Binding var savePassword: Bool

    let onConnect: (String) -> Void

    @State private var hasSubmitted = false

    private var canConnect: Bool {
        !hostPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canConnect, !hasSubmitted else { return }
        hasSubmitted = true
        let submittedPassword = password
        password = ""
        onConnect(submittedPassword)
        isPresented = false
    }

    private func cancel() {
        password = ""
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
                    cancel()
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
        .onAppear {
            hasSubmitted = false
        }
        .onDisappear {
            password = ""
        }
    }
}

struct PasswordPromptSheet: View {
    @Binding var isPresented: Bool
    @Binding var password: String
    @Binding var savePassword: Bool

    let onCancel: () -> Void
    let onConnect: (String) -> Void

    @State private var hasSubmitted = false

    private var canConnect: Bool {
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canConnect, !hasSubmitted else { return }
        hasSubmitted = true
        let submittedPassword = password
        password = ""
        onConnect(submittedPassword)
        isPresented = false
    }

    private func cancel() {
        password = ""
        onCancel()
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
                    cancel()
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
        .onAppear {
            hasSubmitted = false
        }
        .onDisappear {
            password = ""
        }
    }
}
