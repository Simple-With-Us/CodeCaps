import XCTest
@testable import CodeCaps

final class VersionDisplayTests: XCTestCase {
    func testMarketingVersionIsShownOnceWithoutTheRepeatedBuildNumber() {
        XCTAssertEqual(CodeCapsVersion.displayVersion(shortVersion: "1.0.148"), "Version 1.0.148")
    }

    func testMissingMarketingVersionUsesTheExistingFallback() {
        XCTAssertEqual(CodeCapsVersion.displayVersion(shortVersion: nil), "Version 1.0")
    }
}
