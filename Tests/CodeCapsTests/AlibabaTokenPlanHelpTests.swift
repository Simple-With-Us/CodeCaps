import XCTest
@testable import CodeCaps

/// The Alibaba Token Plan help in Settings points at the official docs and carries no key.
final class AlibabaTokenPlanHelpTests: XCTestCase {
    func testLinksAreTheOfficialBailianCLIDocs() {
        XCTAssertEqual(AlibabaTokenPlanHelp.installURL.absoluteString,
                       "https://www.alibabacloud.com/help/en/model-studio/cli/installation")
        XCTAssertEqual(AlibabaTokenPlanHelp.usageURL.absoluteString,
                       "https://www.alibabacloud.com/help/en/model-studio/cli/usage-quota")
    }

    func testAuthLinkIsTheOfficialConfigPage() {
        XCTAssertEqual(AlibabaTokenPlanHelp.authURL.absoluteString, "https://help.aliyun.com/en/model-studio/cli/config")
        XCTAssertTrue(AlibabaTokenPlanHelp.openAPICommand.hasPrefix("bl auth login --open-api"))
    }

    func testCommandsUsePlaceholdersNeverKeyValues() {
        let all = [AlibabaTokenPlanHelp.planKeyCommand, AlibabaTokenPlanHelp.consoleCommand,
                   AlibabaTokenPlanHelp.openAPICommand, AlibabaTokenPlanHelp.checkCommand, AlibabaTokenPlanHelp.tooltip]
            + AlibabaTokenPlanHelp.steps
        for text in all {
            XCTAssertFalse(text.contains("sk-"), text)
        }
        XCTAssertTrue(AlibabaTokenPlanHelp.planKeyCommand.contains("<plan key>"))
        XCTAssertTrue(AlibabaTokenPlanHelp.checkCommand.hasPrefix("bl usage token-plan"))
    }
}
