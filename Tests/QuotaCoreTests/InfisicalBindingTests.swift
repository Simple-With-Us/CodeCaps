import XCTest
@testable import QuotaCore

final class InfisicalBindingTests: XCTestCase {
    private func binding(_ access: InfisicalBinding.Access, token: String) -> InfisicalBinding {
        .init(id: access.rawValue, label: access.title, projectId: "project-A", environment: "qa",
              secretPath: "/apps/codecaps", access: access, serviceToken: token)
    }

    func testServiceTokenIsSentIntactWithoutLoginOrProjectMetadataRequests() async throws {
        let transport = MockInfisicalTransport()
        let token = "st.fixture-id.complete-secret-part"
        transport.handler = { method, url, headers, _ in
            XCTAssertEqual(method, "GET")
            XCTAssertTrue(url.path.contains("/api/v3/secrets/raw/"))
            XCTAssertEqual(headers["Authorization"], "Bearer " + token)
            return (Data(), 404)
        }
        let settings = InfisicalSettings(transport: transport)
        try await settings.validateAndConfigure(.init(readBinding: binding(.read, token: token)), persist: {})
        XCTAssertEqual(transport.calls.count, 3)
        XCTAssertFalse(settings.canWrite)
    }

    func testWriteUsesSeparateMatchingCredentialAndPreservesItsScopeForCreateFallback() async throws {
        let transport = MockInfisicalTransport()
        transport.handler = { method, url, headers, body in
            if method == "GET" {
                XCTAssertEqual(headers["Authorization"], "Bearer st.fixture.read-secret")
                return (Data(), 404)
            }
            XCTAssertEqual(headers["Authorization"], "Bearer st.fixture.write-secret")
            let fields = try XCTUnwrap(body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            XCTAssertEqual(fields["workspaceId"] as? String, "project-A")
            XCTAssertEqual(fields["environment"] as? String, "qa")
            XCTAssertEqual(fields["secretPath"] as? String, "/apps/codecaps")
            XCTAssertTrue(url.path.hasSuffix("PULL_ENDPOINT"))
            return (Data(), method == "PATCH" ? 404 : 200)
        }
        let settings = InfisicalSettings(transport: transport)
        let read = binding(.read, token: "st.fixture.read-secret")
        let write = binding(.write, token: "st.fixture.write-secret")
        try await settings.validateAndConfigure(.init(readBinding: read, writeBinding: write), persist: {})
        XCTAssertTrue(settings.canWrite)
        try await settings.set("https://quota.example/pull", for: InfisicalSettings.Keys.pullEndpoint)
        XCTAssertEqual(transport.methods, ["GET", "GET", "GET", "PATCH", "POST"])
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint), "https://quota.example/pull")
    }

    func testReadCredentialIsNeverInferredToAuthorizeWrites() async {
        let transport = MockInfisicalTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(.init(readBinding: binding(.read, token: "st.fixture.read-secret")))
        do {
            try await settings.set("value", for: InfisicalSettings.Keys.pullEndpoint)
            XCTFail("No selected write binding must fail")
        } catch InfisicalSettings.SettingsError.writeNotConfigured {} catch { XCTFail("Unexpected error") }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testWriteCannotCrossProjectEnvironmentFolderOrSite() async {
        let read = binding(.read, token: "st.fixture.read-secret")
        for mismatch in 0..<4 {
            var write = binding(.write, token: "st.fixture.write-secret")
            if mismatch == 0 { write.projectId = "project-B" }
            if mismatch == 1 { write.environment = "prod" }
            if mismatch == 2 { write.secretPath = "/another-folder" }
            if mismatch == 3 { write.siteURL = URL(string: "https://another.example")! }
            let transport = MockInfisicalTransport()
            let settings = InfisicalSettings(transport: transport)
            settings.configure(.init(readBinding: read, writeBinding: write))
            do { try await settings.set("value", for: InfisicalSettings.Keys.pullEndpoint); XCTFail("Mismatched scope must fail") }
            catch InfisicalSettings.SettingsError.writeNotConfigured {} catch { XCTFail("Unexpected error") }
            XCTAssertTrue(transport.calls.isEmpty)
        }
    }

    func testInvalidServiceTokensAndMissingSelectionsFailClosed() {
        for token in ["secret-only", "Bearer st.id.secret", "st..secret", "st.id.", "st.id.first\nsecond"] {
            XCTAssertThrowsError(try binding(.read, token: token).validate())
        }
        let read = binding(.read, token: "st.fixture.read-secret")
        XCTAssertThrowsError(try InfisicalSetup(bindings: [read], readBindingID: read.id, writeBindingID: "missing").validate())
        let write = binding(.write, token: "st.fixture.write-secret")
        XCTAssertThrowsError(try InfisicalSetup(bindings: [write], writeBindingID: write.id).validate())
        XCTAssertNoThrow(try InfisicalSetup(bindings: [read, write]).validate())
    }
    func testRetiredDisconnectCannotDeleteANewerSelectedSource() throws {
        let transport = MockInfisicalTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(.init(readBinding: binding(.read, token: "st.fixture.read-secret")))
        let retired = settings.beginSetupChange()
        var newer = binding(.read, token: "st.fixture.other-secret")
        newer.projectId = "project-B"
        settings.configure(.init(readBinding: newer))
        XCTAssertThrowsError(try settings.clearConfiguration(expectedRevision: retired) {
            XCTFail("A retired disconnect must not delete the current Keychain setup")
        }) { error in
            guard case InfisicalSettings.SettingsError.superseded = error else { return XCTFail("Expected superseded disconnect") }
        }
        XCTAssertEqual(settings.activeReadBinding?.projectId, "project-B")
        XCTAssertTrue(settings.isProvisioned)
        XCTAssertTrue(transport.calls.isEmpty)
    }

}
