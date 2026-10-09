import XCTest
@testable import QuotaCore

/// All fixtures are synthetic. This transport never leaves the process.
private actor ProjectSelectionTransport: InfisicalSettings.Transport {
    struct Request: Sendable {
        var method: String
        var path: String
        var project: String?
        var environment: String?
    }
    private(set) var requests: [Request] = []
    var projects: [String: [String]] = ["A": ["dev"], "B": ["dev"]]
    var values: [String: String] = ["A": "https://a.example/pull", "B": "https://b.example/pull"]
    var failure: (suffix: String, status: Int)?
    var pause: (suffix: String, project: String)?
    var paused = false
    var releaseContinuation: CheckedContinuation<Void, Never>?
    var pausedContinuations: [CheckedContinuation<Void, Never>] = []

    func setProjects(_ projects: [String: [String]]) { self.projects = projects }
    func setValues(_ values: [String: String]) { self.values = values }
    func fail(_ suffix: String, status: Int) { failure = (suffix, status) }
    func hold(_ suffix: String, project: String) { pause = (suffix, project) }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pausedContinuations.append($0) }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws
        -> (data: Data, statusCode: Int) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let payload = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let isProject = url.path.contains("/api/v1/projects/")
        let project = isProject ? url.lastPathComponent
            : query.first(where: { $0.name == "workspaceId" })?.value ?? payload?["workspaceId"] as? String
        let environment = query.first(where: { $0.name == "environment" })?.value ?? payload?["environment"] as? String
        requests.append(Request(method: method, path: url.path, project: project, environment: environment))
        let result: (Data, Int)
        if let failure, url.path.hasSuffix(failure.suffix) {
            result = (Data(), failure.status)
        } else if url.path.hasSuffix("/login") {
            result = (try JSONSerialization.data(withJSONObject: ["accessToken": "synthetic-token"]), 200)
        } else if isProject, let project, let environments = projects[project] {
            result = (try JSONSerialization.data(withJSONObject: ["project": [
                "id": project, "environments": environments.map { ["slug": $0] },
            ]]), 200)
        } else if isProject {
            result = (Data(), 404)
        } else if method == "GET", url.lastPathComponent == InfisicalSettings.Keys.pullEndpoint,
                  let project, let value = values[project] {
            result = (try JSONSerialization.data(withJSONObject: ["secret": [
                "secretKey": InfisicalSettings.Keys.pullEndpoint, "secretValue": value,
            ]]), 200)
        } else {
            result = (Data(), method == "GET" ? 404 : 200)
        }
        if let pause, url.path.hasSuffix(pause.suffix), project == pause.project {
            self.pause = nil
            paused = true
            pausedContinuations.forEach { $0.resume() }
            pausedContinuations = []
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return result
    }
}

private func projectConfiguration(_ project: String) -> InfisicalSettings.Configuration {
    .init(projectId: project, environment: "dev", clientId: "synthetic-id", clientSecret: "synthetic-secret")
}

final class InfisicalProjectSelectionTests: XCTestCase {
    func testSaveVerifiesProjectThenOnlyThreeNamedKeys() async throws {
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        try await settings.validateAndConfigure(projectConfiguration("B"), persist: {})
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "GET", "GET", "GET"])
        XCTAssertEqual(requests[1].path, "/api/v1/projects/B")
        XCTAssertEqual(requests.dropFirst(2).map(\.project), ["B", "B", "B"])
        XCTAssertTrue(requests.dropFirst(2).allSatisfy { $0.environment == "dev" && $0.path.contains("/secrets/raw/") })
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint), "https://b.example/pull")
    }

    func testMissingProjectOrEnvironmentNeverPersistsCandidate() async throws {
        for projects in [["A": ["dev"]], ["A": ["dev"], "B": ["prod"]]] {
            let transport = ProjectSelectionTransport()
            await transport.setProjects(projects)
            let settings = InfisicalSettings(transport: transport)
            settings.configure(projectConfiguration("A"))
            try await settings.load()
            let loadedAt = settings.lastLoadedAt
            do {
                try await settings.validateAndConfigure(projectConfiguration("B")) {
                    XCTFail("An unavailable destination must not reach persistence")
                }
                XCTFail("Expected failed project/environment validation")
            } catch {}
            XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint), "https://a.example/pull")
            XCTAssertEqual(settings.lastLoadedAt, loadedAt)
            try await settings.set("kept-A", for: InfisicalSettings.Keys.pullEndpoint)
            let requests = await transport.requests
            XCTAssertEqual(requests.last?.project, "A")
        }
    }

    func testBlankProjectIsRejectedBeforeNetworkOrPersistence() async throws {
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        for project in ["", " \n"] {
            do {
                try await settings.validateAndConfigure(projectConfiguration(project)) { XCTFail("Must not persist") }
                XCTFail("Expected blank project rejection")
            } catch InfisicalSettings.SettingsError.invalidDestination {} catch { XCTFail("Unexpected error: \(error)") }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(settings.isProvisioned)
    }

    func testExistingProjectWithNoManagedKeysIsValid() async throws {
        let transport = ProjectSelectionTransport()
        await transport.setValues([:])
        let settings = InfisicalSettings(transport: transport)
        try await settings.validateAndConfigure(projectConfiguration("B"), persist: {})
        XCTAssertTrue(settings.isProvisioned)
        XCTAssertTrue(settings.allValues().isEmpty)
    }

    func testLoginFailureKeepsActiveSetup() async throws {
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(projectConfiguration("A"))
        try await settings.load()
        await transport.fail("/login", status: 401)
        do {
            try await settings.validateAndConfigure(projectConfiguration("B")) { XCTFail("Must not persist") }
            XCTFail("Expected login failure")
        } catch {}
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint), "https://a.example/pull")
        XCTAssertNil(settings.lastError)
    }

    func testPersistenceFailureKeepsActiveSetupAndCache() async throws {
        struct PersistenceFailure: Error {}
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(projectConfiguration("A"))
        try await settings.load()
        do {
            try await settings.validateAndConfigure(projectConfiguration("B")) { throw PersistenceFailure() }
            XCTFail("Expected failed persistence")
        } catch is PersistenceFailure {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint), "https://a.example/pull")
        try await settings.set("still-A", for: InfisicalSettings.Keys.pullEndpoint)
        let requests = await transport.requests
        XCTAssertEqual(requests.last?.project, "A")
    }

    func testIdenticalConfigurationPreservesCacheButNewProjectClearsIt() async throws {
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(projectConfiguration("A"))
        try await settings.load()
        let revision = settings.revision
        settings.configure(projectConfiguration("A"))
        XCTAssertEqual(settings.revision, revision)
        XCTAssertNotNil(settings.lastLoadedAt)
        settings.configure(projectConfiguration("B"))
        XCTAssertTrue(settings.allValues().isEmpty)
        XCTAssertNil(settings.lastLoadedAt)
        XCTAssertNil(settings.lastError)
    }

    func testLateRefreshFromACannotReplaceB() async throws {
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(projectConfiguration("A"))
        await transport.hold("/PULL_ENDPOINT", project: "A")
        let old = Task { await settings.refresh() }
        await transport.waitUntilPaused()
        try await settings.validateAndConfigure(projectConfiguration("B"), persist: {})
        await transport.release()
        await old.value
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint), "https://b.example/pull")
        XCTAssertNil(settings.lastError)
    }

    func testRefreshStartedDuringValidationCannotReplaceCommittedProject() async throws {
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(projectConfiguration("A"))
        let candidateRevision = settings.beginSetupChange()
        await transport.hold("/PULL_ENDPOINT", project: "A")
        let old = Task { await settings.refresh() }
        await transport.waitUntilPaused()
        try await settings.validateAndConfigure(projectConfiguration("B"), revision: candidateRevision, persist: {})
        await transport.release()
        await old.value
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint), "https://b.example/pull")
        XCTAssertNil(settings.lastError)
    }

    func testLateErrorFromACannotReplaceBStatus() async throws {
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(projectConfiguration("A"))
        await transport.fail("/PULL_ENDPOINT", status: 503)
        await transport.hold("/PULL_ENDPOINT", project: "A")
        let old = Task { await settings.refresh() }
        await transport.waitUntilPaused()
        settings.configure(projectConfiguration("B"))
        await transport.release()
        await old.value
        XCTAssertNil(settings.lastError)
        XCTAssertTrue(settings.allValues().isEmpty)
    }

    func testLateSaveCannotPersistAfterBOrClear() async throws {
        for clear in [false, true] {
            let transport = ProjectSelectionTransport()
            let settings = InfisicalSettings(transport: transport)
            await transport.hold("/projects/A", project: "A")
            let old = Task {
                try await settings.validateAndConfigure(projectConfiguration("A")) { XCTFail("Stale save persisted") }
            }
            await transport.waitUntilPaused()
            if clear {
                settings.clearConfiguration()
            } else {
                try await settings.validateAndConfigure(projectConfiguration("B"), persist: {})
            }
            await transport.release()
            do { _ = try await old.value; XCTFail("Expected superseded save") }
            catch InfisicalSettings.SettingsError.superseded {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(settings.isProvisioned, !clear)
            XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint), clear ? nil : "https://b.example/pull")
        }
    }

    func testFailedClearPreservesSetupAndAllowsFreshRefresh() async throws {
        struct PersistenceFailure: Error {}
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(projectConfiguration("A"))
        try await settings.load()
        let retired = settings.revision
        XCTAssertThrowsError(try settings.clearConfiguration { throw PersistenceFailure() })
        XCTAssertFalse(settings.isCurrent(retired))
        XCTAssertTrue(settings.isProvisioned)
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint), "https://a.example/pull")
        // The UI's failure notification restarts the unchanged runtime setup.
        settings.configure(projectConfiguration("A"))
        await transport.setValues(["A": "https://a.example/refreshed"])
        await settings.refresh()
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint), "https://a.example/refreshed")
    }

    func testBatchWriteRejectsRetiredRevisionBeforeNetwork() async throws {
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(projectConfiguration("A"))
        let retired = settings.revision
        settings.configure(projectConfiguration("B"))
        do {
            try await settings.set("old-form", for: InfisicalSettings.Keys.pullEndpoint, expectedRevision: retired)
            XCTFail("Expected retired form to fail")
        } catch InfisicalSettings.SettingsError.superseded {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(settings.allValues().isEmpty)
    }

    func testLateWriteCannotPopulateBOrCreateAfterClear() async throws {
        let transport = ProjectSelectionTransport()
        let settings = InfisicalSettings(transport: transport)
        settings.configure(projectConfiguration("A"))
        await transport.hold("/PUSH_ENDPOINT", project: "A")
        await transport.fail("/PUSH_ENDPOINT", status: 404)
        let old = Task { try await settings.set("old-A", for: InfisicalSettings.Keys.pushEndpoint) }
        await transport.waitUntilPaused()
        settings.clearConfiguration()
        await transport.release()
        do { try await old.value; XCTFail("Expected superseded write") }
        catch InfisicalSettings.SettingsError.superseded {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(settings.allValues().isEmpty)
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.method == "POST" && $0.path.contains("/secrets/") })
    }
}
