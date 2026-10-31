import Foundation

// Jamf School’s commands, Move to Trash and moving location. One device resource serves Macs and mobile devices alike.
// A command is never repeated after a server error, only after a 429; a
// failure can come under HTTP 200 (`JamfSchool.APIError.check`).

extension JamfSchool {
    /// What became of each device in a location move. The move reports per
    /// device inside a success, so these are read rather than the status.
    public struct MoveOutcome: Sendable, Hashable {
        public var moved: [String] = []
        public var notFound: [String] = []
        /// Already in that location; not a failure.
        public var alreadyThere: [String] = []
        public var failed: [String] = []

        public init() {}

        /// UDIDs that didn’t end up where they were asked to go.
        public var unmoved: [String] { notFound + failed }
    }

    /// Jamf School takes at most twenty devices per move.
    static let moveBatchSize = 20
}

extension JamfSchool.Client {
    /// Sends a command to the devices it applies to, one request per device
    /// (`devices/{udid}/refresh`, `restart`, `wipe`, `unenroll`). The fields
    /// the endpoints require are sent and always false: restarting never
    /// clears the passcode, wiping never clears Activation Lock.
    ///
    /// - Parameter approval: the answered confirmation, from
    ///   `MDMCommand.Confirmation.approve(...)`. Required for Wipe and Remove
    ///   MDM Profile (`needsApproval(on:)`), and then for exactly this
    ///   command on Jamf School and the devices that receive it.
    /// - Throws: `MDMCommand.Refusal` for a command Jamf School doesn’t have,
    ///   and for no or another approval; `CancellationError`.
    public func send(_ command: MDMCommand, to targets: [MDMCommand.Target],
                     approval: MDMCommand.Confirmation.Approval?) async throws -> MDMCommand.Result {
        try command.check(approval, on: .jamfSchool, receiving: command.plan(for: targets, on: .jamfSchool).receiving.count)
        return try await sendCommand(command, to: targets)
    }

    @available(*, deprecated, message: "Confirm with MDMCommand.Confirmation and pass its approve(...) to send(_:to:approval:).")
    public func send(_ command: MDMCommand, to targets: [MDMCommand.Target]) async throws -> MDMCommand.Result {
        try await sendCommand(command, to: targets)
    }

    private func sendCommand(_ command: MDMCommand, to targets: [MDMCommand.Target]) async throws -> MDMCommand.Result {
        let action: String
        let form: String?
        switch command {
        case .updateInventory: (action, form) = ("refresh", nil)
        case .restartMobile: (action, form) = ("restart", "clearPasscode=false")
        case .wipeComputer, .wipeMobile: (action, form) = ("wipe", "clearActivationLock=false")
        case .unmanage: (action, form) = ("unenroll", nil)
        default: throw MDMCommand.Refusal("\(command.title) isn’t available in Jamf School.")
        }
        let plan = command.plan(for: targets, on: .jamfSchool)
        var run = CommandRun(targets: targets, command: command.title)
        for skip in plan.skipped { run.set(skip.target, .skipped(skip.reason)) }
        for target in plan.receiving {
            try await run.each(target) {
                let udid = try Self.validatedUDID(target.recordID)
                _ = try await send(HTTPRequest(method: "POST", path: "api/devices/\(udid)/\(action)",
                                               body: form.map { Data($0.utf8) },
                                               contentType: form == nil ? nil : "application/x-www-form-urlencoded; charset=utf-8"))
                return .sent
            }
        }
        return run.result
    }

    /// Moves a device’s record to the trash (`DELETE devices/{udid}/`, with
    /// the trailing slash the API documents). Unlike Jamf Pro’s delete it can
    /// be restored in Jamf School; the device stops being managed.
    public func trash(udid: String) async throws {
        let safe = try Self.validatedUDID(udid)
        _ = try await send(HTTPRequest(method: "DELETE", path: "api/devices/\(safe)/"))
    }

    /// Moves devices to another location (`PUT devices/migrate`, JSON), in
    /// batches of twenty. Always the bulk endpoint, also for one device: the
    /// single-device one takes an identifier documented nowhere.
    ///
    /// A device with an assigned owner can only move when the owner is in the
    /// district or Cross Location Enrollment is on; Jamf School then reports
    /// it under `failed`, inside a success.
    @discardableResult
    public func move(udids: [String], toLocation locationID: String) async throws -> JamfSchool.MoveOutcome {
        struct Answer: Decodable {
            let devicesMoved: [String]?
            let devicesNotFound: [String]?
            let devicesLocationSame: [String]?
            let devicesMoveFailed: [String]?
        }
        let safe = try udids.map(Self.validatedUDID)
        var outcome = JamfSchool.MoveOutcome()
        for start in stride(from: 0, to: safe.count, by: JamfSchool.moveBatchSize) {
            let batch = Array(safe[start..<min(start + JamfSchool.moveBatchSize, safe.count)])
            // JSON, not a form: a form-encoded PUT arrives empty (UDIDArrayEmpty)
            let body = try JSONSerialization.data(withJSONObject: ["udids": batch, "locationId": locationID] as [String: Any])
            let data = try await send(HTTPRequest(method: "PUT", path: "api/devices/migrate", body: body,
                                                  contentType: "application/json"))
            let answer = try? JSONDecoder().decode(Answer.self, from: data)
            outcome.moved += answer?.devicesMoved ?? []
            outcome.notFound += answer?.devicesNotFound ?? []
            outcome.alreadyThere += answer?.devicesLocationSame ?? []
            outcome.failed += answer?.devicesMoveFailed ?? []
        }
        return outcome
    }

    static func validatedUDID(_ value: String) throws -> String {
        do {
            return try JamfPro.validatedIdentifier(value)
        } catch {
            throw JamfSchool.APIError(.invalidIdentifier(String(value.prefix(64))))
        }
    }
}
