import SwiftUI
import UIKit
import WemoCore

@MainActor
struct SettingsView: View {
    @ObservedObject var model: HomeModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var address: String
    @State private var port: String
    @State private var validationError: String?
    @State private var testing = false
    @State private var testSucceeded = false

    init(model: HomeModel) {
        self.model = model
        _address = State(initialValue: model.snapshot.endpoint.address)
        _port = State(initialValue: String(model.snapshot.endpoint.port))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("IP address") {
                        TextField("192.168.4.28", text: $address)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Switch IP address")
                            .disabled(testing || model.snapshot.isBusy)
                    }
                    LabeledContent("Port") {
                        TextField("49153", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Switch HTTP port")
                            .disabled(testing || model.snapshot.isBusy)
                    }
                    Button {
                        testing = true
                        validationError = nil
                        testSucceeded = false
                        Task {
                            defer { testing = false }
                            do {
                                try await model.saveAndTest(address: address, port: port)
                                testSucceeded = model.snapshot.connection == .online && model.snapshot.light != nil
                            } catch { validationError = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            Text("Save & Test Connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                        .frame(minHeight: 32)
                    }
                    .disabled(testing || model.snapshot.isBusy || scenePhase != .active)
                } header: {
                    Text("Local connection")
                } footer: {
                    Text("Use the switch’s private IPv4 address on your home Wi-Fi. This saves the address and reads device information and light status. It does not change the light.")
                }
                if let error = validationError ?? model.snapshot.errorMessage {
                    Section { ErrorMessage(message: error) }
                } else if testSucceeded {
                    Section {
                        Label("Connection successful", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("Light: \(model.snapshot.light?.title ?? "Unknown")")
                    }
                }
                Section("Device information") {
                    LabeledContent("Name", value: model.snapshot.description?.friendlyName ?? "Rayns")
                    LabeledContent("Model", value: model.snapshot.description?.model ?? "Not yet read")
                    LabeledContent("Firmware", value: model.snapshot.description?.firmware ?? "Not yet read")
                    LabeledContent("Saved address", value: model.snapshot.endpoint.displayAddress)
                }
                Section {
                    Text("Wemo Home communicates directly with your switch while the app is open. Allow Local Network access in iPhone Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(testing) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Dismiss Keyboard") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
            .interactiveDismissDisabled(testing)
            .onChange(of: address) { _, _ in testSucceeded = false }
            .onChange(of: port) { _, _ in testSucceeded = false }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.setActive(false); testSucceeded = false }
            }
        }
    }
}
