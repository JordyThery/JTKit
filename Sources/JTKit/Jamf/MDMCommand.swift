import Foundation

/// The MDM commands the apps send to Jamf Pro and Jamf School devices, with
/// the rules every app follows: what each one is called and does, whether it
/// can be undone, how it is confirmed, whether it needs a PIN, whether it
/// works over the Platform API, and its Jamf Pro privilege.
///
/// Which commands an app offers, and the confirmation screens, stay in the
/// app; the texts and rules are here, so every app that sends commands asks
/// the same way (ROADMAP step 7).
public nonisolated enum MDMCommand: String, CaseIterable, Sendable, Hashable {
    case lockComputer
    case wipeComputer
    case blankPush
    case renewProfile
    case redeployFramework
    case updateInventory
    case lockMobile
    case clearPasscode
    case restartMobile
    case shutDownMobile
    case wipeMobile
    case unmanage

    public enum Product: Sendable, Hashable {
        case jamfPro
        case jamfSchool
    }

    public enum DeviceKind: String, Sendable, Hashable {
        case computer
        case mobileDevice
    }

    public var title: String {
        switch self {
        case .lockComputer: "Lock Computer"
        case .wipeComputer: "Wipe Computer"
        case .blankPush: "Send Blank Push"
        case .renewProfile: "Renew MDM Profile"
        case .redeployFramework: "Redeploy Jamf Framework"
        case .updateInventory: "Update Inventory"
        case .lockMobile: "Lock Device"
        case .unmanage: "Remove MDM Profile"
        case .clearPasscode: "Clear Passcode"
        case .restartMobile: "Restart Device"
        case .shutDownMobile: "Shut Down Device"
        case .wipeMobile: "Wipe Device"
        }
    }

    /// What the command does to the device, as the confirmation says it.
    public func consequence(on product: Product) -> String {
        switch self {
        case .lockComputer: "The Mac will lock immediately and require the PIN to be used again."
        case .wipeComputer: "All data on the Mac will be erased. This cannot be undone."
        case .blankPush: "The device will be asked to check in with MDM and process any pending commands."
        case .renewProfile: "The MDM enrollment profile will be renewed on the device."
        case .redeployFramework: "Reinstalls the Jamf management framework (jamf binary) on the Mac through MDM. Use when a Mac has stopped checking in but still responds to MDM."
        case .updateInventory: "The device will be asked to submit a fresh inventory report."
        case .lockMobile: "The device will lock immediately; the owner's passcode unlocks it."
        case .unmanage:
            switch product {
            case .jamfPro: "The MDM profile is removed, so Jamf Pro can no longer manage the device. Its inventory record stays until you delete it."
            case .jamfSchool: "The MDM profile is removed, so Jamf School can no longer manage the device. Its record stays until you move it to the trash."
            }
        case .clearPasscode: "The device passcode will be removed."
        case .restartMobile: "The device will restart immediately."
        case .shutDownMobile: "The device will shut down immediately and stay off until someone powers it back on."
        case .wipeMobile: "All data on the device will be erased. This cannot be undone."
        }
    }

    /// Shown with a destructive (red) button.
    public var isDestructive: Bool {
        switch self {
        case .wipeComputer, .wipeMobile, .lockComputer, .lockMobile, .unmanage: true
        default: false
        }
    }

    /// False for the commands nothing can undo: a wipe, and removing the MDM
    /// profile (the device has to be enrolled again). Their confirmation
    /// always names the connection, and asks for the number of devices when
    /// there are two or more (`Confirmation`).
    public var canBeUndone: Bool {
        switch self {
        case .wipeComputer, .wipeMobile, .unmanage: false
        default: true
        }
    }

    /// Lock and Wipe Computer on Jamf Pro ask for a 6-digit PIN, typed twice.
    /// Jamf School's wipe takes no PIN.
    public func needsPIN(on product: Product) -> Bool {
        product == .jamfPro && (self == .lockComputer || self == .wipeComputer)
    }

    /// Whether the Platform API gateway carries the command. Renew MDM Profile
    /// is accepted there but renews nothing (every UDID comes back as not
    /// processed), so it needs a direct connection.
    public var worksOverPlatformAPI: Bool {
        self != .renewProfile
    }

    public static let unavailableOverPlatformAPI = "This command is currently unavailable over the Platform API and requires an API client connection."

    /// Whether the command reaches this kind of device on the product. Jamf
    /// School has one device resource for Macs and mobile devices, so restart,
    /// inventory and unenroll reach both.
    public func applies(to kind: DeviceKind, on product: Product) -> Bool {
        switch (product, self) {
        case (_, .lockComputer), (_, .wipeComputer), (_, .redeployFramework):
            kind == .computer
        case (.jamfPro, .updateInventory), (.jamfPro, .restartMobile),
             (_, .lockMobile), (_, .clearPasscode), (_, .shutDownMobile), (_, .wipeMobile):
            kind == .mobileDevice
        case (.jamfSchool, .updateInventory), (.jamfSchool, .restartMobile),
             (_, .blankPush), (_, .renewProfile), (_, .unmanage):
            true
        }
    }

    /// The Jamf Pro privilege the command needs, named when Jamf Pro refuses
    /// it. Every command also needs “View MDM command information in Jamf Pro
    /// API” (`JamfPro.Privilege.viewMDMCommandInformation`).
    public func privilege(for kind: DeviceKind) -> JamfPro.Privilege {
        switch self {
        case .lockComputer: .sendComputerRemoteLockCommand
        case .wipeComputer: .sendComputerRemoteWipeCommand
        case .blankPush: .sendBlankPush
        case .renewProfile: .sendRenewMDMProfileCommand
        case .redeployFramework: .sendComputerInstallPackageCommand
        case .updateInventory: .updateInventoryForMobileDevices
        case .lockMobile: .sendMobileDeviceRemoteLockCommand
        case .clearPasscode: .sendMobileDeviceRemovePasscodeCommand
        case .restartMobile: .sendMobileDeviceRestartDeviceCommand
        case .shutDownMobile: .sendMobileDeviceShutDownCommand
        case .wipeMobile: .sendMobileDeviceRemoteWipeCommand
        case .unmanage: kind == .computer ? .sendComputerUnmanageCommand : .unmanageMobileDevices
        }
    }
}

// MARK: - Targets and plans

extension MDMCommand {
    /// One device a command is meant for.
    public struct Target: Sendable, Hashable {
        /// Shown in results and the activity log (masked in the bug report).
        public var serial: String
        /// The Jamf Pro computer or mobile device ID, or the Jamf School UDID.
        public var recordID: String
        public var kind: DeviceKind
        public var udid: String?
        /// The UUID `v2/mdm/commands` and the DDM sync address devices by.
        public var managementID: String?

        public init(serial: String, recordID: String, kind: DeviceKind, udid: String? = nil, managementID: String? = nil) {
            self.serial = serial
            self.recordID = recordID
            self.kind = kind
            self.udid = udid
            self.managementID = managementID
        }
    }

    /// Why a device doesn't get the command.
    public enum SkipReason: Sendable, Hashable {
        /// The command isn't for this kind of device.
        case notApplicable(DeviceKind)
        /// The address needs the record's management ID, which the lookup didn't return.
        case noManagementID
        /// Renew MDM Profile addresses devices by UDID.
        case noUDID
        /// The app found no record for it on the connection.
        case noRecord

        /// After "SERIAL: ", in results.
        public var line: String {
            switch self {
            case .notApplicable(.computer): "the command doesn’t apply to Macs."
            case .notApplicable(.mobileDevice): "the command doesn’t apply to mobile devices."
            case .noManagementID: "the record has no management ID. Run a fresh lookup first."
            case .noUDID: "the record has no UDID, so the MDM profile can’t be renewed. Run a fresh lookup first."
            case .noRecord: "no record on this connection."
            }
        }

        /// "2 have no management ID", for the confirmation.
        public func phrase(count: Int) -> String {
            let one = count == 1
            return switch self {
            case .notApplicable(.computer): one ? "1 is a Mac" : "\(count) are Macs"
            case .notApplicable(.mobileDevice): one ? "1 is a mobile device" : "\(count) are mobile devices"
            case .noManagementID: one ? "1 has no management ID" : "\(count) have no management ID"
            case .noUDID: one ? "1 has no UDID" : "\(count) have no UDID"
            case .noRecord: one ? "1 has no record on this connection" : "\(count) have no record on this connection"
            }
        }
    }

    public struct Skipped: Sendable, Hashable {
        public var target: Target
        public var reason: SkipReason

        public init(target: Target, reason: SkipReason) {
            self.target = target
            self.reason = reason
        }
    }

    /// Which devices will receive the command, known before it is sent.
    public struct Plan: Sendable, Hashable {
        public var receiving: [Target]
        public var skipped: [Skipped]

        public init(receiving: [Target], skipped: [Skipped]) {
            self.receiving = receiving
            self.skipped = skipped
        }

        /// Devices the command could be meant for: every one but those of
        /// the wrong kind.
        public var applicable: [Target] {
            receiving + skipped.filter { if case .notApplicable = $0.reason { false } else { true } }.map(\.target)
        }

        /// "5 selected, 3 will receive the command; 2 have no management ID.",
        /// nil when every selected device receives it.
        ///
        /// - Parameter extra: devices the app left out before planning (e.g.
        ///   no record on this connection), counted as selected.
        public func explanation(extra: [SkipReason: Int] = [:]) -> String? {
            var counts = extra
            for skip in skipped { counts[skip.reason, default: 0] += 1 }
            counts = counts.filter { $0.value > 0 }
            guard !counts.isEmpty else { return nil }
            let selected = receiving.count + counts.values.reduce(0, +)
            let order: [SkipReason] = [.noRecord, .noManagementID, .noUDID, .notApplicable(.computer), .notApplicable(.mobileDevice)]
            let reasons = order.compactMap { reason in counts[reason].map { reason.phrase(count: $0) } }
                .formatted(.list(type: .and))
            let receivingText = receiving.count == 1 ? "1 will receive the command" : "\(receiving.count) will receive the command"
            return "\(selected) selected, \(receivingText); \(reasons)."
        }
    }

    /// Which devices can get the command before anything is sent: the right
    /// kind of device, with the identifiers its address needs.
    ///
    /// - Parameter overPlatformAPI: Restart and Shut Down then go through the
    ///   Platform API's device actions, by serial number, so they need no
    ///   management ID.
    public func plan(for targets: [Target], on product: Product, overPlatformAPI: Bool = false) -> Plan {
        var plan = Plan(receiving: [], skipped: [])
        for target in targets {
            if !applies(to: target.kind, on: product) {
                plan.skipped.append(Skipped(target: target, reason: .notApplicable(target.kind)))
            } else if let missing = missingIdentifier(target, on: product, overPlatformAPI: overPlatformAPI) {
                plan.skipped.append(Skipped(target: target, reason: missing))
            } else {
                plan.receiving.append(target)
            }
        }
        return plan
    }

    private func missingIdentifier(_ target: Target, on product: Product, overPlatformAPI: Bool) -> SkipReason? {
        guard product == .jamfPro else { return nil }
        switch self {
        case .renewProfile:
            return (target.udid ?? "").isEmpty ? .noUDID : nil
        case .lockComputer, .lockMobile, .clearPasscode, .blankPush:
            return (target.managementID ?? "").isEmpty ? .noManagementID : nil
        case .restartMobile, .shutDownMobile:
            return !overPlatformAPI && (target.managementID ?? "").isEmpty ? .noManagementID : nil
        case .wipeComputer, .wipeMobile, .unmanage, .redeployFramework, .updateInventory:
            return nil
        }
    }
}

// MARK: - Confirming

extension MDMCommand {
    /// How a command, or any other device action, is confirmed. The rules,
    /// the same in every app (decided by Jordy, ROADMAP step 7):
    /// - something that can't be undone always names the connection, also
    ///   for one device;
    /// - with two or more devices it also asks to type their number;
    /// - a PIN is typed twice.
    ///
    /// The app shows it: a dialog when nothing has to be typed, otherwise a
    /// sheet (`needsTyping`).
    public struct Confirmation: Sendable, Hashable {
        /// "Wipe Computer — C02XK1JHJG5H", "Wipe Computer — 3 Devices".
        public var title: String
        /// What it does, e.g. the command's consequence.
        public var message: String
        /// “On “Lab Jamf”.”, nil when the connection isn't named.
        public var connectionLine: String?
        /// Why fewer devices than selected receive it, shown before typing.
        public var explanation: String?
        /// The number to type, nil when none is asked.
        public var typedCount: Int?
        public var asksPINTwice: Bool
        /// The button that sends.
        public var actionTitle: String
        public var isDestructive: Bool

        public static let pinLength = 6

        /// - Parameters:
        ///   - subject: the one device's serial, or nil for "N Devices".
        ///   - count: how many devices it goes to.
        ///   - irreversible: names the connection, and asks for the number
        ///     from two devices.
        ///   - namesConnection: names the connection anyway (Jamf School's
        ///     Move to Trash, decided by Jordy).
        public init(action actionTitle: String, subject: String?, count: Int, message: String,
                    irreversible: Bool, namesConnection: Bool = false, connectionName: String?,
                    needsPIN: Bool = false, explanation: String? = nil, isDestructive: Bool) {
            let devices = count == 1 ? subject ?? "1 Device" : "\(count) Devices"
            title = "\(actionTitle) — \(devices)"
            self.message = message
            self.actionTitle = actionTitle
            if (irreversible || namesConnection), let connectionName, !connectionName.isEmpty {
                connectionLine = "On “\(connectionName)”."
            }
            self.explanation = explanation
            typedCount = irreversible && count >= 2 ? count : nil
            asksPINTwice = needsPIN
            self.isDestructive = isDestructive
        }

        /// A command's confirmation, from its plan.
        public init(_ command: MDMCommand, plan: Plan, on product: Product, connectionName: String?,
                    extra: [SkipReason: Int] = [:]) {
            let receiving = plan.receiving
            self.init(action: command.title, subject: receiving.count == 1 ? receiving[0].serial : nil,
                      count: receiving.count, message: command.consequence(on: product),
                      irreversible: !command.canBeUndone, connectionName: connectionName,
                      needsPIN: command.needsPIN(on: product), explanation: plan.explanation(extra: extra),
                      isDestructive: command.isDestructive)
        }

        /// Something has to be typed, so a dialog can't hold it.
        public var needsTyping: Bool { typedCount != nil || asksPINTwice }

        /// What is still missing before it can be sent, nil when it can be.
        public func problem(typedCount typed: String = "", pin: String = "", pinAgain: String = "") -> String? {
            if asksPINTwice {
                guard Self.isValidPIN(pin) else { return "Enter a \(Self.pinLength)-digit PIN." }
                guard pin == pinAgain else { return "The two PINs don’t match." }
            }
            if let typedCount, Int(typed.trimmingCharacters(in: .whitespaces)) != typedCount {
                return "Type \(typedCount) to confirm."
            }
            return nil
        }

        public static func isValidPIN(_ pin: String) -> Bool {
            pin.count == pinLength && pin.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}

// MARK: - Results

extension MDMCommand {
    /// What became of the command on one device.
    public enum Outcome: Sendable, Hashable {
        case sent
        /// Refused, with the message to show after the serial.
        case failed(String)
        /// Accepted, but the server says it did nothing for this device
        /// (Renew MDM Profile's `udidsNotProcessed`, Blank Push's `errorUuids`).
        case notProcessed
        case skipped(SkipReason)
    }

    public struct DeviceOutcome: Sendable, Hashable {
        public var target: Target
        public var outcome: Outcome

        public init(target: Target, outcome: Outcome) {
            self.target = target
            self.outcome = outcome
        }
    }

    /// The command's result, device by device. A command is never repeated
    /// after a server error, only after a 429, when nothing was done.
    public struct Result: Sendable, Hashable {
        public var command: String
        public var outcomes: [DeviceOutcome]
        /// Something about the whole command, e.g. Blank Push sent without
        /// its visible DDM sync.
        public var warning: String?

        public init(command: String, outcomes: [DeviceOutcome], warning: String? = nil) {
            self.command = command
            self.outcomes = outcomes
            self.warning = warning
        }

        public var sent: [Target] { outcomes.filter { $0.outcome == .sent }.map(\.target) }

        /// Every applicable device received it, and nothing needs saying.
        public var isComplete: Bool { problems == nil }

        /// What to show when not every applicable device received it: one
        /// line per device ("SERIAL: message"), devices the server didn't
        /// process together, then the warning. Devices of the wrong kind
        /// aren't listed: the command was never meant for them.
        public var problems: String? {
            var lines = [String]()
            var notProcessed = [String]()
            for item in outcomes {
                switch item.outcome {
                case .sent, .skipped(.notApplicable): break
                case .failed(let message): lines.append("\(item.target.serial): \(message)")
                case .skipped(let reason): lines.append("\(item.target.serial): \(reason.line)")
                case .notProcessed: notProcessed.append(item.target.serial)
                }
            }
            if !notProcessed.isEmpty {
                let names = notProcessed.joined(separator: ", ")
                lines.append(command == MDMCommand.renewProfile.title
                             ? "Jamf Pro accepted the request but renewed no profile for: \(names)"
                             : command == MDMCommand.blankPush.title
                             ? "Jamf Pro could not deliver the blank push to: \(names)"
                             : "The server accepted \(command) but didn’t process it for: \(names)")
            }
            if let warning { lines.append(warning) }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    /// Thrown when nothing is sent at all: the connection can't carry the
    /// command, no device has what its address needs, or the PIN is missing.
    public struct Refusal: Error, LocalizedError, Sendable, Hashable {
        public var message: String

        public init(_ message: String) {
            self.message = message
        }

        public var errorDescription: String? { message }
    }
}

// MARK: - Action entries

extension ActivityLog {
    /// One "Action" entry for a command: how many devices it went to, and
    /// every one it didn't reach with the reason, in the note. Failed when a
    /// device failed or wasn't processed (or `failure` says the whole command
    /// failed); a warning when devices were only skipped. Every device is
    /// masked in the bug-report export.
    public func recordCommand(
        _ title: String,
        outcomes: [MDMCommand.DeviceOutcome],
        warning: String? = nil,
        failure: String? = nil,
        service: String?,
        connection: String?
    ) {
        let serials = outcomes.map(\.target.serial)
        if let failure {
            append(.action("\(title) failed — \(failure)", failed: true, service: service,
                           connection: connection, devices: serials))
            return
        }
        let sent = outcomes.filter { $0.outcome == .sent }.count
        let summary = sent == outcomes.count
            ? "Sent \(title) to \(Self.devices(sent))"
            : sent == 0 ? "\(title) reached none of the \(Self.devices(outcomes.count))"
            : "Sent \(title) to \(sent) of \(Self.devices(outcomes.count))"
        var lines = [String]()
        var failed = false
        for item in outcomes {
            switch item.outcome {
            case .sent: continue
            case .failed(let message):
                failed = true
                lines.append("\(item.target.serial): failed — \(message)")
            case .notProcessed:
                failed = true
                lines.append("\(item.target.serial): accepted, but not processed")
            case .skipped(let reason):
                lines.append("\(item.target.serial): skipped — \(reason.line)")
            }
        }
        if let warning { lines.append(warning) }
        var entry = ActivityLogEntry.action(summary, note: lines.isEmpty ? nil : lines.joined(separator: "\n"),
                                            failed: failed, service: service, connection: connection, devices: serials)
        entry.isWarning = !failed && !lines.isEmpty
        append(entry)
    }

    static func devices(_ count: Int) -> String {
        count == 1 ? "1 device" : "\(count) devices"
    }
}
