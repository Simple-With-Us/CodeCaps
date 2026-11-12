import QuotaCore
import SwiftUI

@MainActor
struct SMSAlertKindToggle: View {
    @ObservedObject var controller: SMSAlertController
    let kindID: String

    var body: some View {
        if SMSAlertPreferences.eligibleKinds.contains(kindID) {
            Toggle("Text Message", isOn: Binding(get: { controller.preferences[kindID] },
                                        set: { controller.preferences[kindID] = $0 }))
                .help("Send a text message when this alert is on.")
        }
    }
}

@MainActor
struct SMSSettingsView: View {
    @ObservedObject var controller: SMSAlertController
    @State private var accountSID = ""
    @State private var apiKeySID = ""
    @State private var apiKeySecret = ""
    @State private var messagingServiceSID = ""
    @State private var recipient = ""

    var body: some View {
        Section {
            TextField("Account SID", text: $accountSID)
            TextField("API Key SID", text: $apiKeySID)
            SecureField(controller.hasSavedSetup ? "API Key Secret (Blank Keeps Saved Secret)" : "API Key Secret",
                        text: $apiKeySecret)
            TextField("Messaging Service SID", text: $messagingServiceSID)
            TextField("Recipient Phone Number", text: $recipient, prompt: Text("+15551234567"))
            HStack {
                Button("Save Setup") {
                    Task {
                        let saved = await controller.saveSetup(configuration: .init(accountSID: accountSID,
                            apiKeySID: apiKeySID, messagingServiceSID: messagingServiceSID, recipient: recipient),
                            apiKeySecret: apiKeySecret)
                        if saved { apiKeySecret = "" }
                    }
                }
                Button("Forget Setup") {
                    Task {
                        await controller.forgetSetup()
                        if !controller.hasSavedSetup { apiKeySecret = ""; adoptConfiguration() }
                    }
                }
                .disabled(!controller.hasSavedSetup)
                Button("Re-Authorize Saved Setup") {
                    Task {
                        await controller.reauthorizeSavedSetup()
                        adoptConfiguration()
                    }
                }
                .disabled(!controller.hasSavedSetup)
                if controller.isWorking { ProgressView().controlSize(.small) }
            }
            .disabled(controller.isWorking)
            if let status = controller.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Text Message Alerts")
        } footer: {
            Text("Text messages start off for every alert." + sentenceGap
                 + "Turn on Text Message beside an alert above, then save your Twilio account, messaging service, and phone number." + sentenceGap
                 + "Your Twilio account pays for texts. A saved setup does not confirm that a text arrived.")
        }
        .onAppear { adoptConfiguration() }
    }

    private func adoptConfiguration() {
        accountSID = controller.configuration?.accountSID ?? ""
        apiKeySID = controller.configuration?.apiKeySID ?? ""
        messagingServiceSID = controller.configuration?.messagingServiceSID ?? ""
        recipient = controller.configuration?.recipient ?? ""
    }
}
