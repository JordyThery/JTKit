import Foundation

// Sending MDM commands to Jamf Pro, and deleting device records: the
// routing Checkpoint built, moved into JTKit with its tests (ROADMAP step 7).
// Each command goes where Jamf Pro carries it:
// - Lock, Restart, Shut Down: `v2/mdm/commands`, one request per kind of
//   device. Over the Platform API, Restart and Shut Down use its device
//   actions instead, after looking the device up by serial.
// - Wipe, Remove MDM Profile, Redeploy Framework: one request per device.
// - Renew MDM Profile, Blank Push: one request for all, which can answer
//   success and still name devices it didn't process.
// - Clear Passcode: the unlock token is read per device, then sent.
// - Update Inventory: the Classic API's mobile device command.
//
// Commands are never repeated after a server error (they are writes); only a
// 429 is retried, when nothing was done. The requests that carry a PIN or an
// unlock token are never recorded with their contents (`SensitiveRequests`).

extension JamfPlatform.Client {
    /// Sends a command to the devices it applies to.
    ///
    /// - Parameter pin: six digits, for Lock and Wipe Computer.
    /// - Returns: what became of the command on each device, in the order given.
    /// - Throws: `MDMCommand.Refusal` when nothing is sent at all (not over
    ///   the Platform API, no PIN, no device with what the address needs);
    ///   `CancellationError`.
    public func send(_ command: MDMCommand, to targets: [MDMCommand.Target], pin: String? = nil) async throws -> MDMCommand.Result {
        let overPlatformAPI = server == .platformAPI
        if overPlatformAPI && !command.worksOverPlatformAPI {
            throw MDMCommand.Refusal(MDMCommand.unavailableOverPlatformAPI)
        }
        if command.needsPIN(on: .jamfPro), !MDMCommand.Confirmation.isValidPIN(pin ?? "") {
            throw MDMCommand.Refusal("The PIN must be exactly 6 digits.")
        }
        let plan = command.plan(for: targets, on: .jamfPro, overPlatformAPI: overPlatformAPI)
        if plan.receiving.isEmpty && !plan.applicable.isEmpty {
            switch command {
            case .renewProfile: throw MDMCommand.Refusal("No device UDIDs are known, so the MDM profile cannot be renewed.")
            case .blankPush: throw MDMCommand.Refusal("No management IDs are known, so a blank push cannot be sent. Run a fresh lookup first.")
            default: break
            }
        }

        var run = CommandRun(targets: targets, command: command.title)
        for skip in plan.skipped { run.set(skip.target, .skipped(skip.reason)) }
        let receiving = plan.receiving

        switch command {
        case .renewProfile:
            try await renewProfile(receiving, &run)
        case .blankPush:
            try await blankPush(receiving, &run)
        case .clearPasscode:
            for target in receiving {
                try await run.each(target) {
                    guard let token = try await unlockToken(mobileDeviceID: target.recordID) else {
                        return .failed("Jamf Pro has no escrowed unlock token for this device, so the passcode cannot be cleared.")
                    }
                    try await modernCommand(["commandType": "CLEAR_PASSCODE", "unlockToken": token],
                                            managementIDs: [target.managementID ?? ""], privilege: command.privilege(for: .mobileDevice))
                    return .sent
                }
            }
        case .restartMobile where overPlatformAPI, .shutDownMobile where overPlatformAPI:
            for target in receiving {
                try await run.each(target) {
                    do {
                        guard let device = try await device(serial: target.serial) else {
                            return .failed("not in the platform device inventory.")
                        }
                        if command == .restartMobile {
                            try await restart(deviceID: device.id)
                        } else {
                            try await shutDown(deviceID: device.id)
                        }
                        return .sent
                    } catch let mismatch as JamfPlatform.DeviceMismatch {
                        return .failed("\(mismatch.localizedDescription) No command was sent.")
                    }
                }
            }
        case .wipeComputer, .wipeMobile, .unmanage, .redeployFramework, .updateInventory:
            for target in receiving {
                try await run.each(target) {
                    try await perDevice(command, target, pin: pin)
                    return .sent
                }
            }
        case .lockComputer, .lockMobile, .restartMobile, .shutDownMobile:
            for kind in [MDMCommand.DeviceKind.computer, .mobileDevice] {
                let batch = receiving.filter { $0.kind == kind }
                guard !batch.isEmpty else { continue }
                var data: [String: any Sendable] = ["commandType": Self.commandType(command)]
                if command == .lockComputer, let pin { data["pin"] = pin }
                do {
                    try await modernCommand(data, managementIDs: batch.compactMap(\.managementID),
                                            privilege: command.privilege(for: kind))
                    for target in batch { run.set(target, .sent) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    for target in batch { run.set(target, .failed(error.localizedDescription)) }
                }
            }
        }
        return run.result
    }

    /// Deletes a computer's record (`v4/computers-inventory/{id}`). Can't be
    /// undone. Needs “Delete Computers”.
    public func deleteComputer(id: String) async throws {
        _ = try await sendThrowing(HTTPRequest(method: "DELETE", path: "pro/v4/computers-inventory/\(JamfPlatform.pathSegment(id))"),
                                   privilege: .deleteComputers)
    }

    /// Deletes a mobile device's record, through the Classic API (Jamf Pro
    /// has no other way). Can't be undone. Needs “Delete Mobile Devices”.
    public func deleteMobileDevice(id: String) async throws {
        _ = try await sendThrowing(HTTPRequest(method: "DELETE", path: JamfClassic.path("mobiledevices", id: id),
                                               accept: "application/json"),
                                   privilege: .deleteMobileDevices)
    }

    // MARK: Private

    private static func commandType(_ command: MDMCommand) -> String {
        switch command {
        case .lockComputer, .lockMobile: "DEVICE_LOCK"
        case .restartMobile: "RESTART_DEVICE"
        default: "SHUT_DOWN_DEVICE"
        }
    }

    private func perDevice(_ command: MDMCommand, _ target: MDMCommand.Target, pin: String?) async throws {
        let id = JamfPlatform.pathSegment(target.recordID)
        let privilege = command.privilege(for: target.kind)
        let request: HTTPRequest
        switch (command, target.kind) {
        case (.wipeComputer, _):
            request = HTTPRequest(method: "POST", path: "pro/v4/computers-inventory/\(id)/erase",
                                  body: try JSONSerialization.data(withJSONObject: pin.map { ["pin": $0] } ?? [:]))
        case (.wipeMobile, _):
            request = HTTPRequest(method: "POST", path: "pro/v2/mobile-devices/\(id)/erase",
                                  body: try JSONSerialization.data(withJSONObject: [String: String]()))
        case (.unmanage, .computer):
            request = HTTPRequest(method: "POST", path: "pro/v4/computers-inventory/\(id)/remove-mdm-profile")
        case (.unmanage, .mobileDevice):
            request = HTTPRequest(method: "POST", path: "pro/v2/mobile-devices/\(id)/unmanage")
        case (.redeployFramework, _):
            request = HTTPRequest(method: "POST", path: "pro/v1/jamf-management-framework/redeploy/\(id)")
        default:
            // Update Inventory: the one command still on the Classic API
            request = HTTPRequest(method: "POST", path: "proclassic/mobiledevicecommands/command/UpdateInventory/id/\(id)",
                                  accept: "application/json")
        }
        _ = try await sendThrowing(request, privilege: privilege)
    }

    /// `v2/mdm/commands`. Jamf Pro's API description names only “View MDM
    /// command information in Jamf Pro API” for it; Jamf Pro also checks the
    /// command's own privilege, so a refusal names both.
    private func modernCommand(_ data: [String: any Sendable], managementIDs: [String], privilege: JamfPro.Privilege) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "clientData": managementIDs.map { ["managementId": $0] },
            "commandData": data,
        ] as [String: Any])
        let privileges = privilege == .viewMDMCommandInformation ? [privilege] : [.viewMDMCommandInformation, privilege]
        _ = try await sendThrowing(HTTPRequest(method: "POST", path: "pro/v2/mdm/commands", body: body), privileges: privileges)
    }

    /// Read when the command is sent, never during a lookup; the call is
    /// recorded without contents.
    private func unlockToken(mobileDeviceID id: String) async throws -> String? {
        struct Detail: Decodable {
            let ios, tvos, watchos, visionos: OS?
            struct OS: Decodable { let unlockToken: String? }
        }
        let response = try await sendThrowing(HTTPRequest(path: "pro/v2/mobile-devices/\(JamfPlatform.pathSegment(id))/detail"),
                                              privilege: .readMobileDevices)
        guard let detail = try? JSONDecoder().decode(Detail.self, from: response.data) else {
            throw failure(JamfPlatformError(.invalidResponse("The mobile device detail could not be read.")))
        }
        return [detail.ios, detail.tvos, detail.watchos, detail.visionos].compactMap { $0?.unlockToken }.first { !$0.isEmpty }
    }

    /// One request for every UDID; Jamf Pro answers 200 even when it renewed
    /// nothing, naming the UDIDs it skipped.
    private func renewProfile(_ receiving: [MDMCommand.Target], _ run: inout CommandRun) async throws {
        guard !receiving.isEmpty else { return }
        struct Answer: Decodable {
            let udidsNotProcessed: Wrapper?
            struct Wrapper: Decodable { let udids: [String]? }
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["udids": receiving.compactMap(\.udid)])
            let response = try await sendThrowing(HTTPRequest(method: "POST", path: "pro/v1/mdm/renew-profile", body: body),
                                                  privilege: .sendRenewMDMProfileCommand)
            let skipped = Set(((try? JSONDecoder().decode(Answer.self, from: response.data))?.udidsNotProcessed?.udids ?? [])
                .map { $0.lowercased() })
            for target in receiving {
                run.set(target, skipped.contains((target.udid ?? "").lowercased()) ? .notProcessed : .sent)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            for target in receiving { run.set(target, .failed(error.localizedDescription)) }
        }
    }

    /// As the Jamf Pro web interface does it: a DDM sync per device (the entry
    /// in the management history), a DeviceInformation query for devices that
    /// refuse it, then the blank push itself, which names the devices it
    /// couldn't reach.
    private func blankPush(_ receiving: [MDMCommand.Target], _ run: inout CommandRun) async throws {
        guard !receiving.isEmpty else { return }
        let managementIDs = receiving.compactMap(\.managementID)
        var fallback = [String]()
        var syncErrors = [String]()
        for id in managementIDs {
            do {
                _ = try await sendThrowing(HTTPRequest(method: "POST", path: "pro/v1/ddm/\(JamfPlatform.pathSegment(id))/sync"),
                                           privilege: .sendDeclarativeManagementCommand)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fallback.append(id)
                syncErrors.append(error.localizedDescription)
            }
        }
        var warning: String?
        if !fallback.isEmpty {
            do {
                try await modernCommand(["commandType": "DEVICE_INFORMATION", "queries": ["DeviceName"]],
                                        managementIDs: fallback, privilege: .viewMDMCommandInformation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                warning = "The blank push was sent, but no visible command could be queued with it: \(syncErrors.first ?? ""); fallback DeviceInformation also failed: \(error.localizedDescription)"
            }
        }
        struct Answer: Decodable { let errorUuids: [String]? }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["clientManagementIds": managementIDs])
            let response = try await sendThrowing(HTTPRequest(method: "POST", path: "pro/v2/mdm/blank-push", body: body),
                                                  privilege: .viewMDMCommandInformation)
            let failed = Set(((try? JSONDecoder().decode(Answer.self, from: response.data))?.errorUuids ?? []).map { $0.lowercased() })
            for target in receiving {
                run.set(target, failed.contains((target.managementID ?? "").lowercased()) ? .notProcessed : .sent)
            }
            run.warning = warning
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            for target in receiving { run.set(target, .failed(error.localizedDescription)) }
        }
    }
}

/// The outcomes of one command being sent, in the order the targets came.
nonisolated struct CommandRun {
    private var targets: [MDMCommand.Target]
    private var outcomes: [MDMCommand.Outcome?]
    private let command: String
    var warning: String?

    init(targets: [MDMCommand.Target], command: String) {
        self.targets = targets
        outcomes = Array(repeating: nil, count: targets.count)
        self.command = command
    }

    mutating func set(_ target: MDMCommand.Target, _ outcome: MDMCommand.Outcome) {
        // the first target still without an outcome, so a device listed twice
        // gets both
        if let index = targets.indices.first(where: { targets[$0] == target && outcomes[$0] == nil }) {
            outcomes[index] = outcome
        }
    }

    /// Runs one device's request; a failure becomes that device's outcome.
    mutating func each(_ target: MDMCommand.Target, _ body: () async throws -> MDMCommand.Outcome) async throws {
        do {
            set(target, try await body())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            set(target, .failed(error.localizedDescription))
        }
    }

    var result: MDMCommand.Result {
        MDMCommand.Result(command: command,
                          outcomes: zip(targets, outcomes).map { MDMCommand.DeviceOutcome(target: $0, outcome: $1 ?? .failed("Not sent.")) },
                          warning: warning)
    }
}
