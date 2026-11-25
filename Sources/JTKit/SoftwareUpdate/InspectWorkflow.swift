import Foundation

extension SoftwareUpdateRules {
    /// Inspect: for the devices chosen, reads each one’s status report, its
    /// Platform API device and its declaration reports (all GETs, through
    /// JTKit), and lists every reason it may not update.
    public nonisolated struct InspectWorkflow: Sendable {
        public let client: JamfPlatform.Client
        /// Devices read at the same time.
        public var parallel = 4

        /// The devices Inspect looks at by default: by serial when given, else
        /// those whose diagnosis contains the text, else every device not on
        /// target whose diagnosis needs attention.
        public static func select(_ devices: [DeviceStatus], diagnosis: String = "", serials: [String] = []) -> [DeviceStatus] {
            let wanted = Set(serials.map { $0.uppercased() }.filter { !$0.isEmpty })
            if !wanted.isEmpty { return devices.filter { wanted.contains($0.serial.uppercased()) } }
            if !diagnosis.isEmpty { return devices.filter { $0.diagnosis.localizedCaseInsensitiveContains(diagnosis) } }
            return devices.filter { $0.category != .onTarget && $0.needsAttention }
        }

        public func run(_ members: [JamfPro.GroupMember], rows: [DeviceStatus], context: InspectContext) async throws -> [InspectResult] {
            let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var results: [Int: InspectResult] = [:]
            try await withThrowingTaskGroup(of: (Int, InspectResult).self) { group in
                var next = 0
                func start() {
                    guard next < members.count else { return }
                    let index = next
                    let member = members[index]
                    next += 1
                    group.addTask {
                        let input = await inspectInput(member, row: rowsByID[Reader.key(member)], serverTimeZone: context.serverTimeZone)
                        return (index, InspectFindings.evaluate(input, context: context))
                    }
                }
                for _ in 0..<max(1, parallel) { start() }
                while let (index, result) = try await group.next() {
                    results[index] = result
                    start()
                }
            }
            return members.indices.compactMap { results[$0] }
        }

        /// One device’s reads; what can’t be read is written into the input.
        func inspectInput(_ member: JamfPro.GroupMember, row: DeviceStatus?, serverTimeZone: TimeZone = .gmt) async -> InspectInput {
            var input = InspectInput(member: member, device: row)
            do {
                if let managementID = member.managementID,
                   let items = try await client.statusItems(managementID: managementID, kind: member.kind) {
                    // the raw items, for when the install state last changed; one request, as before
                    input.status = JamfPro.SoftwareUpdateStatus(items: items)
                    input.installStateChanged = items.last { $0.key == "softwareupdate.install-state" }?.lastUpdateTime
                        .flatMap { JamfPro.serverDate($0, timeZone: serverTimeZone) }
                    input.osVersionChanged = items.last { $0.key == "device.operating-system.version" }?.lastUpdateTime
                        .flatMap { JamfPro.serverDate($0, timeZone: serverTimeZone) }
                }
                guard let serial = member.serialNumber, let device = try await client.device(serial: serial) else { return input }
                input.platformDeviceID = device.id
                do {
                    input.reports = try await client.declarationReports(deviceID: device.id) ?? []
                } catch is CancellationError {
                    input.problem = "Stopped"
                } catch {
                    input.reportsProblem = error.localizedDescription
                }
            } catch is CancellationError {
                input.problem = "Stopped"
            } catch {
                input.problem = error.localizedDescription
            }
            return input
        }

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            client: JamfPlatform.Client,
            parallel: Int = 4
        ) {
            self.client = client
            self.parallel = parallel
        }
    }
}
