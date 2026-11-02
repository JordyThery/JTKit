import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

// 1.3.2: a command run stopped during a wait (Stop, `RequestWaits.cancelAll()`)
// keeps what it sent and marks the rest "not sent, stopped".

private let stoppedProServer = URL(string: "https://stopped.jamfcloud.example")!

/// Three mobile devices; the second answers 429, and the wait before its retry is stopped.
private let targets = (1...3).map {
    MDMCommand.Target(serial: "JTKTESTSTOP0\($0)", recordID: "\($0)", kind: .mobileDevice,
                      udid: "EEEEEEEE-0000-4000-8000-0000000000F\($0)", managementID: "mgmt-\($0)")
}

/// Answers 429 to the second device's request, 200 or 204 to the others.
private func server(secondPath: String) -> MockServer {
    MockServer { request in
        if request.path.hasSuffix("/token") { return .json(200, #"{"access_token":"t","expires_in":1200}"#) }
        return request.path.contains(secondPath) ? .json(429, "{}", headers: ["Retry-After": "40"]) : .json(200, "{}")
    }
}

/// The wait before a retry, stopped as `RequestWaits.cancelAll()` stops it.
private let stoppedWait: @Sendable (Duration) async throws -> Void = { _ in throw CancellationError() }

@MainActor
@Suite("A command stopped during a wait keeps what it sent")
struct StoppedCommandTests {
    private func check(_ result: MDMCommand.Result, server: MockServer, sentPaths: Int) {
        #expect(result.sent.map(\.serial) == ["JTKTESTSTOP01"])
        #expect(result.stopped.map(\.serial) == ["JTKTESTSTOP02", "JTKTESTSTOP03"])
        #expect(result.wasStopped)
        #expect(result.outcomes.allSatisfy { $0.outcome == .sent || $0.outcome == .skipped(.stopped) },
                "no device is marked failed")
        #expect(result.problems?.contains("JTKTESTSTOP02: not sent, stopped.") == true)
        #expect(server.requests.filter { !$0.path.hasSuffix("/token") }.count == sentPaths, "the third is never sent")
    }

    @Test func jamfSchool() async throws {
        let server = server(secondPath: "0000000000F2")
        let client = try JamfSchool.Client(address: "school.example.com/api/", networkID: "999001", apiKey: "KEY",
                                           recorder: RequestRecorder(session: server.session, log: nil, service: "Jamf School"),
                                           sleep: stoppedWait, random: { 0 })
        let schoolTargets = targets.map { MDMCommand.Target(serial: $0.serial, recordID: $0.udid ?? "", kind: $0.kind, udid: $0.udid) }
        let result = try await client.send(.updateInventory, to: schoolTargets, approval: nil)
        check(result, server: server, sentPaths: 2)
    }

    @Test func intune() async throws {
        let server = server(secondPath: "/managedDevices/2/")
        let client = Graph.Client(tokens: FixedToken("tok"), access: .application,
                                  recorder: Graph.recorder(session: server.session, log: nil, connection: "Contoso"),
                                  sleep: stoppedWait, random: { 0 })
        let result = try await client.send(.updateInventory, to: targets, approval: nil)
        check(result, server: server, sentPaths: 2)
    }

    @Test func jamfPro() async throws {
        let server = server(secondPath: "/UpdateInventory/id/2")
        ComputersAPIVersion.shared.set(.v4, for: stoppedProServer.absoluteString)
        let client = try JamfPlatform.Client(baseURL: stoppedProServer, scope: .organization, server: .jamfPro, signIn: .apiClient,
                                             tokens: FixedToken("tok"),
                                             recorder: RequestRecorder(session: server.session, log: nil, service: "Jamf Pro"),
                                             sleep: stoppedWait, random: { 0 })
        let result = try await client.send(.updateInventory, to: targets, approval: nil)
        check(result, server: server, sentPaths: 2)
    }

    @Test func theActionEntrySaysStoppedAndNamesWhatWasntSent() {
        let log = ActivityLog()
        log.recordCommand("Update Inventory", outcomes: [
            .init(target: targets[0], outcome: .sent),
            .init(target: targets[1], outcome: .skipped(.stopped)),
            .init(target: targets[2], outcome: .skipped(.stopped)),
        ], service: "Jamf School", connection: "Contoso")
        let entry = log.entries.last
        #expect(entry?.detail == "Update Inventory stopped: 1 sent, 2 not sent")
        #expect(entry?.note == "JTKTESTSTOP02: not sent, stopped\nJTKTESTSTOP03: not sent, stopped")
        #expect(entry?.isFailure == false)
        #expect(entry?.isWarning == true)
    }
}
