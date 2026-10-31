import Foundation
@testable import JTKit
import JTKitTestSupport

/// A value shared between a test and the fake server’s handler.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    @discardableResult
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&stored) }
    }
}

/// Counts calls: `next()` returns 1, 2, 3…
final class Counter: @unchecked Sendable {
    private let count = Locked(0)
    var value: Int { count.value }

    func next() -> Int {
        count.withLock { $0 += 1; return $0 }
    }
}

/// Records waits instead of waiting.
final class SleepLog: @unchecked Sendable {
    private let waits = Locked<[Duration]>([])
    var recorded: [Duration] { waits.value }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        waits.withLock { $0.append(duration) }
    }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let current = Locked(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { current.value }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// The bearer token a client sends, without a sign-in.
struct FixedToken: BearerTokenSource {
    let tokens: Locked<[String]>
    let forgotten = Counter()

    init(_ values: String...) {
        tokens = Locked(values)
    }

    func token() async throws -> String {
        tokens.value.first ?? "token"
    }

    func forgetToken() async {
        _ = forgotten.next()
        tokens.withLock { if $0.count > 1 { $0.removeFirst() } }
    }
}

func tokenJSON(_ token: String, expiresIn: Int = 900) -> String {
    #"{"access_token":"\#(token)","expires_in":\#(expiresIn),"token_type":"Bearer"}"#
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

// MARK: - Confirmed commands

extension MDMCommand {
    /// The answer a person gives to the command’s confirmation (the typed
    /// count, the PIN twice), or nil for a command that needs none: what an
    /// app passes as `approval`.
    func answered(for targets: [Target], on product: Product, overPlatformAPI: Bool = false,
                  pin: String = "") throws -> Confirmation.Approval? {
        guard needsApproval(on: product) else { return nil }
        let confirmation = Confirmation(self, plan: plan(for: targets, on: product, overPlatformAPI: overPlatformAPI),
                                        on: product, connectionName: "Lab")
        return try confirmation.approve(typedCount: confirmation.typedCount.map(String.init) ?? "", pin: pin, pinAgain: pin)
    }
}

extension JamfPlatform.Client {
    /// Sends a command after answering its confirmation, as an app does.
    func sendConfirmed(_ command: MDMCommand, to targets: [MDMCommand.Target], pin: String = "") async throws -> MDMCommand.Result {
        let approval = try command.answered(for: targets, on: .jamfPro, overPlatformAPI: server == .platformAPI, pin: pin)
        return try await send(command, to: targets, approval: approval)
    }
}

extension JamfSchool.Client {
    /// Sends a command after answering its confirmation, as an app does.
    func sendConfirmed(_ command: MDMCommand, to targets: [MDMCommand.Target]) async throws -> MDMCommand.Result {
        try await send(command, to: targets, approval: try command.answered(for: targets, on: .jamfSchool))
    }
}

extension Graph.Client {
    /// Sends a command after answering its confirmation, as an app does.
    func sendConfirmed(_ command: MDMCommand, to targets: [MDMCommand.Target]) async throws -> MDMCommand.Result {
        try await send(command, to: targets, approval: try command.answered(for: targets, on: .intune))
    }

    /// Sends a command to one device after answering its confirmation.
    func performConfirmed(_ command: MDMCommand, intuneDeviceID id: String) async throws {
        let device = [MDMCommand.Target(serial: "S1", recordID: id, kind: .computer),
                      MDMCommand.Target(serial: "S2", recordID: id, kind: .mobileDevice)]
        let approval = command.intuneRequest(deviceID: "") == nil ? nil : try command.answered(for: device, on: .intune)
        try await perform(command, intuneDeviceID: id, approval: approval)
    }
}
