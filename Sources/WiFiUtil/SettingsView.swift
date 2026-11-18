import ServiceManagement
import SwiftUI
import WiFiSystem

/// The Settings scene: scan interval, public IP lookup, open at login. Changes apply to the engine at once.
struct SettingsView: View {
    let engine: Engine
    @AppStorage(SettingsKey.scanIntervalSeconds) private var intervalSeconds = 60
    @AppStorage(SettingsKey.publicIPEnabled) private var publicIPEnabled = true
    @AppStorage(SettingsKey.interceptionChecksEnabled) private var interceptionChecksEnabled = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Scan every", selection: $intervalSeconds) {
                Text("Off").tag(0)
                Text("30 s").tag(30)
                Text("60 s").tag(60)
                Text("5 min").tag(300)
            }
            Text("A scan can briefly disturb the connection.").font(.caption).foregroundStyle(.secondary)

            Toggle("Look up public IP address", isOn: $publicIPEnabled)
            Text("Contacts api.ipify.org when the menu opens.").font(.caption).foregroundStyle(.secondary)

            Toggle("Check DNS and HTTPS for interception", isOn: $interceptionChecksEnabled)
            Text("Asks this network's DNS server about fixed names and opens apple.com.").font(.caption).foregroundStyle(.secondary)

            Toggle("Open at login", isOn: loginBinding)
            if let note = loginNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onChange(of: intervalSeconds) { _, _ in apply() }
        .onChange(of: publicIPEnabled) { _, _ in apply() }
        .onChange(of: interceptionChecksEnabled) { _, _ in apply() }
    }

    private func apply() {
        engine.settings = loadEngineSettings(from: .standard)
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: { enable in
                do {
                    if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                }
                loginStatus = SMAppService.mainApp.status
            })
    }

    private var loginNote: String? {
        switch loginStatus {
        case .requiresApproval: "Waiting for approval in System Settings → General → Login Items."
        case .notFound: "Login item not found; run the built WiFiUtil.app."
        default: nil
        }
    }
}
