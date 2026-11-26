import Foundation
import XCTest
@testable import QuotaCore

final class EndpointPluginTests: XCTestCase {
    private func descriptor(
        id: String = "plugin:acme", providerKey: String = "acme-plan",
        endpoint: String = "https://api.example.com/usage",
        auth: EndpointPluginDescriptor.Auth = .init(type: .none)
    ) -> EndpointPluginDescriptor {
        EndpointPluginDescriptor(
            id: id, displayName: "Acme Plan", providerKey: providerKey, endpoint: endpoint,
            auth: auth,
            windows: [.init(idSuffix: "monthly", label: "Monthly", window: "monthly",
                            usedPercentPath: "usage.monthly.percent",
                            resetAtPath: "usage.monthly.resetsAt")])
    }

    func testValidDescriptorPasses() throws {
        XCTAssertNoThrow(try descriptor().validated())
    }

    func testReservedAndMalformedDescriptorsAreRefused() {
        XCTAssertThrowsError(try descriptor(providerKey: "kimi").validated())
        XCTAssertThrowsError(try descriptor(id: "acme").validated())
        XCTAssertThrowsError(try descriptor(providerKey: "Acme Plan").validated())
        XCTAssertThrowsError(try descriptor(auth: .init(type: .bearerEnv, env: "1BAD-NAME")).validated())
        XCTAssertThrowsError(try descriptor(auth: .init(type: .none, env: "SECRET")).validated())
    }

    func testEndpointSSRFMatrix() {
        let refused = [
            "http://api.example.com/usage",
            "https://user:pass@api.example.com/usage",
            "https://api.example.com/usage?token=x",
            "https://169.254.169.254/latest/meta-data",
            "https://10.0.0.5/usage",
            "https://172.16.0.5/usage",
            "https://192.168.1.5/usage",
            "https://[::1]/usage",
            "https://0x7f.0.0.1/usage",
            "https://0177.0.0.1/usage",
            "https://2130706433/usage",
            "https://08.8.8.8/usage",
            "ftp://api.example.com/usage",
        ]
        for endpoint in refused {
            XCTAssertThrowsError(try descriptor(endpoint: endpoint).validated(), endpoint)
        }
        XCTAssertNoThrow(try descriptor(endpoint: "https://8.8.8.8/usage").validated())
    }

    func testExternalHostKeepsDefaultPortEvenWithLoopbackOptIn() throws {
        var external = descriptor(endpoint: "https://8.8.8.8:8080/usage")
        external.allowLoopback = true
        XCTAssertThrowsError(try external.validated())
    }

    func testBothPercentPathsAreRefusedEvenWithAbsolutes() {
        var both = descriptor()
        both.windows[0].remainingPercentPath = "usage.monthly.remaining"
        both.windows[0].absoluteRemainingPath = "usage.monthly.left"
        both.windows[0].absoluteLimitPath = "usage.monthly.total"
        XCTAssertThrowsError(try both.validated())
    }

    func testBadDisplayNameHasItsOwnError() {
        var bad = descriptor()
        bad.displayName = ""
        XCTAssertThrowsError(try bad.validated()) { error in
            XCTAssertEqual(error as? EndpointPluginDescriptor.ValidationError, .badDisplayName)
        }
    }

    func testNonPluginEnvNameIsRefused() {
        XCTAssertThrowsError(try descriptor(auth: .init(type: .bearerEnv, env: "AWS_SECRET_ACCESS_KEY")).validated())
        XCTAssertNoThrow(try descriptor(auth: .init(type: .bearerEnv, env: "CODECAPS_PLUGIN_ACME_API_KEY")).validated())
    }

    func testLoopbackNeedsExplicitOptIn() throws {
        XCTAssertThrowsError(try descriptor(endpoint: "http://127.0.0.1:8080/usage").validated())
        var loopback = descriptor(endpoint: "http://127.0.0.1:8080/usage")
        loopback.allowLoopback = true
        XCTAssertNoThrow(try loopback.validated())
    }

    func testJSONPathGrammar() {
        XCTAssertTrue(EndpointJSONPath.isValid("usage.monthly.percent"))
        XCTAssertTrue(EndpointJSONPath.isValid("items[0].remaining"))
        XCTAssertFalse(EndpointJSONPath.isValid("usage..percent"))
        XCTAssertFalse(EndpointJSONPath.isValid("usage.*.percent"))
        XCTAssertFalse(EndpointJSONPath.isValid("a b"))
        let root: [String: Any] = ["items": [["remaining": 42]]]
        XCTAssertEqual(EndpointJSONPath.number(root, path: "items[0].remaining"), 42)
    }

    func testGenericReaderMapsUsedPercentAndReset() async {
        let reader = GenericEndpointQuotaReader(
            descriptor: descriptor(),
            environment: [:],
            now: { Date(timeIntervalSince1970: 0) },
            fetch: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.example.com/usage")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"usage":{"monthly":{"percent":25,"resetsAt":"2026-12-01T00:00:00Z"}}}"#.utf8), response)
            })
        let result = await reader.read()
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.providerKey, "acme-plan")
        XCTAssertEqual(result.windows.first?.remainingPercent, 75)
        XCTAssertEqual(result.windows.first?.resetAt, "2026-12-01T00:00:00Z")
        XCTAssertEqual(result.windows.first?.source, "plugin:acme")
    }

    func testGenericReaderDropsOutOfRangePercent() async {
        let reader = GenericEndpointQuotaReader(
            descriptor: descriptor(), environment: [:],
            now: { Date(timeIntervalSince1970: 0) },
            fetch: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.example.com/usage")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"usage":{"monthly":{"percent":140}}}"#.utf8), response)
            })
        let result = await reader.read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["acme-plan"], "Acme Plan returned no readable quota.")
    }

    func testGenericReaderMissingEnvKeyReportsSignIn() async {
        let reader = GenericEndpointQuotaReader(
            descriptor: descriptor(auth: .init(type: .bearerEnv, env: "CODECAPS_PLUGIN_ACME_KEY")),
            environment: [:],
            fetch: { _ in XCTFail("fetch must not run without the configured key"); throw URLError(.badURL) })
        let result = await reader.read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["acme-plan"], "Acme Plan plugin needs the CODECAPS_PLUGIN_ACME_KEY environment variable set.")
    }

    func testLoaderSkipsInvalidAndDuplicateFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("endpoint-plugin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoder = JSONEncoder()
        try encoder.encode(descriptor()).write(to: dir.appendingPathComponent("a.json"))
        try encoder.encode(descriptor()).write(to: dir.appendingPathComponent("b.json"))
        try Data(#"{"id":"plugin:broken"}"#.utf8).write(to: dir.appendingPathComponent("c.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("d.json"))
        let loaded = EndpointPluginLoader.load(directory: dir)
        XCTAssertEqual(loaded.map(\.id), ["plugin:acme"])
    }

    func testDisabledPluginFactoryIsNeverInvoked() async {
        let descriptor = try! descriptor().validated()
        let registry = LocalQuotaReaderRegistry(
            registrations: EndpointPluginLoader.registrations(descriptors: [descriptor], environment: [:]))
        var preferences = QuotaReaderPreferences()
        preferences.setEnabled(false, for: "plugin:acme")
        let result = await registry.read(preferences: preferences)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }
}
