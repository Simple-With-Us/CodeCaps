import SwiftUI

/// What the Alibaba Token Plan source needs, in the words and commands of the official
/// Bailian CLI docs.  No key value appears here:  every credential is a placeholder, and
/// CodeCaps only runs the bounded `bl usage token-plan` command.
enum AlibabaTokenPlanHelp {
    static let installURL = URL(string: "https://www.alibabacloud.com/help/en/model-studio/cli/installation")!
    static let usageURL = URL(string: "https://www.alibabacloud.com/help/en/model-studio/cli/usage-quota")!

    static let planKeyCommand = "bl auth login --config token-plan --api-key <plan key> --base-url https://token-plan.ap-southeast-1.maas.aliyuncs.com"
    static let consoleCommand = "bl auth login --console --config token-plan --console-site international"
    static let consoleFallback = "--no-browser"
    static let checkCommand = "bl usage token-plan --output json"

    static let tooltip = "Needs the Bailian CLI (bl) signed in two ways: your Token Plan key, and a console sign-in or AccessKey for usage."

    static let steps: [String] = [
        "Install the Bailian CLI (bl).",
        "Sign in with your Token Plan key (international endpoint shown; use the endpoint for the region you subscribed in):",
        "Usage needs its own sign-in. Either sign in to the console (add --no-browser to print the login link), or use an Alibaba Cloud AccessKey ID and secret from the RAM console in BAILIAN_ACCESS_KEY_ID and BAILIAN_ACCESS_KEY_SECRET:",
        "Check it works. CodeCaps runs only this command:",
    ]
}

struct AlibabaTokenPlanHelpView: View {
    var body: some View {
        DisclosureGroup("How to connect Alibaba Token Plan") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(AlibabaTokenPlanHelp.steps[0])")
                Link("Bailian CLI install guide", destination: AlibabaTokenPlanHelp.installURL)
                Text(AlibabaTokenPlanHelp.steps[1])
                command(AlibabaTokenPlanHelp.planKeyCommand)
                Text(AlibabaTokenPlanHelp.steps[2])
                command(AlibabaTokenPlanHelp.consoleCommand)
                Text(AlibabaTokenPlanHelp.steps[3])
                command(AlibabaTokenPlanHelp.checkCommand)
                Link("Usage and quota commands", destination: AlibabaTokenPlanHelp.usageURL)
                Text("CodeCaps never reads or stores your keys; they stay in the bl CLI's own sign-in.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
        .font(.caption)
        .help(AlibabaTokenPlanHelp.tooltip)
    }

    private func command(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}
