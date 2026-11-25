import Foundation

extension SoftwareUpdateRules {
    /// Where a refresh is: the step, and how far it is when it counts something.
    public nonisolated struct RefreshProgress: Sendable, Hashable {
        public var step: String
        public var done = 0
        public var total = 0
        /// What it counts, in the plural (“devices”, “declarations”, “groups”).
        public var unit = ""

        /// “Reading Blueprint health, 3 of 18 declarations”.
        public var text: String { total > 0 ? "\(step), \(done) of \(total) \(unit)" : step }

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            step: String,
            done: Int = 0,
            total: Int = 0,
            unit: String = ""
        ) {
            self.step = step
            self.done = done
            self.total = total
            self.unit = unit
        }
    }

    /// Apple’s release data couldn’t be read at all: no device’s target is
    /// known, so the refresh stops and the previous one is kept.
    public nonisolated struct AppleDataUnavailable: LocalizedError, Equatable {
        public init() {}

        public var errorDescription: String? {
            "Apple’s release data couldn’t be read, so no device’s target is known."
        }
    }

    /// A refresh’s reading and measuring of one Blueprint’s devices: reads the
    /// Blueprint’s software update and scope, the scope groups’ members with
    /// their inventory and each one’s status report, the Blueprint’s
    /// declaration reports (all GETs), gives every device its own target and
    /// sorts it (`Classifier`), with Blueprint health. What the app adds on
    /// top (history, a comparison group, its tables) stays the app’s.
    ///
    /// The Jamf Pro reads (groups, members, status reports) go to `jamfPro`,
    /// the Platform API reads (the Blueprint, its groups, the device list,
    /// declaration reports) to `platform`: the same gateway client twice for
    /// an app on the Platform API alone, or a Jamf Pro client and a Platform
    /// client, each with the app’s own request limits
    /// (`JamfPlatform.Client(maxConcurrent:rateLimit:)`). `parallel` is how
    /// many reads the reader starts at a time.
    ///
    /// Keeps nothing: what earlier refreshes remembered comes in
    /// (`firstPosted`, `reportedDeadlines`), and what to remember after this
    /// one goes back in `Reading.reportedDeadlines`.
    public nonisolated struct Reader: Sendable {
        public let jamfPro: JamfPlatform.Client
        public let platform: JamfPlatform.Client
        /// Apple’s release data; nil when it couldn’t be read (the reading stops).
        public let catalog: AppleReleases.Catalog?
        public let serverTimeZone: TimeZone
        /// The first public posting date the app saw of each build (`FirstPostings`).
        public var firstPosted: [String: Date] = [:]
        /// What earlier refreshes of the Blueprint remembered of its devices’
        /// reported deadlines (`ReportedDeadlines`).
        public var reportedDeadlines = ReportedDeadlines()
        /// Demo Mode: a Blueprint with nothing remembered starts as if earlier
        /// refreshes had seen its Macs report Jamf’s deadline for every version
        /// (`demoReportedDeadlines`).
        public var seedsDemoDeadlines = false
        public var staleDays = 30
        /// Status reports read at the same time.
        public var parallel = 4
        /// Page reads of the Blueprint’s declaration reports in flight at a
        /// time, shared by every declaration: after a declaration’s first page
        /// its other pages are read at once, within this budget.
        public var pageReads = 16

        /// One client for everything: the Platform API, also as the gateway to Jamf Pro.
        public init(client: JamfPlatform.Client, catalog: AppleReleases.Catalog?, serverTimeZone: TimeZone) {
            self.init(jamfPro: client, platform: client, catalog: catalog, serverTimeZone: serverTimeZone)
        }

        public init(jamfPro: JamfPlatform.Client, platform: JamfPlatform.Client, catalog: AppleReleases.Catalog?, serverTimeZone: TimeZone) {
            self.jamfPro = jamfPro
            self.platform = platform
            self.catalog = catalog
            self.serverTimeZone = serverTimeZone
        }

        /// What one reading found.
        public struct Reading: Sendable {
            public var blueprint: JamfPlatform.BlueprintDetail
            /// Every software update block of the Blueprint, and its update settings.
            public var blocks: [JamfPlatform.SoftwareUpdateBlock]
            public var settings: [JamfPlatform.SoftwareUpdateSettings]
            /// The Blueprint’s scope as Jamf Pro groups, by name, and its Platform groups that aren’t one.
            public var scope: [JamfPro.DeviceGroup]
            public var unmatchedScope: Int
            /// Each device once, in the order read.
            public var members: [JamfPro.GroupMember]
            /// What was read of each device: its status report, or why it couldn’t be read.
            public var inputs: [DeviceInput]
            public var devices: [DeviceStatus]
            /// How the Blueprint’s declarations stand; nil when they couldn’t be read.
            public var health: BlueprintHealth?
            /// What to remember of the devices’ reported deadlines after this reading.
            public var reportedDeadlines: ReportedDeadlines
            /// What couldn’t be read but didn’t stop the reading, e.g. part of Apple’s release data.
            public var problems: [String]

            /// Every stored property, in order, with the same defaults as the memberwise initializer.
            public init(
                blueprint: JamfPlatform.BlueprintDetail,
                blocks: [JamfPlatform.SoftwareUpdateBlock],
                settings: [JamfPlatform.SoftwareUpdateSettings],
                scope: [JamfPro.DeviceGroup],
                unmatchedScope: Int,
                members: [JamfPro.GroupMember],
                inputs: [DeviceInput],
                devices: [DeviceStatus],
                health: BlueprintHealth? = nil,
                reportedDeadlines: ReportedDeadlines,
                problems: [String]
            ) {
                self.blueprint = blueprint
                self.blocks = blocks
                self.settings = settings
                self.scope = scope
                self.unmatchedScope = unmatchedScope
                self.members = members
                self.inputs = inputs
                self.devices = devices
                self.health = health
                self.reportedDeadlines = reportedDeadlines
                self.problems = problems
            }
        }

        public func read(blueprintID: String, updateStarted: Date? = nil, now: Date = Date(),
                  progress: @Sendable (RefreshProgress) -> Void = { _ in }) async throws -> Reading {
            guard let catalog else { throw AppleDataUnavailable() }
            progress(RefreshProgress(step: "Reading the Blueprint"))
            let (blueprint, blocks) = try await JamfPlatform.Blueprints(client: platform).softwareUpdate(blueprintID: blueprintID)
            var problems = catalog.problems
            if blocks.isEmpty { problems.append("The Blueprint has no software update.") }

            // the scope, read on every refresh
            progress(RefreshProgress(step: "Reading the Blueprint’s scope"))
            let platformGroups = try await platform.platformGroups()
            // only the group lists the scope needs: an iPhone-only Blueprint lists no computer groups
            let kinds = Self.groupKinds(platformGroupIDs: blueprint.scopeDeviceGroups, platformGroups: platformGroups)
            let groups = kinds.isEmpty ? [] : try await jamfPro.jamfProGroups(kinds)
            let keys = Self.scope(platformGroupIDs: blueprint.scopeDeviceGroups, platformGroups: platformGroups)
            let scope = keys.compactMap { key in groups.first { $0.id == key } }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let unmatched = blueprint.scopeDeviceGroups.count - scope.count
            if unmatched > 0 {
                problems.append("\(unmatched) of the Blueprint’s scope groups \(unmatched == 1 ? "isn’t" : "aren’t") a Jamf Pro mobile device or computer group.")
            }

            // each device once, also when it is in several scope groups
            var members: [JamfPro.GroupMember] = []
            var seen = Set<String>()
            for (number, group) in scope.enumerated() {
                progress(RefreshProgress(step: "Reading group members", done: number, total: scope.count, unit: "groups"))
                for member in try await jamfPro.members(of: group) where seen.insert(Self.key(member)).inserted {
                    members.append(member)
                }
            }

            progress(RefreshProgress(step: "Reading status reports", done: 0, total: members.count, unit: "devices"))
            var inputs = try await statuses(members) { done, total in
                progress(RefreshProgress(step: "Reading status reports", done: done, total: total, unit: "devices"))
            }
            // the Blueprint's update declarations, as the devices list them: the pairs some device holds active
            // read in full, the others once each, for their name
            let reads = BlueprintHealth.reads(blueprintID: blueprintID, statuses: inputs.map(\.status), blocks: blocks)
            let declarations = try await declarationReports(reads, inputs: &inputs, progress: progress)
            var deviceIDs: [String: String] = [:]
            for input in inputs {
                if let platformID = input.platformDeviceID?.lowercased() { deviceIDs[platformID] = Self.key(input.member) }
            }
            let tied = BlueprintHealth.byDevice(declarations.reports, deviceIDs: deviceIDs)
            let current = BlueprintHealth.catalogue(declarations.reports + declarations.samples, blocks: blocks,
                                                    blueprintName: blueprint.overview.name)
            let (known, remember) = deadlineBasis(inputs, blocks: blocks, blueprint: blueprint, updateStarted: updateStarted, now: now)
            var devices = inputs.map { input in
                let osName = Classifier.osName(isComputer: input.member.kind == .computer,
                                               modelIdentifier: input.member.modelIdentifier ?? input.status?.modelIdentifier ?? "")
                return classify(input, blocks: blocks, blueprint: blueprint, updateStarted: updateStarted, now: now, known: known,
                                awaitingSync: BlueprintHealth.isAwaitingSync(tied.reports[Self.key(input.member)] ?? [],
                                                                             osName: osName, current: current))
            }
            var health: BlueprintHealth?
            if let problem = declarations.problem {
                problems.append(problem)
            } else {
                let built = BlueprintHealth.make(byDevice: tied.reports, devices: devices, current: current,
                                                 blueprintName: blueprint.overview.name, blueprintID: blueprintID,
                                                 unmatchedDevices: tied.unmatched,
                                                 devicesWithoutPlatformID: reads.isEmpty ? 0 : inputs.filter { $0.platformDeviceID == nil }.count)
                // the cause where nothing else explains it: the list says it
                for index in devices.indices {
                    devices[index].declarationsChecked = true
                    guard let found = built.coverage[devices[index].id] else {
                        // a failed or invalid update declaration of its own OS explains a device that hasn't started
                        if BlueprintHealth.explainedCategories.contains(devices[index].category),
                           let problem = BlueprintHealth.declarationProblem(tied.reports[devices[index].id] ?? [], osName: devices[index].osName,
                                                                            current: current, names: [blueprintID.lowercased(): blueprint.overview.name]) {
                            devices[index].diagnosis = problem
                        }
                        continue
                    }
                    switch found {
                    case .notCovered(let ranges): devices[index].notCoveredBy = ranges
                    case .notFetched(let last):
                        devices[index].notFetched = true
                        devices[index].notFetchedSince = last
                    }
                    if BlueprintHealth.explainedCategories.contains(devices[index].category) {
                        devices[index].diagnosis = BlueprintHealth.diagnosis(found, device: devices[index])
                    }
                }
                health = built
            }
            return Reading(blueprint: blueprint, blocks: blocks, settings: blueprint.softwareUpdateSettings, scope: scope,
                           unmatchedScope: unmatched, members: members, inputs: inputs, devices: devices, health: health,
                           reportedDeadlines: remember, problems: problems)
        }

        /// What the health step read of the Blueprint’s declarations.
        public struct DeclarationReadings: Sendable {
            /// Every report of the declarations read in full (`BlueprintHealth.Reads.full`).
            public var reports: [JamfPlatform.DeclarationReport] = []
            /// One report per sampled pair (`Reads.sampled`), the newest: for the
            /// catalogue (its name and predicate), never tied to a device.
            public var samples: [JamfPlatform.DeclarationReport] = []
            /// Why the reading stopped, if it did.
            public var problem: String?

            public init(reports: [JamfPlatform.DeclarationReport] = [], samples: [JamfPlatform.DeclarationReport] = [], problem: String? = nil) {
                self.reports = reports
                self.samples = samples
                self.problem = problem
            }
        }

        /// Each of the given update declarations read in full (its devices’
        /// reports, every page), and the Platform device list, read once, to tie
        /// each report to a device by serial number. As `declarationReports(_:inputs:progress:)`
        /// with `BlueprintHealth.Reads`, sampling nothing.
        public func declarationReports(_ identifiers: [String], inputs: inout [DeviceInput],
                                progress: @Sendable (RefreshProgress) -> Void = { _ in }) async throws -> (reports: [JamfPlatform.DeclarationReport], problem: String?) {
            let read = try await declarationReports(BlueprintHealth.Reads(full: identifiers), inputs: &inputs, progress: progress)
            return (read.reports, read.problem)
        }

        /// The Blueprint’s update declarations as `BlueprintHealth.reads` lists
        /// them: the pairs some device holds active in full (their devices’
        /// reports; after a declaration’s first page the pages its count
        /// announces are read at once, every page read within `pageReads`),
        /// the other pairs once each (their newest report, for the catalogue); and the
        /// Platform device list, read once, to tie each report to a device by
        /// serial number. A refusal or a failed read stops the reading and is
        /// returned as the problem (never as “serial not found”); a declaration
        /// nothing reported gives none. A stop is thrown, so a stopped refresh
        /// is never saved.
        public func declarationReports(_ reads: BlueprintHealth.Reads, inputs: inout [DeviceInput],
                                progress: @Sendable (RefreshProgress) -> Void = { _ in }) async throws -> DeclarationReadings {
            guard !reads.isEmpty else { return DeclarationReadings() }
            progress(RefreshProgress(step: "Reading the device list"))
            let platformDevices: [JamfPlatform.Device]
            do {
                platformDevices = try await platform.devices()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return DeclarationReadings(problem: "The Platform device list couldn’t be read, so the Blueprint’s declaration reports can’t be tied to devices: "
                                           + error.localizedDescription)
            }
            var bySerial: [String: String] = [:]
            for device in platformDevices {
                if let serial = device.serialNumber?.uppercased(), !serial.isEmpty { bySerial[serial] = device.id }
            }
            for index in inputs.indices {
                inputs[index].platformDeviceID = inputs[index].member.serialNumber.flatMap { bySerial[$0.uppercased()] }
            }
            let budget = ReadBudget(pageReads)
            let full = reads.full
            let sampled = reads.sampled
            do {
                // in the order of the identifiers, whichever finishes first
                var found = [[JamfPlatform.DeclarationReport]](repeating: [], count: full.count + sampled.count)
                try await withThrowingTaskGroup(of: (Int, [JamfPlatform.DeclarationReport]).self) { group in
                    for (index, identifier) in full.enumerated() {
                        group.addTask { (index, try await self.declaration(identifier, budget: budget)) }
                    }
                    for (offset, identifier) in sampled.enumerated() {
                        group.addTask { (full.count + offset, try await self.sample(identifier, budget: budget)) }
                    }
                    var read = 0
                    progress(RefreshProgress(step: "Reading Blueprint health", done: 0, total: reads.count, unit: "declarations"))
                    while let (index, reports) = try await group.next() {
                        found[index] = reports
                        read += 1
                        progress(RefreshProgress(step: "Reading Blueprint health", done: read, total: reads.count, unit: "declarations"))
                    }
                }
                return DeclarationReadings(reports: found.prefix(full.count).flatMap { $0 },
                                           samples: found.dropFirst(full.count).flatMap { $0 })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return DeclarationReadings(problem: "The Blueprint’s declaration reports couldn’t be read: \(error.localizedDescription)")
            }
        }

        /// Every report of one declaration: its first page, then the pages its
        /// count announces at once (each within the budget), then one page
        /// after another should more have come meanwhile, or when the answer
        /// carries no count. None when nothing reported it (404).
        func declaration(_ identifier: String, budget: ReadBudget) async throws -> [JamfPlatform.DeclarationReport] {
            let pageSize = 100
            let maxPages = 1_000
            func page(_ number: Int) async throws -> JamfPlatform.Page<JamfPlatform.DeclarationReport>? {
                try await budget.run {
                    try await self.platform.declarationReportPage(declarationIdentifier: identifier, page: number, pageSize: pageSize)
                }
            }
            // task-group children call this: one return (swiftlang/swift#93208)
            var reports: [JamfPlatform.DeclarationReport] = []
            if let first = try await page(0) {
                reports = first.results
                var received = first.results.count + first.unreadableCount
                var last = first
                var next = 1
                if JamfPlatform.hasMore(after: first, received: received, pageSize: pageSize), let total = first.totalCount {
                    let announced = min((total + pageSize - 1) / pageSize, maxPages)
                    if announced > 1 {
                        let rest = try await withThrowingTaskGroup(of: (Int, JamfPlatform.Page<JamfPlatform.DeclarationReport>?).self,
                                                                   returning: [(Int, JamfPlatform.Page<JamfPlatform.DeclarationReport>?)].self) { group in
                            for number in 1..<announced {
                                group.addTask { (number, try await page(number)) }
                            }
                            var pages: [(Int, JamfPlatform.Page<JamfPlatform.DeclarationReport>?)] = []
                            for try await result in group { pages.append(result) }
                            return pages.sorted { $0.0 < $1.0 }
                        }
                        for (_, found) in rest {
                            guard let found else { break }
                            reports += found.results
                            received += found.results.count + found.unreadableCount
                            last = found
                        }
                        next = announced
                    }
                }
                while JamfPlatform.hasMore(after: last, received: received, pageSize: pageSize) {
                    guard next < maxPages else {
                        throw JamfPlatform.APIError(.pageLimitReached(path: "ddm/report/v1/declarations/\(identifier)/devices", pages: maxPages))
                    }
                    guard let found = try await page(next) else { break }
                    reports += found.results
                    received += found.results.count + found.unreadableCount
                    last = found
                    next += 1
                }
            }
            return reports
        }

        /// One report of a pair no device in scope holds active: the newest
        /// inactive one, which carries the predicate Jamf last gave the pair
        /// (an active report carries none), as the catalogue would pick it
        /// from every report. None when nothing reported it.
        func sample(_ identifier: String, budget: ReadBudget) async throws -> [JamfPlatform.DeclarationReport] {
            let page = try await budget.run {
                try await self.platform.declarationReportPage(declarationIdentifier: identifier, page: 0, pageSize: 1,
                                                              filter: "active==false", sort: "dateUpdated,desc")
            }
            return page?.results ?? []
        }

        /// What the Blueprint’s computed deadlines count from: the first public
        /// posting dates this app saw and, per platform and version, the posting
        /// date the devices’ own reports say Jamf counted from (`TargetRules.reportedPosting`).
        public func postingBasis(_ inputs: [DeviceInput], blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                          updateStarted: Date?, now: Date) -> PostingBasis {
            deadlineBasis(inputs, blocks: blocks, blueprint: blueprint, updateStarted: updateStarted, now: now).known
        }

        /// The same, with what earlier refreshes of this Blueprint remembered
        /// (`reportedDeadlines`), and what to remember after this one: the
        /// posting dates its devices report now replace those remembered, which
        /// stay while their version is a rule’s target.
        public func deadlineBasis(_ inputs: [DeviceInput], blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                           updateStarted: Date?, now: Date) -> (known: PostingBasis, remember: ReportedDeadlines) {
            var known = PostingBasis(remembered: firstPosted)
            var targets = Set<String>()
            // each reported deadline with when it was reported, per platform and version
            var candidates: [String: [(minute: Int, reportedAt: Date)]] = [:]
            let reports = inputs.compactMap { input -> (platform: AppleReleases.Platform, version: OSVersion, posted: Date)? in
                let device = rule(input, blocks: blocks, blueprint: blueprint, updateStarted: updateStarted, now: now, known: known)
                guard let version = device.rule.osVersion else { return nil }
                if !device.rule.namedByBlueprint && device.rule.unknown == nil { targets.insert(PostingBasis.key(device.platform, version)) }
                guard let found = TargetRules.reportedPosting(device.rule, status: input.status, block: device.block, catalog: catalog,
                                                              platform: device.platform, serverTimeZone: serverTimeZone,
                                                              blueprintChanged: blueprint.overview.updatedDate,
                                                              timeZone: input.member.timeZone) else { return nil }
                if let moment = found.moment {
                    candidates[PostingBasis.key(device.platform, version), default: []].append((PostingBasis.minute(moment), found.reportedAt))
                }
                return (device.platform, version, found.posted)
            }
            known.reported = TargetRules.reportedPostings(reports)
            let reportedDeadlines = seedsDemoDeadlines && self.reportedDeadlines.isEmpty
                ? demoReportedDeadlines(blocks: blocks, now: now, blueprintChanged: blueprint.overview.updatedDate) : self.reportedDeadlines
            let earlier = reportedDeadlines.basis(targets: targets, blueprintChanged: blueprint.overview.updatedDate)
            let minutes = Self.newDeadlineMinutes(candidates, known: earlier.minutes)
            known.rememberedReported = earlier.postings
            known.reportedMinutes = earlier.minutes.merging(minutes) { $0.union($1) }
            let remember = reportedDeadlines.updated(reported: known.reported, moments: minutes, targets: targets,
                                                     blueprintChanged: blueprint.overview.updatedDate, now: now)
            return (known, remember)
        }

        /// The deadline minutes this refresh adds, per platform and version: a
        /// reported minute counts only when it was reported before the earliest
        /// deadline known for that version had passed, whether remembered or
        /// reported in this refresh (with none known yet, before its own time).
        /// A Mac that missed the deadline reports its rescheduled time before
        /// that time arrives, but after Jamf’s deadline: it never counts.
        public static func newDeadlineMinutes(_ candidates: [String: [(minute: Int, reportedAt: Date)]],
                                       known: [String: Set<Int>]) -> [String: Set<Int>] {
            var added: [String: Set<Int>] = [:]
            for (key, reports) in candidates {
                guard let earliest = (reports.map(\.minute) + Array(known[key] ?? [])).min() else { continue }
                let deadline = Date(timeIntervalSince1970: Double(earliest) * 60)
                let kept = Set(reports.filter { $0.reportedAt < deadline }.map(\.minute))
                if !kept.isEmpty { added[key] = kept }
            }
            return added
        }

        /// Demo Mode’s made-up earlier refreshes: Jamf’s deadline for every
        /// macOS version Apple’s data lists, as the rule counts it, written as a
        /// moment in UTC at the Blueprint’s time (as JTKit’s demo Macs write it).
        /// A version Apple posted publicly again after its release counts from
        /// its first posting, and that posting is remembered as the one the
        /// Blueprint’s devices reported (seen the day after the Blueprint’s
        /// last change), as Jamf keeps the deadline it sent.
        func demoReportedDeadlines(blocks: [JamfPlatform.SoftwareUpdateBlock], now: Date,
                                          blueprintChanged: Date? = nil) -> ReportedDeadlines {
            var seeded = ReportedDeadlines()
            guard let catalog, let block = Self.block(for: "macOS", in: blocks) else { return seeded }
            for release in catalog.releases where release.platform == .macOS && release.version.extra == nil {
                let key = PostingBasis.key(.macOS, release.version)
                var known = PostingBasis()
                if let first = release.postings.compactMap(\.date).min(),
                   let posted = catalog.publicPosting(of: release, model: nil, boardID: nil)?.date, posted > first {
                    known.rememberedReported[key] = first
                    seeded.postings[key] = .init(posted: first, seen: (blueprintChanged ?? first).addingTimeInterval(86_400))
                }
                guard let local = TargetRules.ruleDeadline(for: release.version, block: block, catalog: catalog, platform: .macOS,
                                                           model: nil, boardID: nil, known: known),
                      let moment = JamfPlatform.SoftwareUpdateBlock.deadline(local, in: .gmt) else { continue }
                seeded.moments[key] = [.init(minute: PostingBasis.minute(moment), seen: now)]
            }
            return seeded
        }

        /// The Blueprint’s rule for one device, and what it was read with.
        private func rule(_ input: DeviceInput, blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                          updateStarted: Date?, now: Date, known: PostingBasis)
            -> (rule: DeviceTarget, block: JamfPlatform.SoftwareUpdateBlock?, platform: AppleReleases.Platform, osName: String, os: String?) {
            let member = input.member
            let platform: AppleReleases.Platform = member.kind == .computer ? .macOS : .iOS
            let model = member.modelIdentifier ?? input.status?.modelIdentifier
            let osName = Classifier.osName(isComputer: member.kind == .computer, modelIdentifier: model ?? "")
            // the newer of what the device reports and its inventory: a device
            // that installed may not have sent a new status report yet
            let os = Classifier.newer(input.status?.osVersion, member.osVersion)
            let block = Self.block(for: osName, in: blocks)
            let rule = TargetRules.target(
                os: os, model: model, boardID: input.status?.deviceID, osName: osName,
                context: TargetRules.Context(block: block, catalog: catalog, platform: platform,
                                             blueprintChanged: blueprint.overview.updatedDate, updateStarted: updateStarted,
                                             now: now, known: known))
            return (rule, block, platform, osName, os)
        }

        /// One device against its own target.
        public func classify(_ input: DeviceInput, blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                      updateStarted: Date?, now: Date, known: PostingBasis? = nil, awaitingSync: Bool = false) -> DeviceStatus {
            let member = input.member
            let model = member.modelIdentifier ?? input.status?.modelIdentifier
            let known = known ?? PostingBasis(remembered: firstPosted)
            let (rule, block, platform, osName, os) = self.rule(input, blocks: blocks, blueprint: blueprint, updateStarted: updateStarted, now: now,
                                                                known: known)
            // what Jamf actually sent the device comes first, when it reports it
            let target = TargetRules.fromDevice(rule, status: input.status, os: os, osName: osName, catalog: catalog,
                                                platform: platform, serverTimeZone: serverTimeZone, model: model,
                                                boardID: input.status?.deviceID, blueprintChanged: blueprint.overview.updatedDate,
                                                earlierStepDeadline: { [catalog] version in
                                                    TargetRules.ruleDeadline(for: version, block: block, catalog: catalog, platform: platform,
                                                                             model: model, boardID: input.status?.deviceID, known: known)
                                                },
                                                earlierStepWindow: { [catalog] version in
                                                    TargetRules.ruleWindow(for: version, block: block, catalog: catalog, platform: platform,
                                                                           model: model, boardID: input.status?.deviceID, now: now, known: known)
                                                },
                                                awaitingSync: awaitingSync,
                                                postingDeadlines: { [catalog] version, build in
                                                    TargetRules.postingDeadlines(for: version, build: build, block: block, catalog: catalog,
                                                                                 platform: platform).map(\.deadline)
                                                },
                                                known: known,
                                                timeZone: member.timeZone, now: now)
            let base = ClassificationContext(target: nil, since: nil, serverTimeZone: serverTimeZone, now: now, staleDays: staleDays,
                                             catalog: catalog, platform: platform)
            return Classifier.classify(input, target: target, context: base)
        }

        /// Each member’s status report, a few at a time, in the members’ order.
        /// A report that can’t be read is noted on the device, not thrown.
        public func statuses(_ members: [JamfPro.GroupMember], progress: @Sendable (Int, Int) -> Void) async throws -> [DeviceInput] {
            var inputs: [Int: DeviceInput] = [:]
            try await withThrowingTaskGroup(of: (Int, DeviceInput).self) { group in
                var next = 0
                func start() {
                    guard next < members.count else { return }
                    let index = next
                    let member = members[index]
                    next += 1
                    group.addTask {
                        guard let managementID = member.managementID, !managementID.isEmpty else {
                            return (index, DeviceInput(member: member, statusProblem: "No management ID in Jamf Pro"))
                        }
                        // one return at the end, not one from the do and the catch around the read:
                        // Release builds made with Swift 6.4 can crash on that shape (swiftlang/swift#93208)
                        let input: DeviceInput
                        do {
                            let status = try await jamfPro.softwareUpdateStatus(managementID: managementID, kind: member.kind)
                            input = DeviceInput(member: member, status: status)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            input = DeviceInput(member: member, statusProblem: error.localizedDescription)
                        }
                        return (index, input)
                    }
                }
                for _ in 0..<max(1, parallel) { start() }
                while let (index, input) = try await group.next() {
                    inputs[index] = input
                    progress(inputs.count, members.count)
                    start()
                }
            }
            return members.indices.compactMap { inputs[$0] }
        }

        /// A device by kind and Jamf Pro number: a Mac and an iPad can share a number.
        public static func key(_ member: JamfPro.GroupMember) -> String { "\(member.kind.rawValue)/\(member.id)" }

        /// The block for a device: the one whose activation predicate asks for
        /// its OS (`== 'iPadOS'`; never `!= 'iPadOS'`), else one without a
        /// predicate, else the first.
        public static func block(for osName: String, in blocks: [JamfPlatform.SoftwareUpdateBlock]) -> JamfPlatform.SoftwareUpdateBlock? {
            blocks.first { $0.activationPredicate?.range(of: "==\\s*'\(osName)'", options: .regularExpression) != nil }
                ?? blocks.first { $0.activationPredicate == nil }
                ?? blocks.first
        }

        /// The Blueprint’s rule by its values, to compare refreshes: unlike its
        /// text, it doesn’t change with this Mac’s region or clock format.
        public static func ruleKey(_ blocks: [JamfPlatform.SoftwareUpdateBlock]) -> String {
            let keys = blocks.map { block -> String in
                switch block.enforcement {
                case .specific(let version, let deadline, _): "specific|\(version)|\(block.targetBuildVersion ?? "")|\(deadline ?? "")"
                case .latest(let days, let time): "latest|\(days ?? 0)|\(time ?? "")"
                case .semantic(let days, let time): "minor|\(days ?? 0)|\(time ?? "")"
                case .unknown(let kind): "unknown|\(kind ?? "")"
                }
            }
            return Array(NSOrderedSet(array: keys)).compactMap { $0 as? String }.joined(separator: ";")
        }

        /// The Blueprint’s rule in plain language; several blocks joined.
        public static func rule(_ blocks: [JamfPlatform.SoftwareUpdateBlock]) -> String {
            let rules = blocks.map { block -> String in
                switch block.enforcement {
                case .specific(let version, let deadline, _):
                    "Version \(version)" + (deadline.map { " by \(TargetRules.readable($0))" } ?? "")
                case .latest(let days, _):
                    (days ?? 0) == 0 ? "The newest release, without delay" : "The newest release, \(Plural.count(days ?? 0, "day")) after its release"
                case .semantic(let days, _):
                    (days ?? 0) == 0 ? "Minor updates, without delay" : "Minor updates, \(Plural.count(days ?? 0, "day")) after their release"
                case .unknown:
                    "A software update this app doesn’t read"
                }
            }
            return rules.isEmpty ? "No software update" : Array(NSOrderedSet(array: rules)).compactMap { $0 as? String }.joined(separator: "; ")
        }

        /// The kinds of Jamf Pro groups the Blueprint’s scope holds, mobile
        /// device groups first: the reader lists only these (an iPhone-only
        /// Blueprint lists no computer groups). Empty when no scope group is a
        /// Jamf Pro group.
        public static func groupKinds(platformGroupIDs: [String], platformGroups: [JamfPlatform.PlatformGroup]) -> [MDMCommand.DeviceKind] {
            let wanted = Set(platformGroupIDs.map { $0.lowercased() })
            let types = Set(platformGroups.filter { wanted.contains($0.id.lowercased()) }.map(\.deviceType))
            var kinds: [MDMCommand.DeviceKind] = []
            if types.contains(.mobile) { kinds.append(.mobileDevice) }
            if types.contains(.computer) { kinds.append(.computer) }
            return kinds
        }

        /// The Blueprint’s scope as Jamf Pro groups (by kind and number), from
        /// its Platform API group IDs, through the Platform API’s list of
        /// groups (`pro/v2/groups`).
        public static func scope(platformGroupIDs: [String], platformGroups: [JamfPlatform.PlatformGroup]) -> Set<JamfPro.DeviceGroup.ID> {
            let wanted = Set(platformGroupIDs.map { $0.lowercased() })
            return Set(platformGroups.filter { wanted.contains($0.id.lowercased()) }.compactMap(JamfPro.DeviceGroup.ID.init))
        }
    }
}
