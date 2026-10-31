import Foundation
import Testing
@testable import JTKit

// The shared "under tests" pieces the apps had copies of: the launch checks,
// the attempt log and the refusing session.

@Suite("Under tests: launch checks, attempt log, refusing session")
struct TestRunTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "JTKitTestRunTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("A sandbox launch is -JTKitSandbox YES, true or 1; the unit-test host is Xcode’s test configuration")
    func launches() {
        #expect(DemoMode.isSandboxLaunch(["app", "-JTKitSandbox", "YES"]))
        #expect(DemoMode.isSandboxLaunch(["app", "-JTKitSandbox", "1"]))
        #expect(!DemoMode.isSandboxLaunch(["app", "-JTKitSandbox", "NO"]))
        #expect(!DemoMode.isSandboxLaunch(["app", "-JTKitSandbox"]))
        #expect(!DemoMode.isSandboxLaunch(["app"]))

        #expect(TestRun.isUnitTestHost(environment: ["XCTestConfigurationFilePath": "/x"]))
        #expect(TestRun.isUnitTestHost(environment: ["XCTestBundlePath": "/x"]))
        #expect(!TestRun.isUnitTestHost(environment: [:]))
        #expect(TestRun.isActive(environment: ["XCTestSessionIdentifier": "s"], arguments: ["app"]))
        #expect(TestRun.isActive(environment: [:], arguments: ["app", "-JTKitSandbox", "true"]))
        #expect(!TestRun.isActive(environment: [:], arguments: ["app", "-JTKitSandbox", "NO"]))
    }

    @Test("The attempt log appends one JSON line per attempt and reads them all back")
    func attemptLog() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = TestRun.AttemptLog(fileURL: folder.appending(path: "commands.jsonl"))
        #expect(log.attempts().isEmpty)
        log.record("Wipe Computer (Jamf Pro), 1 device")
        TestRun.AttemptLog(fileURL: log.fileURL).record("Lock Device (Intune), 2 devices")
        #expect(log.attempts().map(\.what) == ["Wipe Computer (Jamf Pro), 1 device", "Lock Device (Intune), 2 devices"])
        #expect(log.attempts().allSatisfy { ["unit test host", "UI test run"].contains($0.process) })
        #expect(TestRun.attemptsFolder(named: "App-under-test").lastPathComponent == "App-under-test")
        #expect(TestRun.Refusal("Refused under tests.").localizedDescription == "Refused under tests.")
    }

    @Test("The refusing session sends nothing: method, host and path are written down, never the query")
    func refusingSession() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = TestRun.AttemptLog(fileURL: folder.appending(path: "saved-connection-requests.jsonl"))
        let session = TestRun.refusingSession(log: log, kind: "Graph", message: "Refused under tests: no saved tenant.")
        let url = try #require(URL(string: "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$filter=serialNumber%20eq%20'C02'"))
        do {
            _ = try await session.data(from: url)
            Issue.record("A request was answered")
        } catch let error as URLError {
            #expect(error.code == .resourceUnavailable)
            #expect(error.localizedDescription == "Refused under tests: no saved tenant.")
        }
        let attempts = log.attempts()
        #expect(attempts.map(\.what) == ["Graph: GET graph.microsoft.com/v1.0/deviceManagement/managedDevices"])
        #expect(!(attempts.first?.what.contains("C02") ?? true))

        // without a kind, as the saved-connection guards write it
        let plain = TestRun.refusingSession(log: log, message: "Refused.")
        _ = try? await plain.data(from: try #require(URL(string: "https://jamf.example.com/api/v1/auth/token")))
        #expect(log.attempts().last?.what == "GET jamf.example.com/api/v1/auth/token")
    }
}
