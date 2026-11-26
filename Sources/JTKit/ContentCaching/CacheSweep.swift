import Foundation

extension ContentCacheRules {
    /// Progress of a sweep, as the software update reader reports it.
    public typealias Progress = SoftwareUpdateRules.RefreshProgress

    /// How a caching Blueprint’s declaration stands on one Mac.
    public struct DeclarationState: Hashable, Sendable, Codable {
        public enum State: String, Hashable, Sendable, Codable, CaseIterable {
            case applied, pending, awaitingSync, failed, invalid
            /// Its activation’s predicate is false for this Mac (`Info.Predicate`):
            /// the configuration’s `Error.ActivationFailed` isn’t a failure.
            case notForThisDevice
            /// The Mac hasn’t reported it.
            case notReceived

            public var title: String {
                switch self {
                case .applied: "Applied"
                case .pending: "Pending"
                case .awaitingSync: "Awaiting sync"
                case .failed: "Failed"
                case .invalid: "Invalid"
                case .notForThisDevice: "Not for this device"
                case .notReceived: "Not received"
                }
            }
        }

        public var blueprintID: String
        public var blueprintName: String
        public var state: State
        /// The report’s reason codes, e.g. `Error.ConfigurationFailed`.
        public var reasons: [String]

        public init(blueprintID: String, blueprintName: String, state: State, reasons: [String] = []) {
            self.blueprintID = blueprintID
            self.blueprintName = blueprintName
            self.state = state
            self.reasons = reasons
        }

        /// The state of a configuration on one device from its reports: the
        /// configuration’s own, and its activation’s. An activation that
        /// reports `Info.Predicate` makes the pair not for this device, as
        /// `SoftwareUpdateRules.BlueprintHealth` counts it.
        public static func state(configuration: JamfPlatform.DeclarationReport?,
                                 activation: JamfPlatform.DeclarationReport?) -> State {
            if let activation, activation.reasons.contains(where: { $0.code == "Info.Predicate" }) { return .notForThisDevice }
            guard let configuration else { return .notReceived }
            if configuration.validity == .invalid { return .invalid }
            switch configuration.status {
            case .successful: return configuration.active == false ? .pending : .applied
            case .pending, .unknown, .other: return .pending
            case .awaitingSync: return .awaitingSync
            case .unsuccessful: return .failed
            }
        }
    }

    /// One Mac whose content cache is activated.
    public struct CacheRecord: Hashable, Sendable, Identifiable {
        /// Jamf Pro’s computer ID: the cache’s identity across sweeps.
        public var id: String
        public var name: String?
        public var serialNumber: String?
        public var managementID: String?
        public var siteName: String?
        public var osVersion: String?
        public var model: String?
        public var lastContact: Date?
        /// The inventory report the `caching` figures are from.
        public var reportDate: Date?
        public var caching: JamfPro.ContentCaching
        /// macOS 27’s status items; nil before macOS 27 or without a report.
        public var status: JamfPro.ContentCacheStatus?
        /// Why the status report couldn’t be read; nil when it was, or when there is none.
        public var statusProblem: String?
        /// The declarations the Mac reports it holds (`management.declarations`).
        public var declarationIdentifiers: [String]
        /// The caching Blueprints’ declarations on this Mac.
        public var declarations: [DeclarationState]
        /// Activated, and no caching Blueprint sends it a content caching declaration.
        public var isUnplanned: Bool
        public var health: CacheHealth
        public var savings: Savings

        public init(id: String, name: String? = nil, serialNumber: String? = nil, managementID: String? = nil,
                    siteName: String? = nil, osVersion: String? = nil, model: String? = nil, lastContact: Date? = nil,
                    reportDate: Date? = nil, caching: JamfPro.ContentCaching, status: JamfPro.ContentCacheStatus? = nil,
                    statusProblem: String? = nil, declarationIdentifiers: [String] = [], declarations: [DeclarationState] = [],
                    isUnplanned: Bool = false, health: CacheHealth = CacheHealth(), savings: Savings? = nil) {
            self.id = id
            self.name = name
            self.serialNumber = serialNumber
            self.managementID = managementID
            self.siteName = siteName
            self.osVersion = osVersion
            self.model = model
            self.lastContact = lastContact
            self.reportDate = reportDate
            self.caching = caching
            self.status = status
            self.statusProblem = statusProblem
            self.declarationIdentifiers = declarationIdentifiers
            self.declarations = declarations
            self.isUnplanned = isUnplanned
            self.health = health
            self.savings = savings ?? Savings.compute(caching)
        }

        /// What to keep of this cache for the trend.
        public func snapshot(at date: Date) -> CacheSnapshot {
            CacheSnapshot(date: date, cacheID: id, countersSince: caching.countersSince,
                          serverGuid: status?.status?.serverGuid ?? caching.serverGuid, served: savings.served,
                          fromOrigin: savings.fromOrigin, used: status?.info?.cacheUsed ?? caching.cacheUsed,
                          pressurePercent: status?.info?.pressurePercent ?? caching.pressurePercent, health: health.level)
        }

        /// Whether a caching Blueprint’s declaration should be on this Mac
        /// and is applied; nil when none should be.
        public var declarationApplied: Bool? {
            let relevant = declarations.filter { $0.state != .notForThisDevice }
            return relevant.isEmpty ? nil : relevant.contains { $0.state == .applied }
        }
    }

    /// A Mac a caching Blueprint configures, a cache or not.
    public struct ConfiguredMac: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String?
        public var serialNumber: String?
        public var siteName: String?
        /// Its content cache is activated (it is among the sweep’s caches).
        public var isActivated: Bool
        public var declaration: DeclarationState.State

        public init(id: String, name: String? = nil, serialNumber: String? = nil, siteName: String? = nil,
                    isActivated: Bool = false, declaration: DeclarationState.State = .notReceived) {
            self.id = id
            self.name = name
            self.serialNumber = serialNumber
            self.siteName = siteName
            self.isActivated = isActivated
            self.declaration = declaration
        }
    }

    /// A Blueprint that sends a content caching declaration: what it sets,
    /// and which Macs it reaches.
    public struct CachingBlueprint: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var updated: String?
        public var settings: [JamfPlatform.ContentCacheSettings]
        /// Its scope’s Jamf Pro computer groups.
        public var scope: [JamfPro.DeviceGroup]
        public var configured: [ConfiguredMac]
        /// The declaration identifiers read for it.
        public var identifiers: [String]

        public init(id: String, name: String, updated: String? = nil, settings: [JamfPlatform.ContentCacheSettings] = [],
                    scope: [JamfPro.DeviceGroup] = [], configured: [ConfiguredMac] = [], identifiers: [String] = []) {
            self.id = id
            self.name = name
            self.updated = updated
            self.settings = settings
            self.scope = scope
            self.configured = configured
            self.identifiers = identifiers
        }

        public var activatedCount: Int { configured.filter(\.isActivated).count }
        public var appliedCount: Int { configured.filter { $0.declaration == .applied }.count }

        /// Whether a Mac’s declaration list holds this Blueprint’s caching configuration.
        public func isHeld(in identifiers: [String]) -> Bool {
            let prefixes = settings.map { $0.identifierPrefix(blueprintID: id).lowercased() }
            return identifiers.contains { identifier in
                !JamfPlatform.ContentCacheSettings.isActivation(identifier)
                    && prefixes.contains { identifier.lowercased().hasPrefix($0) }
            }
        }
    }

    /// Reads every content cache of a tenant: the computer inventory with
    /// its `GENERAL` and `CONTENT_CACHING` sections (every Mac; Jamf’s list
    /// can’t be filtered on the cache), keeping the Macs whose cache is
    /// activated; each cache’s status report; the Blueprints that send a
    /// content caching declaration, their scope and how the declaration
    /// stands. GET only, with the permissions the software update reader
    /// already needs (`devices:read`, `blueprints:read`,
    /// `device-groups:read`, `declarations:read`). Keeps nothing.
    public nonisolated struct Sweep: Sendable {
        public let jamfPro: JamfPlatform.Client
        public let platform: JamfPlatform.Client
        /// Status reports read at a time.
        public var parallel = 4
        /// Inventory pages in flight at a time, after the first.
        public var pageReads = 16
        public var pageSize = 100
        public var thresholds = CacheHealth.Thresholds()
        /// The zone Jamf Pro writes status item times in.
        public var serverTimeZone = TimeZone(identifier: "UTC") ?? .gmt

        /// One client for everything: the Platform API, also as the gateway to Jamf Pro.
        public init(client: JamfPlatform.Client) {
            self.init(jamfPro: client, platform: client)
        }

        public init(jamfPro: JamfPlatform.Client, platform: JamfPlatform.Client) {
            self.jamfPro = jamfPro
            self.platform = platform
        }

        public struct Result: Sendable {
            public var date: Date
            /// Every activated cache, by name.
            public var caches: [CacheRecord]
            public var cachingBlueprints: [CachingBlueprint]
            /// The Blueprints without a caching declaration, with their
            /// `updated` time: pass them to the next sweep (`read(skipping:)`).
            public var notCaching: [String: String]
            /// Macs in the inventory, caches or not.
            public var computersRead: Int
            public var inventoryPages: Int
            /// What couldn’t be read; the rest of the sweep stands.
            public var problems: [String]

            public init(date: Date, caches: [CacheRecord] = [], cachingBlueprints: [CachingBlueprint] = [],
                        notCaching: [String: String] = [:], computersRead: Int = 0, inventoryPages: Int = 0,
                        problems: [String] = []) {
                self.date = date
                self.caches = caches
                self.cachingBlueprints = cachingBlueprints
                self.notCaching = notCaching
                self.computersRead = computersRead
                self.inventoryPages = inventoryPages
                self.problems = problems
            }

            public var unplanned: [CacheRecord] { caches.filter(\.isUnplanned) }

            /// What to keep of every cache for the trend.
            public var snapshots: [CacheSnapshot] { caches.map { $0.snapshot(at: date) } }

            /// The worst health of the caches in each site (nil key: no site).
            public var healthBySite: [String?: CacheHealth.Level] {
                Dictionary(grouping: caches, by: \.siteName).compactMapValues { CacheHealth.worst(of: $0.map(\.health)) }
            }
        }

        /// One sweep.
        /// - Parameter skipping: the previous sweep’s `notCaching`, so
        ///   unchanged Blueprints without a caching declaration aren’t read again.
        public func read(skipping: [String: String] = [:], now: Date = Date(),
                         progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Result {
            var result = Result(date: now)

            // 1. every Mac, with the two sections; a failure here stops the sweep
            let inventory = try await computers { done, total in
                progress(Progress(step: "Reading the computer inventory", done: done, total: total, unit: "pages"))
            }
            result.computersRead = inventory.records.count
            result.inventoryPages = inventory.pages
            result.problems += inventory.problems
            let activated = inventory.records.filter { $0.contentCaching?.isActivated == true }

            // 2. each cache’s status report
            progress(Progress(step: "Reading caches", done: 0, total: activated.count, unit: "caches"))
            let statuses = try await statusItems(activated) { done in
                progress(Progress(step: "Reading caches", done: done, total: activated.count, unit: "caches"))
            }

            // 3. the caching Blueprints and their scope
            progress(Progress(step: "Reading Blueprints"))
            var blueprints: [CachingBlueprint] = []
            var members: [String: [JamfPro.GroupMember]] = [:]
            do {
                let found = try await JamfPlatform.Blueprints(client: platform).cachingBlueprints(skipping: skipping)
                result.notCaching = found.notCaching
                let platformGroups = found.blueprints.isEmpty ? [] : try await platform.platformGroups()
                let scopeReader = ScopeReader(jamfPro: jamfPro)
                for (number, (detail, settings)) in found.blueprints.enumerated() {
                    progress(Progress(step: "Reading caching Blueprints", done: number, total: found.blueprints.count, unit: "Blueprints"))
                    var blueprint = CachingBlueprint(id: detail.id.lowercased(), name: detail.overview.name,
                                                     updated: detail.overview.updated, settings: settings)
                    let groups = try await scopeReader.groups(platformGroupIDs: detail.scopeDeviceGroups, platformGroups: platformGroups,
                                                              kinds: [.computer])
                    blueprint.scope = groups.groups
                    members[blueprint.id] = try await scopeReader.members(of: groups).members
                    blueprints.append(blueprint)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.problems.append("The caching Blueprints couldn’t be read: \(error.localizedDescription)")
            }

            // 4. how each Blueprint’s declaration stands
            let held = statuses.values.compactMap(\.items).map { JamfPro.SoftwareUpdateStatus.declarationIdentifiers(in: $0) }
            var reportsByBlueprint: [String: [String: (configuration: JamfPlatform.DeclarationReport?, activation: JamfPlatform.DeclarationReport?)]] = [:]
            if !blueprints.isEmpty {
                do {
                    let bySerial = try await reports(for: &blueprints, held: held.flatMap { $0 }) { done, total in
                        progress(Progress(step: "Checking declarations", done: done, total: total, unit: "declarations"))
                    }
                    reportsByBlueprint = bySerial
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    result.problems.append("The caching declarations’ reports couldn’t be read: \(error.localizedDescription)")
                }
            }

            // 5. put it together
            let activatedIDs = Set(activated.compactMap(\.id))
            for index in blueprints.indices {
                let blueprint = blueprints[index]
                let reports = reportsByBlueprint[blueprint.id] ?? [:]
                blueprints[index].configured = (members[blueprint.id] ?? []).map { member in
                    let pair = member.serialNumber.flatMap { reports[$0.uppercased()] }
                    return ConfiguredMac(id: member.id, name: member.name, serialNumber: member.serialNumber,
                                         siteName: member.siteName, isActivated: activatedIDs.contains(member.id),
                                         declaration: DeclarationState.state(configuration: pair?.configuration, activation: pair?.activation))
                }
            }
            result.cachingBlueprints = blueprints
            result.caches = activated.compactMap { computer -> CacheRecord? in
                guard let id = computer.id, let caching = computer.contentCaching else { return nil }
                let read = statuses[id]
                let identifiers = read?.items.map { JamfPro.SoftwareUpdateStatus.declarationIdentifiers(in: $0) } ?? []
                let serial = computer.serialNumber?.uppercased()
                var declarations: [DeclarationState] = []
                var planned = false
                for blueprint in blueprints {
                    let inScope = (members[blueprint.id] ?? []).contains { $0.id == id }
                    let holds = blueprint.isHeld(in: identifiers)
                    guard inScope || holds else { continue }
                    planned = true
                    let pair = serial.flatMap { reportsByBlueprint[blueprint.id]?[$0] }
                    let report = pair?.configuration
                    declarations.append(DeclarationState(
                        blueprintID: blueprint.id, blueprintName: blueprint.name,
                        state: DeclarationState.state(configuration: report, activation: pair?.activation),
                        reasons: (report?.reasons ?? []).compactMap(\.code)))
                }
                var record = CacheRecord(
                    id: id, name: computer.general?.name, serialNumber: computer.serialNumber,
                    managementID: computer.general?.managementID, siteName: computer.general?.site?.assignedName,
                    osVersion: computer.operatingSystem?.version, model: computer.hardware?.model,
                    lastContact: computer.general?.lastContact ?? computer.general?.lastCheckIn,
                    reportDate: computer.general?.reportDate, caching: caching,
                    status: read?.items.flatMap(JamfPro.ContentCacheStatus.init(items:)), statusProblem: read?.problem,
                    declarationIdentifiers: identifiers, declarations: declarations, isUnplanned: !planned)
                record.health = CacheHealth.evaluate(caching, status: record.status, reportDate: record.reportDate,
                                                     declarationApplied: record.declarationApplied,
                                                     serverTimeZone: serverTimeZone, thresholds: thresholds, now: now)
                return record
            }.sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
            let unreadable = result.caches.filter { $0.statusProblem != nil }.count
            if unreadable > 0 {
                result.problems.append("\(unreadable) \(unreadable == 1 ? "cache’s status report" : "caches’ status reports") couldn’t be read.")
            }
            return result
        }

        // MARK: Steps

        /// Every computer with `GENERAL` and `CONTENT_CACHING`, by ID: page 0,
        /// then the pages its `totalCount` announces at once within
        /// `pageReads`, then one after another should more have come.
        func computers(progress: @Sendable (_ done: Int, _ total: Int) -> Void) async throws
            -> (records: [JamfPro.Computer], pages: Int, problems: [String]) {
            let budget = ReadBudget(pageReads)
            let size = max(pageSize, 1)
            let maxPages = 1_000
            let first = try await page(0, size: size)
            var records = first.results
            var received = first.results.count + first.unreadableCount
            var unreadable = first.unreadableCount
            var pages = 1
            var last = first
            if JamfPlatform.hasMore(after: first, received: received, pageSize: size), let total = first.totalCount {
                let announced = min((total + size - 1) / size, maxPages)
                progress(1, announced)
                var found = [JamfPlatform.Page<JamfPro.Computer>?](repeating: nil, count: announced)
                try await withThrowingTaskGroup(of: (Int, JamfPlatform.Page<JamfPro.Computer>).self) { group in
                    for number in 1..<max(announced, 1) {
                        group.addTask { (number, try await budget.run { try await self.page(number, size: size) }) }
                    }
                    var done = 1
                    while let (number, page) = try await group.next() {
                        found[number] = page
                        done += 1
                        progress(done, announced)
                    }
                }
                for page in found.dropFirst().compactMap({ $0 }) {
                    records += page.results
                    received += page.results.count + page.unreadableCount
                    unreadable += page.unreadableCount
                    pages += 1
                    last = page
                }
                // devices added meanwhile: on, one page at a time
                while pages < maxPages, JamfPlatform.hasMore(after: last, received: received, pageSize: size),
                      received >= pages * size {
                    let next = try await page(pages, size: size)
                    records += next.results
                    received += next.results.count + next.unreadableCount
                    unreadable += next.unreadableCount
                    pages += 1
                    last = next
                }
            } else {
                while pages < maxPages, JamfPlatform.hasMore(after: last, received: received, pageSize: size) {
                    let next = try await page(pages, size: size)
                    records += next.results
                    received += next.results.count + next.unreadableCount
                    unreadable += next.unreadableCount
                    pages += 1
                    last = next
                }
            }
            // a page read twice (devices added while reading) holds some computers twice
            var seen = Set<String>()
            records = records.filter { $0.id.map { seen.insert($0).inserted } ?? true }
            let problems = unreadable > 0 ? ["\(unreadable) inventory \(unreadable == 1 ? "record" : "records") couldn’t be read."] : []
            return (records, pages, problems)
        }

        /// One page of the computer inventory, sorted by ID so pages don’t
        /// shift. Its answer isn’t recorded (every Mac’s general section);
        /// an error is.
        func page(_ number: Int, size: Int) async throws -> JamfPlatform.Page<JamfPro.Computer> {
            struct Body: Decodable {
                let totalCount: Int?
                let results: [Tolerant<JamfPro.Computer>]
            }
            let query = [URLQueryItem(name: "page", value: String(number)), URLQueryItem(name: "page-size", value: String(size)),
                         URLQueryItem(name: "section", value: JamfPro.InventorySection.general.rawValue),
                         URLQueryItem(name: "section", value: JamfPro.InventorySection.contentCaching.rawValue),
                         URLQueryItem(name: "sort", value: "id:asc")]
            let response = try await jamfPro.send(HTTPRequest(path: "pro/v4/computers-inventory", query: query),
                                                  privileges: [.readComputers], permissions: [JamfPlatform.Permission.devicesRead])
            // task-group children call this: one return (swiftlang/swift#93208)
            let page: JamfPlatform.Page<JamfPro.Computer>
            do {
                let body = try JSONDecoder().decode(Body.self, from: response.data)
                let records = body.results.compactMap(\.value)
                page = JamfPlatform.Page(results: records, totalCount: body.totalCount,
                                         unreadableCount: body.results.count - records.count)
            } catch {
                throw jamfPro.failure(JamfPlatform.APIError(.invalidResponse("pro/v4/computers-inventory couldn’t be read: \(error.localizedDescription)")))
            }
            return page
        }

        struct StatusRead: Sendable {
            var items: [JamfPro.StatusItem]?
            var problem: String?
        }

        /// The status items of each cache, `parallel` at a time, by computer
        /// ID. A cache without a report (404) has none; one that couldn’t be
        /// read has a problem; a refusal (403) stops the sweep.
        func statusItems(_ computers: [JamfPro.Computer], progress: @Sendable (Int) -> Void) async throws -> [String: StatusRead] {
            let wanted = computers.compactMap { computer -> (String, String)? in
                guard let id = computer.id, let management = computer.general?.managementID else { return nil }
                return (id, management)
            }
            let budget = ReadBudget(parallel)
            var reads: [String: StatusRead] = [:]
            try await withThrowingTaskGroup(of: (String, StatusRead).self) { group in
                for (id, management) in wanted {
                    group.addTask {
                        // one return (swiftlang/swift#93208)
                        let read: StatusRead
                        do {
                            let items = try await budget.run { try await self.jamfPro.statusItems(managementID: management, kind: .computer) }
                            read = StatusRead(items: items)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as JamfPlatform.APIError where error.status == 403 {
                            throw error
                        } catch {
                            read = StatusRead(problem: error.localizedDescription)
                        }
                        return (id, read)
                    }
                }
                while let (id, read) = try await group.next() {
                    reads[id] = read
                    progress(reads.count)
                }
            }
            return reads
        }

        /// The reports of each caching Blueprint’s declarations, by Blueprint
        /// ID and then serial number: the configurations and step
        /// activations the caches list for it, and the configuration as Jamf
        /// names it (`…_declaration_custom_<n>`), each read once in full.
        func reports(for blueprints: inout [CachingBlueprint], held: [String],
                     progress: @Sendable (_ done: Int, _ total: Int) -> Void) async throws
            -> [String: [String: (configuration: JamfPlatform.DeclarationReport?, activation: JamfPlatform.DeclarationReport?)]] {
            var wanted: [(blueprint: String, identifier: String)] = []
            for index in blueprints.indices {
                let blueprint = blueprints[index]
                var identifiers: [String] = []
                for settings in blueprint.settings {
                    let prefix = settings.identifierPrefix(blueprintID: blueprint.id).lowercased()
                    let step = "blueprint_\(blueprint.id.lowercased())_s\(settings.stepIndex + 1)_"
                    identifiers.append(settings.configurationIdentifier(blueprintID: blueprint.id))
                    identifiers += held.filter { identifier in
                        let lower = identifier.lowercased()
                        return JamfPlatform.ContentCacheSettings.isActivation(identifier) ? lower.hasPrefix(step) : lower.hasPrefix(prefix)
                    }
                }
                var seen = Set<String>()
                identifiers = identifiers.filter { seen.insert($0.lowercased()).inserted }
                blueprints[index].identifiers = identifiers
                wanted += identifiers.map { (blueprint.id, $0) }
            }
            let platform = platform
            let devices = try await platform.devices()
            var serials: [String: String] = [:]
            for device in devices {
                if let serial = device.serialNumber?.uppercased(), !serial.isEmpty { serials[device.id.lowercased()] = serial }
            }
            let budget = ReadBudget(parallel)
            var found: [(Int, [JamfPlatform.DeclarationReport])] = []
            try await withThrowingTaskGroup(of: (Int, [JamfPlatform.DeclarationReport]).self) { group in
                for (index, entry) in wanted.enumerated() {
                    group.addTask {
                        let reports = try await budget.run { try await platform.declarationReports(declarationIdentifier: entry.identifier) }
                        return (index, reports ?? [])
                    }
                }
                while let next = try await group.next() {
                    found.append(next)
                    progress(found.count, wanted.count)
                }
            }
            var byBlueprint: [String: [String: (configuration: JamfPlatform.DeclarationReport?, activation: JamfPlatform.DeclarationReport?)]] = [:]
            for (index, reports) in found.sorted(by: { $0.0 < $1.0 }) {
                let blueprint = wanted[index].blueprint
                for report in reports {
                    guard let serial = report.deviceID.flatMap({ serials[$0.lowercased()] }) else { continue }
                    var pair = byBlueprint[blueprint]?[serial] ?? (nil, nil)
                    if JamfPlatform.ContentCacheSettings.isActivation(report.declarationIdentifier) || report.type == "ACTIVATION" {
                        pair.activation = newer(pair.activation, report)
                    } else if report.payloadType == nil || report.payloadType == JamfPlatform.ContentCacheSettings.declarationType {
                        pair.configuration = newer(pair.configuration, report)
                    }
                    byBlueprint[blueprint, default: [:]][serial] = pair
                }
            }
            return byBlueprint
        }

        private func newer(_ current: JamfPlatform.DeclarationReport?, _ next: JamfPlatform.DeclarationReport) -> JamfPlatform.DeclarationReport {
            guard let current else { return next }
            return (next.dateUpdated ?? .distantPast) > (current.dateUpdated ?? .distantPast) ? next : current
        }
    }
}
