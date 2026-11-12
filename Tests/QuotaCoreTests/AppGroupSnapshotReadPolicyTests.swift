import XCTest
@testable import QuotaCore

final class AppGroupSnapshotReadPolicyTests: XCTestCase {
    func testMissingFileConsultsNextTier() {
        XCTAssertEqual(
            AppGroupSnapshotReadPolicy.decision(
                filePresent: false,
                readSucceeded: false,
                decodeSucceeded: false,
                decodedExplicitlyEmpty: false
            ),
            .consultNextTier
        )
    }

    func testUnreadableFileFallsThrough() {
        XCTAssertEqual(
            AppGroupSnapshotReadPolicy.decision(
                filePresent: true,
                readSucceeded: false,
                decodeSucceeded: false,
                decodedExplicitlyEmpty: false
            ),
            .consultNextTier
        )
    }

    func testDecodeFailureFallsThrough() {
        XCTAssertEqual(
            AppGroupSnapshotReadPolicy.decision(
                filePresent: true,
                readSucceeded: true,
                decodeSucceeded: false,
                decodedExplicitlyEmpty: false
            ),
            .consultNextTier
        )
    }

    func testValidEmptyIsAuthoritative() {
        XCTAssertEqual(
            AppGroupSnapshotReadPolicy.decision(
                filePresent: true,
                readSucceeded: true,
                decodeSucceeded: true,
                decodedExplicitlyEmpty: true
            ),
            .stopAuthoritativeEmpty
        )
    }

    func testValidContentIsAuthoritative() {
        XCTAssertEqual(
            AppGroupSnapshotReadPolicy.decision(
                filePresent: true,
                readSucceeded: true,
                decodeSucceeded: true,
                decodedExplicitlyEmpty: false
            ),
            .stopAuthoritativeContent
        )
    }
}
