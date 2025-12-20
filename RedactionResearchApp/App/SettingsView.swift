import SwiftUI

struct SettingsView: View {
    @AppStorage("cloudAIEnabled") private var cloudAIEnabled: Bool = false
    @AppStorage("cloudAIAPIKey") private var cloudAIAPIKey: String = ""

    var body: some View {
        Form {
            Toggle("Enable Cloud AI (off by default)", isOn: $cloudAIEnabled)
            SecureField("Cloud AI API Key", text: $cloudAIAPIKey)
                .disabled(!cloudAIEnabled)
            Text("Cloud AI is optional. You will be prompted to enable it the first time you use an AI feature.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 480)
    }
}
