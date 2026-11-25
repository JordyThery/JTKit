import Foundation
import JTKitTestSupport
import Testing
@testable import JTKit

private let blueprint = "7b000000-1111-4000-8000-00000000c0de"

private final class CountingToken: BearerTokenSource, @unchecked Sendable {
    private let state = Locked((now: 0, most: 0))
    var most: Int { state.value.most }

    func token() async throws -> String {
        state.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
        try await Task.sleep(for: .milliseconds(20))
        state.withLock { $0.now -= 1 }
        return "token"
    }

    func forgetToken() async {}
}

/// A token that takes long enough for a stop to come first.
private final class SlowToken: BearerTokenSource, Sendable {
    func token() async throws -> String {
        try await Task.sleep(for: .seconds(30))
        return "token"
    }

    func forgetToken() async {}
}

/// A Declaration Reporting server: so many reports per declaration, pages of
/// `size`, with or without a `totalCount`; one declaration can grow after
/// its first page.
private struct ReportServer {
    var counts: [String: Int]
    var withCount = true
    /// The declaration whose count grows by this many after page 0 was read.
    var grows: (identifier: String, by: Int)?

    func make() -> MockServer {
        let grown = Locked(Set<String>())
        return MockServer { request in
            if request.path.hasPrefix("/devices/v1/devices") { return .json(200, #"{"totalCount":0,"results":[]}"#) }
            guard let identifier = request.path.split(separator: "/").dropFirst(4).first.map(String.init),
                  request.path.hasSuffix("/devices"), var count = counts[identifier] else { return .json(404, "{}") }
            let page = Int(request.queryValue("page") ?? "0") ?? 0
            let size = Int(request.queryValue("size") ?? "100") ?? 100
            if let grows, grows.identifier == identifier {
                if page == 0 { grown.withLock { _ = $0.insert(identifier) } } else if grown.value.contains(identifier) { count += grows.by }
            }
            let results = (page * size..<min(count, (page + 1) * size)).map {
                #"{"declarationIdentifier":"\#(identifier)","deviceId":"D-\#($0)","status":"SUCCESSFUL","active":true,"type":"CONFIGURATION"}"#
            }
            let total = withCount ? #""totalCount":\#(count),"# : ""
            return .json(200, "{\(total)\"results\":[\(results.joined(separator: ","))]}")
        }
    }
}

@Suite("1.10.0: the health step’s reads")
@MainActor
struct SoftwareUpdateHealthSpeedTests {
    private func client(_ server: MockServer, tokens: any BearerTokenSource = FixedToken("tok")) throws -> JamfPlatform.Client {
        try JamfPlatform.Client(baseURL: URL(string: "https://us.api.jamfcloud.com")!,
                                scope: .environment("6f2b3c1d-0000-4000-8000-000000000001"), tokens: tokens,
                                recorder: RequestRecorder(session: server.session, log: nil))
    }

    private func reader(_ server: MockServer, tokens: any BearerTokenSource = FixedToken("tok")) throws -> SoftwareUpdateRules.Reader {
        SoftwareUpdateRules.Reader(client: try client(server, tokens: tokens), catalog: AppleReleases.Catalog(), serverTimeZone: .gmt)
    }

    private func pages(_ server: MockServer, of identifier: String) -> [(page: Int, size: Int)] {
        server.requests.filter { $0.path.contains("/declarations/\(identifier)/") }
            .map { (Int($0.queryValue("page") ?? "") ?? -1, Int($0.queryValue("size") ?? "") ?? -1) }
    }

    // MARK: Part 1: the remaining pages at once

    @Test("After page 0 the pages the count announces are read at once; the reports equal a page-by-page read, in the same order")
    func parallelPagesEqualSequential() async throws {
        let server = ReportServer(counts: ["big": 350, "small": 40, "none": 0]).make()
        var inputs: [SoftwareUpdateRules.DeviceInput] = []
        let read = try await reader(server).declarationReports(["big", "small", "none"], inputs: &inputs)
        #expect(read.problem == nil)
        let sequential = try await client(ReportServer(counts: ["big": 350]).make()).declarationReports(declarationIdentifier: "big") ?? []
        #expect(sequential.count == 350)
        #expect(read.reports.filter { $0.declarationIdentifier == "big" }.map(\.deviceID) == sequential.map(\.deviceID))
        #expect(read.reports.filter { $0.declarationIdentifier == "small" }.count == 40)
        #expect(read.reports.filter { $0.declarationIdentifier == "none" }.isEmpty)
        let big = pages(server, of: "big")
        #expect(big.first?.page == 0, "the first page comes first: it carries the count")
        #expect(big.map(\.page).sorted() == [0, 1, 2, 3])
        #expect(big.allSatisfy { $0.size == 100 })
        #expect(pages(server, of: "small").map(\.page) == [0])
        #expect(pages(server, of: "none").map(\.page) == [0])
    }

    @Test("Devices added after the first page are read page by page after the announced ones; without a count, page by page as before")
    func growthAndNoCount() async throws {
        let grown = ReportServer(counts: ["grow": 250], grows: ("grow", 100)).make()
        var inputs: [SoftwareUpdateRules.DeviceInput] = []
        let read = try await reader(grown).declarationReports(["grow"], inputs: &inputs)
        #expect(read.reports.count == 350)
        #expect(pages(grown, of: "grow").map(\.page).sorted() == [0, 1, 2, 3])

        let uncounted = ReportServer(counts: ["plain": 150], withCount: false).make()
        let plain = try await reader(uncounted).declarationReports(["plain"], inputs: &inputs)
        #expect(plain.reports.count == 150)
        #expect(pages(uncounted, of: "plain").map(\.page) == [0, 1], "one after another: the second page is short, so it ends the list")
    }

    @Test("Every page read of every declaration shares one budget: 16 by default, never more; a smaller one holds")
    func budget() async throws {
        let counts = Dictionary(uniqueKeysWithValues: (1...6).map { ("d\($0)", 1_000) })
        var inputs: [SoftwareUpdateRules.DeviceInput] = []
        let standard = CountingToken()
        let wide = try reader(ReportServer(counts: counts).make(), tokens: standard)
        #expect(wide.pageReads == 16)
        let read = try await wide.declarationReports(Array(counts.keys), inputs: &inputs)
        #expect(read.reports.count == 6_000 && read.problem == nil)
        #expect(standard.most <= 16, "\(standard.most)")
        #expect(standard.most >= 8, "the pages are read at once: \(standard.most)")

        let narrow = CountingToken()
        var small = try reader(ReportServer(counts: counts).make(), tokens: narrow)
        small.pageReads = 3
        _ = try await small.declarationReports(Array(counts.keys), inputs: &inputs)
        #expect(narrow.most <= 3, "\(narrow.most)")
    }

    @Test("A stop while the pages are read is thrown as a stop")
    func stopped() async throws {
        // every request waits for its token for a long time: the stop comes while the pages are in flight
        let slow = SlowToken()
        let reader = try reader(ReportServer(counts: ["d": 5_000]).make(), tokens: slow)
        let task = Task {
            var inputs: [SoftwareUpdateRules.DeviceInput] = []
            return try await reader.declarationReports(["d"], inputs: &inputs)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    // MARK: Part 2: pairs no device holds active

    @Test("The status report says which declarations a device holds active, whatever the order of the fields and the nested reasons")
    func activeIdentifiers() {
        let mine = "Blueprint_\(blueprint)_s1_c1_sys_"
        let text = "{activations=[{active=true, identifier=\(mine)act2, valid=valid, server-token=0a}, "
            + "{reasons=[{details={Identifier=\(mine)act1, ServerToken=0b, Predicate=status.device.operating-system.family == \"iOS\" AND "
            + "status.device.model.identifier IN {\"iPhone12,1\", \"iPhone12,3\"}}, description=Activation “\(mine)act1:0b” has errors., "
            + "code=Info.Predicate}], active=false, identifier=\(mine)act1, valid=valid, server-token=0b}], assets=[], "
            + "configurations=[{active=true, identifier=\(mine)cfg2, valid=valid, server-token=0c}, "
            + "{reasons=[{details={Identifier=\(mine)act1, ServerToken=0b}, description=Activation “\(mine)act1:0b” has errors., "
            + "code=Error.ActivationFailed}], active=false, identifier=\(mine)cfg1, valid=unknown, server-token=0d}], management=[]}"
        let status = Sample.status([("management.declarations", text)])
        #expect(status.declarationIdentifiers == ["\(mine)act2", "\(mine)act1", "\(mine)cfg2", "\(mine)cfg1"])
        #expect(status.activeDeclarationIdentifiers == ["\(mine)act2", "\(mine)cfg2"])

        let json = #"{"activations":[{"identifier":"a1","active":true,"reasons":[{"details":{"Identifier":"x{y"}}]},{"active":false,"identifier":"a2"}]}"#
        #expect(Sample.status([("management.declarations", json)]).activeDeclarationIdentifiers == ["a1"])

        let flattened = Sample.status([("management.declarations.configurations[0].identifier", "c1"),
                                       ("management.declarations.configurations[0].active", "true"),
                                       ("management.declarations.configurations[1].identifier", "c2"),
                                       ("management.declarations.configurations[1].active", "false")])
        #expect(flattened.declarationIdentifiers == ["c1", "c2"] && flattened.activeDeclarationIdentifiers == ["c1"])
    }

    @Test("Pairs some device holds active are read in full; the others once, by their activation; an identifier without a number in full")
    func reads() {
        let mine = "Blueprint_\(blueprint)_s1_c1_sys_"
        func status(_ entries: [(String, Bool)]) -> JamfPro.SoftwareUpdateStatus {
            let list = entries.map { "{identifier=\($0.0), active=\($0.1)}" }.joined(separator: ", ")
            return Sample.status([("management.declarations", "{activations=[\(list)], configurations=[]}")])
        }
        // device 1 holds pair 12 active (by its configuration only); device 2 holds pair 3 awaiting sync (active); pair 7 nowhere
        let one = status([("\(mine)cfg12", true), ("\(mine)act12", false), ("\(mine)cfg7", false), ("\(mine)act7", false), ("\(mine)odd", false)])
        let two = status([("\(mine)act3", true), ("\(mine)cfg3", true), ("\(mine)act7", false), ("\(mine)cfg7", false)])
        let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))
        let reads = SoftwareUpdateRules.BlueprintHealth.reads(blueprintID: blueprint.uppercased(), statuses: [one, nil, two], blocks: [block])
        #expect(reads.full == ["\(mine)cfg12", "\(mine)act12", "\(mine)odd", "\(mine)act3", "\(mine)cfg3"])
        #expect(reads.sampled == ["\(mine)act7"])
        #expect(reads.count == 6 && !reads.isEmpty)
        #expect(SoftwareUpdateRules.BlueprintHealth.pairKey("\(mine)cfg12") == SoftwareUpdateRules.BlueprintHealth.pairKey("\(mine)act12"))
        #expect(SoftwareUpdateRules.BlueprintHealth.pairKey("\(mine)odd") == "\(mine)odd")
        #expect(SoftwareUpdateRules.BlueprintHealth.reads(blueprintID: blueprint, statuses: [nil], blocks: [block]).isEmpty)
    }

    private struct Demo {
        let mode: DemoMode
        let source: DemoSource
        func client(log: ActivityLog? = nil) throws -> JamfPlatform.Client {
            try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                    recorder: RequestRecorder(session: source.session, log: log), sleep: { _ in })
        }
        func catalog() async throws -> AppleReleases.Catalog {
            try await AppleReleases.Client(recorder: RequestRecorder(session: source.session, log: nil), userAgent: "JTKit tests",
                                           sofaURL: DemoAppleReleaseServer.sofaURL, gdmfURL: DemoAppleReleaseServer.gdmfURL).catalog()
        }
    }

    private func demo() throws -> Demo {
        let defaults = UserDefaults(suiteName: "jtkit-health-speed-\(UUID().uuidString)")!
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        DemoSoftwareUpdate.install(on: mode.jamfPlatformServer)
        return Demo(mode: mode, source: try #require(mode.source(for: .demoJamfPlatform)))
    }

    private func reportRequests(_ log: ActivityLog) -> [(identifier: String, size: String?, filter: String?, sort: String?)] {
        log.entries.filter { $0.operation.hasPrefix("GET") }.compactMap { entry -> (String, String?, String?, String?)? in
            guard let text = entry.request?.url, let url = URL(string: text), url.path().contains("/ddm/report/v1/declarations/") else { return nil }
            let identifier = url.path().split(separator: "/").dropFirst(4).first.map(String.init) ?? ""
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            return (identifier, value("size"), value("filter"), value("sort"))
        }
    }

    @Test("Demo: a pair no Mac holds active is read once, by its activation; the rows, the “others” line and Inspect’s list are as with every report")
    func demoSkipsOldPairs() async throws {
        let demo = try demo()
        let log = ActivityLog()
        let reader = SoftwareUpdateRules.Reader(client: try demo.client(log: log), catalog: try await demo.catalog(), serverTimeZone: .gmt)
        let now = Date()
        let reading = try await reader.read(blueprintID: DemoSoftwareUpdate.macBlueprintID, now: now)
        let health = try #require(reading.health)
        let requests = reportRequests(log)
        // the macOS 26 pair: no demo Mac runs 26, so none holds it active (one Mac on 15 holds the macOS 15 pair)
        let old = DemoSoftwareUpdate.macPairs[1]
        let sample = requests.filter { $0.identifier == old.activation }
        #expect(sample.map(\.size) == ["1"], "one report of the old pair’s activation")
        #expect(sample.first?.filter == "active==false" && sample.first?.sort == "dateUpdated,desc", "the newest inactive one, which carries the predicate")
        #expect(!requests.contains { $0.identifier == old.configuration }, "its configuration isn’t read")
        for pair in [DemoSoftwareUpdate.macPairs[0], DemoSoftwareUpdate.macPairs[2]] {
            #expect(requests.filter { $0.identifier == pair.configuration }.map(\.size) == ["100"])
            #expect(requests.filter { $0.identifier == pair.activation }.map(\.size) == ["100"])
            #expect(requests.filter { $0.identifier == pair.activation }.allSatisfy { $0.filter == "active==true,active==false" && $0.sort == nil })
        }
        #expect(health.current.count == 3 && health.current.contains { $0.key == SoftwareUpdateRules.BlueprintHealth.pairKey(old.configuration) })
        #expect(health.inapplicable == 1 && health.declarations.count == 2)

        // every report read, as before 1.10.0: the same rows, the same “others” count, the same list, the same coverage
        var inputs = reading.inputs
        let identifiers = SoftwareUpdateRules.BlueprintHealth.identifiers(blueprintID: DemoSoftwareUpdate.macBlueprintID,
                                                                            statuses: inputs.map(\.status), blocks: reading.blocks)
        #expect(identifiers.count == 6)
        let every = try await reader.declarationReports(identifiers, inputs: &inputs)
        var deviceIDs: [String: String] = [:]
        for input in inputs where input.platformDeviceID != nil { deviceIDs[input.platformDeviceID!.lowercased()] = SoftwareUpdateRules.Reader.key(input.member) }
        let tied = SoftwareUpdateRules.BlueprintHealth.byDevice(every.reports, deviceIDs: deviceIDs)
        let current = SoftwareUpdateRules.BlueprintHealth.catalogue(every.reports, blocks: reading.blocks, blueprintName: reading.blueprint.overview.name)
        let before = SoftwareUpdateRules.BlueprintHealth.make(byDevice: tied.reports, devices: reading.devices, current: current,
                                                              blueprintName: reading.blueprint.overview.name, blueprintID: DemoSoftwareUpdate.macBlueprintID)
        #expect(before.declarations == health.declarations)
        #expect(before.inapplicable == health.inapplicable)
        #expect(before.current.map(\.name) == health.current.map(\.name))
        #expect(before.current.map(\.predicate) == health.current.map(\.predicate))
        #expect(before.coverage == health.coverage)
    }

    @Test("Demo: the iPad Blueprint’s iOS step, which no iPad holds active, is read once and still listed")
    func demoIPadStep() async throws {
        let demo = try demo()
        let log = ActivityLog()
        let reader = SoftwareUpdateRules.Reader(client: try demo.client(log: log), catalog: try await demo.catalog(), serverTimeZone: .gmt)
        let reading = try await reader.read(blueprintID: DemoSoftwareUpdate.iPadBlueprintID)
        let health = try #require(reading.health)
        let iOS = DemoSoftwareUpdate.iPadPairs[1]
        let requests = reportRequests(log)
        #expect(requests.filter { $0.identifier == iOS.activation }.map(\.size) == ["1"])
        #expect(!requests.contains { $0.identifier == iOS.configuration })
        #expect(requests.filter { $0.identifier == DemoSoftwareUpdate.iPadPairs[0].configuration }.map(\.size) == ["100"])
        #expect(health.current.count == 2 && health.inapplicable == 1 && health.declarations.count == 1)
        #expect(health.current.map(\.family) == ["iPadOS", "iOS"])
    }

    // MARK: Only the group kinds the scope needs

    @Test("The reader lists only the Jamf Pro group kinds the scope holds")
    func groupKinds() async throws {
        typealias Reader = SoftwareUpdateRules.Reader
        let groups = [
            JamfPlatform.PlatformGroup(id: "P-M", name: "Phones", jamfProID: "1", deviceType: .mobile),
            JamfPlatform.PlatformGroup(id: "P-C", name: "Macs", jamfProID: "2", deviceType: .computer),
            JamfPlatform.PlatformGroup(id: "P-X", name: "Other", jamfProID: "3", deviceType: .other("TV")),
        ]
        #expect(Reader.groupKinds(platformGroupIDs: ["p-m"], platformGroups: groups) == [.mobileDevice])
        #expect(Reader.groupKinds(platformGroupIDs: ["P-C"], platformGroups: groups) == [.computer])
        #expect(Reader.groupKinds(platformGroupIDs: ["P-C", "P-M"], platformGroups: groups) == [.mobileDevice, .computer])
        #expect(Reader.groupKinds(platformGroupIDs: ["P-X", "nope"], platformGroups: groups).isEmpty)

        let demo = try demo()
        let proLog = ActivityLog()
        let reader = Reader(jamfPro: try demo.client(log: proLog), platform: try demo.client(), catalog: try await demo.catalog(), serverTimeZone: .gmt)
        func paths() -> [String] { proLog.entries.filter { $0.operation.hasPrefix("GET") }.compactMap { $0.request?.url } }
        let iPads = try await reader.read(blueprintID: DemoSoftwareUpdate.iPadBlueprintID)
        #expect(iPads.scope.map(\.name) == ["Field iPads"])
        #expect(paths().contains { $0.contains("mobile-device-groups") } && !paths().contains { $0.contains("computer-groups") })
        let macs = try await reader.read(blueprintID: DemoSoftwareUpdate.macBlueprintID)
        #expect(macs.scope.map(\.name) == ["Studio Macs"])
        #expect(paths().contains { $0.contains("computer-groups") })
        #expect(paths().filter { $0.contains("mobile-device-groups") && !$0.contains("membership") }.count == 1, "only the iPad read listed them")
    }
}
