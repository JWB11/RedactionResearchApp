import SwiftUI

struct SettingsView: View {
    @ObservedObject private var ai = AIService.shared
    @AppStorage("cloudAIAPIKey") private var cloudAIAPIKey: String = ""

    @State private var showingLocalConsent: Bool = false
    @State private var showingCloudConsent: Bool = false

    var body: some View {
        Form {
            Section("AI routing") {
                Toggle("Enable Local AI (on-device)", isOn: Binding(
                    get: { ai.isLocalEnabled },
                    set: { newValue in
                        if newValue {
                            if ai.hasLocalConsent {
                                ai.setLocalAIEnabled(true)
                            } else {
                                showingLocalConsent = true
                            }
                        } else {
                            ai.setLocalAIEnabled(false)
                        }
                    })
                )
                Text("Local AI keeps prompts and document text on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Enable Cloud AI (off-device)", isOn: Binding(
                    get: { ai.isCloudEnabled },
                    set: { newValue in
                        if newValue {
                            if ai.hasCloudConsent {
                                ai.setCloudAIEnabled(true)
                            } else {
                                showingCloudConsent = true
                            }
                        } else {
                            ai.setCloudAIEnabled(false)
                        }
                    })
                )
                SecureField("Cloud AI API Key", text: $cloudAIAPIKey)
                    .disabled(!ai.isCloudEnabled)
                Text("Cloud AI sends prompts and derived text to your configured provider. Enable only when you intend to use cloud models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 480)
        .alert("Enable Local AI?", isPresented: $showingLocalConsent) {
            Button("Enable", role: .destructive) {
                ai.markConsent(forLocal: true)
                ai.setLocalAIEnabled(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local AI runs entirely on-device; your data stays on this Mac.")
        }
        .alert("Enable Cloud AI?", isPresented: $showingCloudConsent) {
            Button("Enable", role: .destructive) {
                ai.markConsent(forLocal: false)
                ai.setCloudAIEnabled(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cloud AI routes prompts and content to your configured provider. Do not enable unless you are comfortable with this data leaving your device.")
        }
    }
}
