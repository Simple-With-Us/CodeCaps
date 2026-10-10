import XCTest
@testable import QuotaCore

/// A transport double that records every request and answers from a handler
/// the test controls.  Nothing here reaches the network.
final class MockInfisicalTransport: InfisicalSettings.Transport, @unchecked Sendable {
    struct Call {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?
    }

    var calls: [Call] = []
    var handler: (String, URL, [String: String], Data?) throws -> (Data, Int) =
        { _, _, _, _ in throw MockError.unexpected }

    enum MockError: Error {
        case unexpected
        case boom
    }

    func send(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?
    ) async throws -> (data: Data, statusCode: Int) {
        calls.append(Call(method: method, url: url, headers: headers, body: body))
        return try handler(method, url, headers, body)
    }

    var requestCount: Int { calls.count }
    var methods: [String] { calls.map(\.method) }
}

private func loginPayload(token: String = "tok-123") -> Data {
    try! JSONSerialization.data(withJSONObject: ["accessToken": token])
}

private func secretPayload(key: String, value: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "secret": ["secretKey": key, "secretValue": value],
    ])
}

private func configuredSettings(
    transport: MockInfisicalTransport,
    values: [String: String] = [:]
) -> InfisicalSettings {
    let settings = InfisicalSettings(transport: transport)
    settings.configure(InfisicalSettings.Configuration(
        projectId: "synthetic-project",
        environment: "prod",
        clientId: "test-client",
        clientSecret: "test-secret"
    ))
    transport.handler = { method, url, _, _ in
        if url.path.hasSuffix("/api/v1/auth/universal-auth/login"), method == "POST" {
            return (loginPayload(), 200)
        }
        if method == "GET", let key = url.pathComponents.last,
           url.path.contains("/api/v3/secrets/raw/") {
            guard let value = values[key] else { return (Data(), 404) }
            return (secretPayload(key: key, value: value), 200)
        }
        throw MockInfisicalTransport.MockError.unexpected
    }
    return settings
}

/// The fleet-wide Infisical SOT contract, proved against a mock transport:
/// startup load populates the cache, runtime reads never touch the network,
/// admin writes land in Infisical before the cache, and failures keep
/// last-known-good.
final class InfisicalSettingsTests: XCTestCase {

    func testLoadPopulatesCacheFromInfisical() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://quota.example.com/api/quota-windows",
            InfisicalSettings.Keys.refreshSeconds: "120",
        ])

        try await settings.load()

        XCTAssertEqual(
            settings.value(for: InfisicalSettings.Keys.pullEndpoint),
            "https://quota.example.com/api/quota-windows"
        )
        XCTAssertEqual(settings.refreshInterval, 120)
        XCTAssertNotNil(settings.lastLoadedAt)
        XCTAssertNil(settings.lastError)
        // One login plus three named reads — and nothing else.
        XCTAssertEqual(transport.methods, ["POST", "GET", "GET", "GET"])
        let requested = transport.calls.filter { $0.method == "GET" }.compactMap { $0.url.pathComponents.last }
        XCTAssertEqual(requested, [InfisicalSettings.Keys.pullEndpoint,
                                   InfisicalSettings.Keys.pushEndpoint,
                                   InfisicalSettings.Keys.refreshSeconds])
        XCTAssertTrue(transport.calls.filter { $0.method == "GET" }.allSatisfy {
            $0.url.path.contains("/api/v3/secrets/raw/") &&
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name == "secretPath" && $0.value == "/"
            } == true
        })
        XCTAssertNil(settings.value(for: "UNRELATED_SECRET"))
        XCTAssertEqual(Set(settings.allValues().keys),
                       Set([InfisicalSettings.Keys.pullEndpoint, InfisicalSettings.Keys.refreshSeconds]))
    }

    func testRuntimeReadsMakeZeroNetworkCallsAfterInit() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://quota.example.com/api/quota-windows",
        ])
        try await settings.load()
        let callsAfterLoad = transport.requestCount

        for _ in 0..<25 {
            _ = settings.value(for: InfisicalSettings.Keys.pullEndpoint)
            _ = settings.value(for: "SOME_OTHER_KEY")
            _ = settings.allValues()
            _ = settings.refreshInterval
        }

        XCTAssertEqual(transport.requestCount, callsAfterLoad,
                       "memory-only reads must not hit the network")
    }

    func testWriteThroughPatchesInfisicalBeforeUpdatingCache() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://old.example.com/api/quota-windows",
        ])
        try await settings.load()

        // Capture what the cache holds at the exact moment the PATCH leaves:
        // it must still be the OLD value, proving Infisical is written first.
        var patchSeen = false
        var cacheValueAtPatchTime: String?
        transport.handler = { method, url, _, _ in
            if url.path.hasSuffix("/api/v1/auth/universal-auth/login"), method == "POST" {
                return (loginPayload(), 200)
            }
            if method == "PATCH" {
                patchSeen = true
                cacheValueAtPatchTime = settings.value(for: InfisicalSettings.Keys.pullEndpoint)
                return (Data(), 200)
            }
            throw MockInfisicalTransport.MockError.unexpected
        }

        try await settings.set("https://new.example.com/api/quota-windows",
                               for: InfisicalSettings.Keys.pullEndpoint)

        XCTAssertTrue(patchSeen)
        XCTAssertEqual(cacheValueAtPatchTime, "https://old.example.com/api/quota-windows",
                       "the cache must not move before the Infisical write succeeds")
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint),
                       "https://new.example.com/api/quota-windows")
    }

    func testWriteThroughCreatesMissingSecretWithPost() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport)
        try await settings.load()

        transport.handler = { method, url, _, _ in
            if url.path.hasSuffix("/api/v1/auth/universal-auth/login"), method == "POST" {
                return (loginPayload(), 200)
            }
            if method == "PATCH" { return (Data(), 404) }
            if method == "POST", url.path.contains("/api/v3/secrets/") { return (Data(), 201) }
            throw MockInfisicalTransport.MockError.unexpected
        }

        try await settings.set("300", for: InfisicalSettings.Keys.refreshSeconds)

        XCTAssertEqual(transport.methods.filter { $0 == "PATCH" }.count, 1)
        // login (load) + login (set) + create = 3 POSTs.
        XCTAssertEqual(transport.methods.filter { $0 == "POST" }.count, 3)
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.refreshSeconds), "300")
    }

    func testFailedRefreshKeepsLastKnownGood() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://quota.example.com/api/quota-windows",
        ])
        try await settings.load()

        transport.handler = { _, _, _, _ in throw MockInfisicalTransport.MockError.boom }
        await settings.refresh() // never throws

        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint),
                       "https://quota.example.com/api/quota-windows",
                       "a failed refresh must keep serving the last-known-good cache")
        XCTAssertNotNil(settings.lastError)
    }

    func testLaterNamedReadFailureKeepsEntirePreviousCache() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://old.example.com/pull",
            InfisicalSettings.Keys.pushEndpoint: "https://old.example.com/push",
        ])
        try await settings.load()
        let loadedAt = settings.lastLoadedAt

        transport.handler = { method, url, _, _ in
            if method == "POST", url.path.hasSuffix("/api/v1/auth/universal-auth/login") {
                return (loginPayload(), 200)
            }
            if method == "GET", url.path.hasSuffix("/PULL_ENDPOINT") {
                return (secretPayload(key: InfisicalSettings.Keys.pullEndpoint,
                                      value: "https://new.example.com/pull"), 200)
            }
            if method == "GET", url.path.hasSuffix("/PUSH_ENDPOINT") { return (Data(), 503) }
            throw MockInfisicalTransport.MockError.unexpected
        }

        await settings.refresh()

        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint),
                       "https://old.example.com/pull")
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pushEndpoint),
                       "https://old.example.com/push")
        XCTAssertEqual(settings.lastLoadedAt, loadedAt)
        XCTAssertNotNil(settings.lastError)
    }

    func testUnrelatedSecretIsNeverRequestedOrCached() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            "UNRELATED_SECRET": "must-stay-unread",
            InfisicalSettings.Keys.pullEndpoint: "https://quota.example.com/pull",
        ])

        try await settings.load()

        XCTAssertFalse(transport.calls.contains { $0.url.path.contains("UNRELATED_SECRET") })
        XCTAssertNil(settings.value(for: "UNRELATED_SECRET"))
        XCTAssertFalse(settings.allValues().keys.contains("UNRELATED_SECRET"))
    }

    func testFailedWriteThroughRejectsAndLeavesCacheUntouched() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://old.example.com/api/quota-windows",
        ])
        try await settings.load()

        transport.handler = { method, url, _, _ in
            if url.path.hasSuffix("/api/v1/auth/universal-auth/login"), method == "POST" {
                return (loginPayload(), 200)
            }
            if method == "PATCH" { return (Data(), 500) }
            throw MockInfisicalTransport.MockError.unexpected
        }

        do {
            try await settings.set("https://new.example.com/api/quota-windows",
                                   for: InfisicalSettings.Keys.pullEndpoint)
            XCTFail("a failed Infisical write must fail the save")
        } catch {
            // Expected: the save is rejected.
        }

        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint),
                       "https://old.example.com/api/quota-windows",
                       "a failed write must not move the cache")
    }

    func testLoadWithoutProvisionedIdentityThrows() async {
        let transport = MockInfisicalTransport()
        let settings = InfisicalSettings(transport: transport)

        do {
            try await settings.load()
            XCTFail("load without an identity must throw")
        } catch {
            XCTAssertTrue(error is InfisicalSettings.SettingsError)
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testRefreshWithoutProvisionedIdentityIsANoOp() async {
        let transport = MockInfisicalTransport()
        let settings = InfisicalSettings(transport: transport)

        await settings.refresh()

        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertNil(settings.lastError)
    }

    func testEmptyValuesAreTreatedAsAbsent() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pushEndpoint: "",
        ])
        try await settings.load()

        XCTAssertNil(settings.value(for: InfisicalSettings.Keys.pushEndpoint))
    }

    func testRefreshIntervalDefaultsAndClamps() async throws {
        let transport = MockInfisicalTransport()

        // Absent → default.
        var settings = configuredSettings(transport: transport)
        try await settings.load()
        XCTAssertEqual(settings.refreshInterval, InfisicalSettings.defaultRefreshInterval)

        // Parseable → honoured.
        settings = configuredSettings(transport: transport,
                                      values: [InfisicalSettings.Keys.refreshSeconds: "120"])
        try await settings.load()
        XCTAssertEqual(settings.refreshInterval, 120)

        // Unparseable → default.
        settings = configuredSettings(transport: transport,
                                      values: [InfisicalSettings.Keys.refreshSeconds: "soon"])
        try await settings.load()
        XCTAssertEqual(settings.refreshInterval, InfisicalSettings.defaultRefreshInterval)

        // Absurdly small → clamped, so a typo cannot hot-loop the timer.
        settings = configuredSettings(transport: transport,
                                      values: [InfisicalSettings.Keys.refreshSeconds: "5"])
        try await settings.load()
        XCTAssertEqual(settings.refreshInterval, InfisicalSettings.minimumRefreshInterval)
    }

    /// The dev and staging environments are retired (owner, 2026-10-10), so
    /// every build variant, `.dev` included, reads prod.
    func testDefaultEnvironmentIsProdForEveryBuild() {
        XCTAssertEqual(InfisicalSettings.defaultEnvironment(), "prod")
    }

    func testNonProdEnvironmentIsRefusedBeforeAnyRequest() async throws {
        for environment in ["dev", "staging", "production", ""] {
            let transport = MockInfisicalTransport()
            let settings = InfisicalSettings(transport: transport)
            settings.configure(InfisicalSettings.Configuration(
                projectId: "synthetic-project",
                environment: environment,
                clientId: "test-client",
                clientSecret: "test-secret"
            ))
            do {
                try await settings.load()
                XCTFail("Expected a refusal for environment \"\(environment)\"")
            } catch InfisicalSettings.SettingsError.invalidDestination {
            }
            do {
                try await settings.validateAndConfigure(InfisicalSettings.Configuration(
                    projectId: "synthetic-project",
                    environment: environment,
                    clientId: "test-client",
                    clientSecret: "test-secret"
                ), persist: {})
                XCTFail("Expected a refusal for environment \"\(environment)\"")
            } catch InfisicalSettings.SettingsError.invalidDestination {
            }
            XCTAssertTrue(transport.calls.isEmpty, "no request may go out for \"\(environment)\"")
        }
    }

    func testClearConfigurationEmptiesCache() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://quota.example.com/api/quota-windows",
        ])
        try await settings.load()
        XCTAssertTrue(settings.isProvisioned)

        settings.clearConfiguration()

        XCTAssertFalse(settings.isProvisioned)
        XCTAssertNil(settings.value(for: InfisicalSettings.Keys.pullEndpoint))
    }
}
