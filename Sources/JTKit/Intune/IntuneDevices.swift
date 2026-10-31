import Foundation

extension Graph {
    /// A device as Intune reports it, with the fields `Graph.Client.intuneDevices()`
    /// asks for.
    ///
    /// Tolerant: only `id` is required; a missing field, or one of an unexpected
    /// type, is nil. Dates are kept as Graph writes them.
    public nonisolated struct ManagedDevice: Decodable, Sendable, Hashable {
        /// Intune’s managed device ID, which every action is addressed to.
        public var id: String
        /// Empty for some virtual and personally enrolled devices.
        public var serialNumber: String?
        public var deviceName: String?
        /// macOS, iOS, iPadOS, Windows, Android…: Intune keeps one collection
        /// for every platform.
        public var operatingSystem: String?
        public var osVersion: String?
        public var enrolledDateTime: String?
        public var lastSyncDateTime: String?
        public var managementCertificateExpirationDate: String?
        /// FileVault on a Mac, BitLocker on Windows, data protection on an
        /// iPhone or iPad (on exactly when a passcode is set).
        public var isEncrypted: Bool?
        public var isSupervised: Bool?
        /// The management channel, e.g. `mdm`, `easMdm`; empty once retired.
        public var managementAgent: String?
        public var complianceState: String?
        /// How it enrolled, e.g. `appleBulkWithUser` (Automated Device Enrollment).
        public var deviceEnrollmentType: String?

        /// The fields asked for by name: a managed device has over sixty, among
        /// them a large health-attestation object. `enrollmentProfileName` is
        /// left out on purpose: it names the profile the device enrolled with,
        /// not the one the console shows as assigned.
        public static let fields = [
            "id", "serialNumber", "deviceName", "operatingSystem", "osVersion",
            "enrolledDateTime", "lastSyncDateTime", "managementCertificateExpirationDate",
            "isEncrypted", "isSupervised", "managementAgent", "complianceState",
            "deviceEnrollmentType",
        ]

        public init(id: String, serialNumber: String? = nil, deviceName: String? = nil, operatingSystem: String? = nil,
                    osVersion: String? = nil, enrolledDateTime: String? = nil, lastSyncDateTime: String? = nil,
                    managementCertificateExpirationDate: String? = nil, isEncrypted: Bool? = nil, isSupervised: Bool? = nil,
                    managementAgent: String? = nil, complianceState: String? = nil, deviceEnrollmentType: String? = nil) {
            self.id = id
            self.serialNumber = serialNumber
            self.deviceName = deviceName
            self.operatingSystem = operatingSystem
            self.osVersion = osVersion
            self.enrolledDateTime = enrolledDateTime
            self.lastSyncDateTime = lastSyncDateTime
            self.managementCertificateExpirationDate = managementCertificateExpirationDate
            self.isEncrypted = isEncrypted
            self.isSupervised = isSupervised
            self.managementAgent = managementAgent
            self.complianceState = complianceState
            self.deviceEnrollmentType = deviceEnrollmentType
        }

        private enum CodingKeys: String, CodingKey {
            case id, serialNumber, deviceName, operatingSystem, osVersion, enrolledDateTime, lastSyncDateTime,
                 managementCertificateExpirationDate, isEncrypted, isSupervised, managementAgent, complianceState,
                 deviceEnrollmentType
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
            func flag(_ key: CodingKeys) -> Bool? { (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil }
            id = try container.decode(String.self, forKey: .id)
            serialNumber = text(.serialNumber)
            deviceName = text(.deviceName)
            operatingSystem = text(.operatingSystem)
            osVersion = text(.osVersion)
            enrolledDateTime = text(.enrolledDateTime)
            lastSyncDateTime = text(.lastSyncDateTime)
            managementCertificateExpirationDate = text(.managementCertificateExpirationDate)
            isEncrypted = flag(.isEncrypted)
            isSupervised = flag(.isSupervised)
            managementAgent = text(.managementAgent)
            complianceState = text(.complianceState)
            deviceEnrollmentType = text(.deviceEnrollmentType)
        }

        // MARK: - Derived

        /// Enrolled through Automated Device Enrollment (the `appleBulk…` types).
        public var enrolledViaADE: Bool? {
            deviceEnrollmentType.map { $0.hasPrefix("appleBulk") }
        }

        /// iOS or iPadOS, where `isEncrypted` reports data protection, so a
        /// passcode, rather than storage encryption.
        public var isApplePlatform: Bool {
            switch operatingSystem?.lowercased() {
            case "ios", "ipados": true
            default: false
            }
        }

        /// Computer or mobile device, from the platform: Intune draws no such
        /// line. Windows counts as a computer: the commands that reach it are
        /// the computer ones.
        public var kind: MDMCommand.DeviceKind {
            switch operatingSystem?.lowercased() {
            case "macos", "windows": .computer
            default: .mobileDevice
            }
        }

        /// Whether Intune still manages it; nil when the agent is empty (a
        /// retired or wiped device keeps its record for a while).
        public var isManaged: Bool? {
            guard let managementAgent, !managementAgent.isEmpty else { return nil }
            return managementAgent.lowercased().contains("mdm")
        }

        /// Compliance in words rather than Graph’s spelling.
        public var complianceSummary: String? {
            guard let complianceState, !complianceState.isEmpty else { return nil }
            switch complianceState {
            case "compliant": return "Compliant"
            case "noncompliant": return "Not compliant"
            case "inGracePeriod": return "In grace period"
            case "configManager": return "Managed by Configuration Manager"
            case "unknown": return "Unknown"
            default:
                let words = complianceState.replacingOccurrences(of: "_", with: " ").lowercased()
                return words.prefix(1).uppercased() + words.dropFirst()
            }
        }

        /// The device in the Intune admin center.
        public var consoleURL: URL? {
            URL(string: "https://intune.microsoft.com/#view/Microsoft_Intune_ManagedDevices/ManagedDeviceMenu.MenuView/~/overview/managedDeviceId/\(id)")
        }
    }
}

@available(*, deprecated, renamed: "Graph.ManagedDevice")
public typealias IntuneManagedDevice = Graph.ManagedDevice

// MARK: - Calls

extension Graph.Client {
    /// Every managed device in the tenant, with `Graph.ManagedDevice.fields`,
    /// 1,000 per page (Graph’s most). The answers are recorded in the
    /// activity log, as a device lookup’s are.
    ///
    /// The whole tenant, because Graph documents no `$filter` on
    /// `serialNumber`.
    public func intuneDevices() async throws -> [Graph.ManagedDevice] {
        try await list(Graph.ManagedDevice.self,
                       "deviceManagement/managedDevices?$select=\(Graph.ManagedDevice.fields.joined(separator: ","))&$top=1000",
                       version: .v1, recordsBodies: true)
    }

    /// `intuneDevices()` keyed by upper-cased serial number. The first
    /// record wins (the same hardware enrolled twice); devices without a
    /// serial are left out.
    public func intuneDevicesBySerial() async throws -> [String: Graph.ManagedDevice] {
        var bySerial = [String: Graph.ManagedDevice]()
        for device in try await intuneDevices() {
            guard let serial = device.serialNumber, !serial.isEmpty else { continue }
            let key = serial.uppercased()
            if bySerial[key] == nil { bySerial[key] = device }
        }
        return bySerial
    }

    /// Test Connection of an Intune connection: reads one managed device,
    /// the cheapest read that still needs the read permission. No `$count`,
    /// which Graph refuses here.
    public func testConnection() async throws {
        _ = try await getRaw("deviceManagement/managedDevices?$select=id&$top=1", version: .v1)
    }

    @available(*, deprecated, renamed: "testConnection()")
    public func intuneTestConnection() async throws {
        try await testConnection()
    }

    /// Sends a command to one Intune device. Not repeated after a server
    /// error or a dropped connection, only after a 429; Delete Record is
    /// repeated (deleting twice does no harm).
    ///
    /// - Throws: `MDMCommand.Refusal` for a command Intune doesn’t have, and
    ///   before anything is sent for an empty ID or one with `?`, `#` or `/`
    ///   (other characters are percent-encoded);
    ///   `Graph.APIError` when refused, naming the permission the request
    ///   needs (`Graph.Permission.required(method:path:)`).
    /// - Parameter approval: the answered confirmation, from
    ///   `MDMCommand.Confirmation.approve(...)`. Required for a command that
    ///   can’t be undone (`needsApproval(on:)`), and then for exactly this
    ///   command on Intune.
    public func perform(_ command: MDMCommand, intuneDeviceID id: String,
                        approval: MDMCommand.Confirmation.Approval?) async throws {
        try command.check(approval, on: .intune, receiving: nil)
        try await performCommand(command, intuneDeviceID: id)
    }

    @available(*, deprecated, message: "Confirm with MDMCommand.Confirmation and pass its approve(...) to perform(_:intuneDeviceID:approval:).")
    public func perform(_ command: MDMCommand, intuneDeviceID id: String) async throws {
        try await performCommand(command, intuneDeviceID: id)
    }

    private func performCommand(_ command: MDMCommand, intuneDeviceID id: String) async throws {
        guard let request = command.intuneRequest(deviceID: id) else {
            throw MDMCommand.Refusal("\(command.title) isn’t available in Intune.")
        }
        guard !id.isEmpty, !id.contains(where: { "?#/".contains($0) }) else {
            throw MDMCommand.Refusal(id.isEmpty ? "The device has no Intune device ID." : "“\(id)” isn’t an Intune device ID.")
        }
        if request.method == "DELETE" {
            try await delete(request.path, version: .v1)
        } else {
            _ = try await send(request.method, request.path, version: .v1, body: request.body)
        }
    }

    /// Sends a command to every device it applies to, one request per device
    /// (Graph’s actions take one device). Devices of the wrong kind are
    /// skipped; a refused device doesn’t stop the others.
    ///
    /// - Parameters:
    ///   - targets: `recordID` is the managed device ID.
    ///   - approval: the answered confirmation, from
    ///     `MDMCommand.Confirmation.approve(...)`. Required for a command that
    ///     can’t be undone (`needsApproval(on:)`), and then for exactly this
    ///     command on Intune and the devices that receive it.
    public func send(_ command: MDMCommand, to targets: [MDMCommand.Target],
                     approval: MDMCommand.Confirmation.Approval?) async throws -> MDMCommand.Result {
        if command.intuneRequest(deviceID: "") != nil {
            try command.check(approval, on: .intune, receiving: command.plan(for: targets, on: .intune).receiving.count)
        }
        return try await sendCommand(command, to: targets)
    }

    @available(*, deprecated, message: "Confirm with MDMCommand.Confirmation and pass its approve(...) to send(_:to:approval:).")
    public func send(_ command: MDMCommand, to targets: [MDMCommand.Target]) async throws -> MDMCommand.Result {
        try await sendCommand(command, to: targets)
    }

    private func sendCommand(_ command: MDMCommand, to targets: [MDMCommand.Target]) async throws -> MDMCommand.Result {
        guard command.intuneRequest(deviceID: "") != nil else {
            throw MDMCommand.Refusal("\(command.title) isn’t available in Intune.")
        }
        let title = command.title(on: .intune)
        var outcomes = [MDMCommand.DeviceOutcome]()
        for target in targets {
            guard command.applies(to: target.kind, on: .intune) else {
                outcomes.append(.init(target: target, outcome: .skipped(.notApplicable(target.kind))))
                continue
            }
            do {
                try await performCommand(command, intuneDeviceID: target.recordID)
                outcomes.append(.init(target: target, outcome: .sent))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcomes.append(.init(target: target, outcome: .failed(error.localizedDescription)))
            }
        }
        return MDMCommand.Result(command: title, outcomes: outcomes)
    }
}
