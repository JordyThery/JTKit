import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

// 1.5.0: Apple’s release data from SOFA and GDMF. The feeds here are small
// made-up ones in the sources’ shape; no request leaves the test.

private let sofaIOS = #"""
{"SchemaVersion":"2.0","OSVersions":[
  {"OSVersion":"27","Latest":{"ProductVersion":"27.1","Build":"24B5074","ReleaseDate":"2026-10-26T00:00:00Z","SupportedDevices":["iPad13,18","iPad14,8"],"SecurityInfo":"https://support.example/27-1"},
   "SecurityReleases":[{"ProductVersion":"27.1","Build":"24B5074"},{"ProductVersion":"27.0.1","Build":"24A5341","ReleaseDate":"2026-09-30T00:00:00Z"}]},
  {"OSVersion":"17","Latest":{"ProductVersion":"17.7.10","Build":"21H5450","SupportedDevices":["iPad7,5","iPad13,18"]},"SecurityReleases":[]}],
 "Devices":{"iPad7,5":{"MarketingName":"iPad (6th generation) Wi-Fi"}}}
"""#

private let sofaMacOS = #"""
{"OSVersions":[
  {"OSVersion":"Golden Gate 27","Latest":{"ProductVersion":"27.1","Build":"26B5060","SupportedDevices":["J413AP"]},"SecurityReleases":[]},
  {"OSVersion":"Sequoia 15","Latest":{"ProductVersion":"15.7.4","Build":"24G5420","SupportedDevices":["J413AP","J132AP"]},"SecurityReleases":[]}],
 "Models":{"Mac14,2":{"MarketingName":"MacBook Air (M2)","OSVersions":[27,26,15]},"MacBookPro15,2":{"MarketingName":"MacBook Pro (2018)","OSVersions":[15,14]}},
 "Devices":{"J132AP":{"DeviceID":"MacBookPro15,2"},"J413AP":{"DeviceID":"Mac14,2"}}}
"""#

private let gdmf = #"""
{"PublicAssetSets":{
  "iOS":[{"ProductVersion":"27.0.2","Build":"24A5350","PostingDate":"2026-10-10","ExpirationDate":"2027-01-10","SupportedDevices":["iPad13,18","iPhone17,1"]},
         {"ProductVersion":"8.8.2","Build":"19U5526","PostingDate":"2026-10-26","SupportedDevices":["Watch3,1"]}],
  "macOS":[{"ProductVersion":"27.1","Build":"26B5060","PostingDate":"2026-10-26","SupportedDevices":["J413AP","J999AP"]}]},
 "AssetSets":{}}
"""#

private func catalog() throws -> AppleReleases.Catalog {
    try AppleReleases.Catalog(sofaIOS: Data(sofaIOS.utf8), sofaMacOS: Data(sofaMacOS.utf8), gdmf: Data(gdmf.utf8))
}

@Suite("1.5.0: OSVersion")
struct OSVersionTests {
    @Test("Reads versions in many spellings")
    func parsing() {
        #expect(OSVersion("27.0.1") == OSVersion(major: 27, minor: 0, patch: 1))
        #expect(OSVersion("iOS 27.1") == OSVersion(major: 27, minor: 1))
        #expect(OSVersion("macOS Golden Gate 27.2")?.major == 27)
        #expect(OSVersion("Sequoia 15") == OSVersion(major: 15))
        #expect(OSVersion("26.3.1 (a)")?.extra == "(a)")
        #expect(OSVersion("") == nil)
        #expect(OSVersion("none") == nil)
    }

    @Test("Compares by number; a missing part is 0; a Rapid Security Response is a little newer")
    func ordering() throws {
        #expect(try #require(OSVersion("27.10")) > #require(OSVersion("27.9")))
        #expect(OSVersion("27") == OSVersion("27.0.0"))
        #expect(Set([OSVersion("27")!, OSVersion("27.0")!]).count == 1)
        #expect(try #require(OSVersion("26.3.1 (a)")) > #require(OSVersion("26.3.1")))
        #expect(try #require(OSVersion("26.3.1 (a)")) < #require(OSVersion("26.3.2")))
        #expect(try #require(OSVersion("9.9.9")) < #require(OSVersion("10.0")))
    }

    @Test("Writes and codes as text")
    func text() throws {
        #expect(OSVersion("27")?.description == "27.0")
        #expect(OSVersion("27.0.1")?.description == "27.0.1")
        #expect(OSVersion("26.3.1 (a)")?.description == "26.3.1 (a)")
        let data = try JSONEncoder().encode([OSVersion("27.1")!])
        #expect(String(decoding: data, as: UTF8.self) == #"["27.1"]"#)
        #expect(try JSONDecoder().decode([OSVersion].self, from: data) == [OSVersion("27.1")!])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([OSVersion].self, from: Data(#"["x"]"#.utf8)) }
    }
}

@Suite("1.5.0: Apple’s release catalog")
struct AppleReleaseCatalogTests {
    @Test("Latest per major, builds from either source, newest first")
    func releases() throws {
        let catalog = try catalog()
        #expect(catalog.majors(.iOS) == [27, 17])
        #expect(catalog.latest(.iOS)?.version == OSVersion("27.1"))
        #expect(catalog.latest(.iOS, major: 17)?.build == "21H5450")
        #expect(catalog.build(of: OSVersion("27.0.1")!, .iOS) == "24A5341")
        // only GDMF knows this one
        #expect(catalog.build(of: OSVersion("27.0.2")!, .iOS) == "24A5350")
        #expect(catalog.release(OSVersion("27.0.2")!, .iOS)?.expirationDate != nil)
        #expect(catalog.release(OSVersion("27.1")!, .iOS)?.securityInfo == URL(string: "https://support.example/27-1"))
        #expect(catalog.latest(.macOS)?.build == "26B5060")
        #expect(catalog.majors(.macOS) == [27, 15])
        let iOS = catalog.releases.filter { $0.platform == .iOS }.map(\.version)
        #expect(iOS == iOS.sorted(by: >))
    }

    @Test("Apple Watch releases in GDMF’s iOS list are left out")
    func watchLeftOut() throws {
        let catalog = try catalog()
        #expect(catalog.release(OSVersion("8.8.2")!, .iOS) == nil)
        #expect(catalog.majors(.iOS).contains(8) == false)
    }

    @Test("iPhones and iPads by model: supported, not supported, unknown")
    func mobileSupport() throws {
        let catalog = try catalog()
        #expect(catalog.supports(model: "iPad13,18", major: 27, .iOS) == true)
        #expect(catalog.supports(model: "iPad7,5", major: 27, .iOS) == false)
        #expect(catalog.supports(model: "iPhone17,1", major: 27, .iOS) == true)
        #expect(catalog.supports(model: "iPad99,1", major: 27, .iOS) == nil)
        #expect(catalog.supports(model: nil, major: 27, .iOS) == nil)
        #expect(catalog.lastSupportedVersion(model: "iPad7,5", .iOS) == OSVersion("17.7.10"))
        #expect(catalog.lastSupportedVersion(model: "iPad13,18", .iOS) == OSVersion("27.1"))
        #expect(catalog.marketingName("iPad7,5") == "iPad (6th generation) Wi-Fi")
    }

    @Test("Macs by model through SOFA’s models, or by board ID")
    func macSupport() throws {
        let catalog = try catalog()
        #expect(catalog.supports(model: "Mac14,2", major: 27, .macOS) == true)
        #expect(catalog.supports(model: "MacBookPro15,2", major: 27, .macOS) == false)
        // the board ID of a Mac whose inventory has no model
        #expect(catalog.supports(model: nil, boardID: "J132AP", major: 27, .macOS) == false)
        #expect(catalog.supports(model: nil, boardID: "J132AP", major: 15, .macOS) == true)
        // a board ID only Apple’s list knows
        #expect(catalog.supports(model: nil, boardID: "J999AP", major: 27, .macOS) == true)
        #expect(catalog.supports(model: "Mac99,9", major: 27, .macOS) == nil)
        #expect(catalog.lastSupportedVersion(model: "MacBookPro15,2", .macOS) == OSVersion("15.7.4"))
        #expect(catalog.marketingName("J132AP") == "MacBook Pro (2018)")
        #expect(catalog.supportedDevices(.macOS, major: 27).isSuperset(of: ["J413AP", "Mac14,2"]))
    }

    @Test("Something that isn’t a feed is an error; a missing source isn’t")
    func sources() throws {
        #expect(throws: AppleReleases.FeedError.self) { try AppleReleases.Catalog(gdmf: Data(#"{"hello":1}"#.utf8)) }
        #expect(throws: AppleReleases.FeedError.self) { try AppleReleases.Catalog(sofaIOS: Data("<html>".utf8)) }
        let onlyApple = try AppleReleases.Catalog(gdmf: Data(gdmf.utf8))
        #expect(onlyApple.latest(.iOS)?.version == OSVersion("27.0.2"))
    }
}

@Suite("1.5.0: reading Apple’s release data")
struct AppleReleaseClientTests {
    @Test("Three GETs with the app’s User-Agent and no credentials")
    func requests() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/v2/ios_data_feed.json": .json(200, sofaIOS)
            case "/v2/macos_data_feed.json": .json(200, sofaMacOS)
            case "/v2/pmv": .json(200, gdmf)
            default: .json(404, "{}")
            }
        }
        let client = AppleReleases.Client(recorder: RequestRecorder(session: server.session, log: nil, service: "Apple"),
                                          userAgent: "Example App/1.0", sleep: { _ in })
        let catalog = try await client.catalog()
        #expect(catalog.problems.isEmpty)
        #expect(catalog.latest(.macOS)?.version == OSVersion("27.1"))
        #expect(Set(server.requests.map { "\($0.method) \($0.url.host() ?? "")\($0.path)" }) == [
            "GET sofafeed.macadmins.io/v2/ios_data_feed.json", "GET sofafeed.macadmins.io/v2/macos_data_feed.json",
            "GET gdmf.apple.com/v2/pmv",
        ])
        for request in server.requests {
            #expect(request.header("User-Agent") == "Example App/1.0")
            #expect(request.header("Authorization") == nil)
            #expect(request.header("Cookie") == nil)
        }
    }

    @Test("Only the platforms asked for")
    func platforms() async throws {
        let server = MockServer { _ in .json(200, sofaIOS) }
        let client = AppleReleases.Client(recorder: RequestRecorder(session: server.session, log: nil), userAgent: "X", sleep: { _ in })
        _ = try? await client.catalog([.iOS])
        #expect(!server.requests.contains { $0.path.contains("macos") })
    }

    @Test("A source that fails is named; the rest is used; nothing read is an error")
    func failures() async throws {
        let partly = MockServer { request in
            request.path == "/v2/pmv" ? .json(503, "{}") : .json(200, request.path.contains("ios") ? sofaIOS : sofaMacOS)
        }
        let client = AppleReleases.Client(recorder: RequestRecorder(session: partly.session, log: nil), userAgent: "X", sleep: { _ in })
        let catalog = try await client.catalog()
        #expect(catalog.latest(.iOS)?.version == OSVersion("27.1"))
        #expect(catalog.problems.count == 1 && catalog.problems[0].hasPrefix("GDMF"))

        let broken = MockServer { _ in .json(500, "{}") }
        let none = AppleReleases.Client(recorder: RequestRecorder(session: broken.session, log: nil), userAgent: "X", sleep: { _ in })
        await #expect(throws: (any Error).self) { try await none.catalog() }
    }

    @Test("A source answering with something else is a problem, not a crash")
    func wrongAnswer() async throws {
        let server = MockServer { request in
            request.path == "/v2/pmv" ? .json(200, gdmf) : .json(200, #"{"not":"a feed"}"#)
        }
        let catalog = try await AppleReleases.Client(recorder: RequestRecorder(session: server.session, log: nil),
                                                     userAgent: "X", sleep: { _ in }).catalog()
        #expect(catalog.problems.count == 2)
        #expect(catalog.latest(.macOS)?.version == OSVersion("27.1"))
    }
}

@Suite("1.5.0: demo devices mid-update")
@MainActor
struct DemoSoftwareUpdateTests {
    private func demo() throws -> (DemoMode, JamfPlatform.Client, DemoSource) {
        let defaults = UserDefaults(suiteName: "jtkit-demo-sw-\(UUID().uuidString)")!
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        DemoSoftwareUpdate.install(on: demo.jamfPlatformServer)
        let source = try #require(demo.source(for: .demoJamfPlatform))
        let client = try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                             recorder: RequestRecorder(session: source.session, log: nil), sleep: { _ in })
        return (demo, client, source)
    }

    @Test("The groups, the members and every iPad’s status, through JTKit’s real client")
    func iPads() async throws {
        let (_, client, _) = try demo()
        let groups = try await client.jamfProGroups()
        #expect(groups.map(\.name) == ["Field iPads", "Spare iPads", "Studio Macs", "Loaner Macs"])
        let iPads = try await client.members(of: groups[0])
        #expect(iPads.count == DemoSoftwareUpdate.iPads.count)
        #expect(Set(iPads.map(\.serialNumber)) == Set(DemoSoftwareUpdate.iPads.map(\.serial)))
        #expect(iPads.contains { $0.timeZone == "America/St_Johns" })
        #expect(iPads.contains { $0.timeZone == nil })

        var states: [String: JamfPro.SoftwareUpdateStatus?] = [:]
        for iPad in iPads {
            states[iPad.name ?? ""] = try await client.softwareUpdateStatus(managementID: iPad.managementID ?? "", kind: .mobileDevice)
        }
        #expect(states["Field iPad 01"]??.osVersion == "27.1")
        #expect(states["Field iPad 03"]??.installState == .downloading)
        #expect(states["Field iPad 04"]??.failure?.reason?.hasPrefix("PasscodeRequired") == true)
        #expect(states["Field iPad 05"]??.pendingVersion?.osVersion == "27.0.2")
        #expect(states["Field iPad 06"]??.failure?.count == 3)
        #expect(states["Field iPad 07"] == .some(nil))
        #expect(states["Field iPad 12"]??.installState == .installing)
    }

    @Test("Smart and static computer groups, with inventory and status")
    func macs() async throws {
        let (_, client, _) = try demo()
        let groups = try await client.computerGroups()
        let studio = try await client.members(of: try #require(groups.first { $0.isSmart }))
        let loaners = try await client.members(of: try #require(groups.first { !$0.isSmart }))
        #expect(studio.count == 11 && loaners.count == 2)
        let old = try #require(studio.first { $0.modelIdentifier == "MacBookPro15,2" })
        let status = try await client.softwareUpdateStatus(managementID: old.managementID ?? "", kind: .computer)
        #expect(status?.deviceID == "J132AP")
    }

    @Test("1.7.0: the new cases: an older pending version with the newer deadline, a failed earlier step, an older release, enrollment")
    func newCases() async throws {
        let (_, client, _) = try demo()
        let now = Date()
        let groups = try await client.computerGroups()
        let studio = try await client.members(of: try #require(groups.first { $0.isSmart }))
        func status(_ name: String) async throws -> JamfPro.SoftwareUpdateStatus? {
            let mac = try #require(studio.first { $0.name == name })
            return try await client.softwareUpdateStatus(managementID: mac.managementID ?? "", kind: .computer)
        }
        // 27.0.2 pending with the deadline the Blueprint gives 27.1
        let moved = try await status("Studio Mac 09")
        #expect(moved?.pendingVersion?.osVersion == "27.0.2")
        #expect(moved?.pendingVersion?.targetLocalDateTime == DemoAppleReleaseServer.macDeadline(of: "27.1", now: now))
        // the earlier step failed, with its own deadline
        let failed = try await status("Studio Mac 10")
        #expect(failed?.installState == .failed && failed?.pendingVersion?.osVersion == "27.0.2")
        #expect(failed?.pendingVersion?.targetLocalDateTime == DemoAppleReleaseServer.macDeadline(of: "27.0.2", now: now))
        // a 2018 MacBook Pro on 15.7.3, not supervised
        let older = try #require(studio.first { $0.name == "Studio Mac 11" })
        #expect(older.osVersion == "15.7.3" && older.supervised == false)
        // the iPads' enrollment
        let iPads = try await client.members(of: try #require(try await client.mobileDeviceGroups().first { $0.isSmart }))
        #expect(iPads.first { $0.name == "Field iPad 14" }?.isUserEnrollment == true)
        #expect(iPads.first { $0.name == "Field iPad 13" }?.isUserEnrollment == false)
        #expect(iPads.first { $0.name == "Field iPad 01" }?.appleEnrollmentType == "supervised")
    }

    @Test("The Blueprints’ blocks and the declaration reports")
    func blueprintsAndReports() async throws {
        let (_, client, _) = try demo()
        let update = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: DemoSoftwareUpdate.iPadBlueprintID)
        #expect(update.blocks.map(\.stepName) == ["iPadOS", "iOS"])
        #expect(update.blocks.allSatisfy { $0.targetOSVersion == DemoSoftwareUpdate.targetVersion })
        #expect(update.blocks.first?.targetLocalDateTime?.hasSuffix("T17:00:00") == true)

        let device = try #require(DemoSoftwareUpdate.iPads.first { $0.number == 111 })
        let found = try await client.device(serial: device.serial)
        #expect(found?.id == device.platformID)
        let reports = try #require(try await client.declarationReports(deviceID: device.platformID,
                                                                         filter: "declarationIdentifier==Blueprint_*"))
        // a configuration and its activation per step
        #expect(reports.count == 4)
        #expect(reports.first { $0.active == true && $0.type == "CONFIGURATION" }?.status == .pending)
        #expect(reports.allSatisfy { $0.blueprintID == DemoSoftwareUpdate.iPadBlueprintID })
    }

    @Test("Apple’s release data in demo mode, never the real hosts")
    func releases() async throws {
        let (_, _, source) = try demo()
        let client = AppleReleases.Client(recorder: RequestRecorder(session: source.session, log: nil), userAgent: "Demo",
                                          sofaURL: DemoAppleReleaseServer.sofaURL, gdmfURL: DemoAppleReleaseServer.gdmfURL)
        let catalog = try await client.catalog()
        #expect(catalog.problems.isEmpty)
        #expect(catalog.latest(.iOS)?.version == OSVersion(DemoSoftwareUpdate.targetVersion))
        #expect(catalog.supports(model: "iPad7,5", major: 27, .iOS) == false)
        #expect(catalog.lastSupportedVersion(model: "iPad7,5", .iOS) == OSVersion("17.7.10"))
        #expect(catalog.supports(model: nil, boardID: "J132AP", major: 27, .macOS) == false)
        #expect(DemoAppleReleaseServer.sofaHost.hasSuffix(DemoNetwork.reservedDomain))
        #expect(DemoAppleReleaseServer.gdmfHost.hasSuffix(DemoNetwork.reservedDomain))
        for device in DemoSoftwareUpdate.devices {
            #expect(device.osBuild != "unknown", "\(device.name) has no demo build")
        }
    }

    @Test("The Mac Blueprint enforces minor updates after a delay; release dates are relative to now")
    func macBlueprintAndDates() async throws {
        let (_, client, source) = try demo()
        let update = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: DemoSoftwareUpdate.macBlueprintID)
        #expect(update.blocks.map(\.enforcement) == [.semantic(minorEnforceAfterDays: DemoSoftwareUpdate.macDelayDays, deploymentTime: "17:00")])
        #expect(update.blueprint.softwareUpdateSettings.first?.automaticDownload == .alwaysOn)
        let catalog = try await AppleReleases.Client(recorder: RequestRecorder(session: source.session, log: nil), userAgent: "Demo",
                                                     sofaURL: DemoAppleReleaseServer.sofaURL, gdmfURL: DemoAppleReleaseServer.gdmfURL).catalog()
        let released = try #require(catalog.release(OSVersion("27.1")!, .macOS)?.releaseDate)
        let days = Date().timeIntervalSince(released) / 86_400
        #expect(days > 11 && days < 13.1)
        #expect(catalog.releases.allSatisfy { $0.releaseDate != nil })
    }

    @Test("Writes are refused")
    func readOnly() {
        let server = DemoSoftwareUpdateServer()
        let response = server.respond(to: DemoRequest(method: "POST", url: URL(string: "https://x.demo.invalid/pro/v1/computer-groups")!))
        #expect(response.status == 405)
    }

    @Test("Other apps’ demo is unchanged: without install, the paths aren’t there")
    func notInstalled() async throws {
        let defaults = UserDefaults(suiteName: "jtkit-demo-sw-\(UUID().uuidString)")!
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        let source = try #require(demo.source(for: .demoJamfPlatform))
        let client = try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                             recorder: RequestRecorder(session: source.session, log: nil), sleep: { _ in })
        let blueprints = try await JamfPlatform.Blueprints(client: client).list()
        #expect(!blueprints.contains { $0.id == DemoSoftwareUpdate.iPadBlueprintID })
        #expect(DemoWorld.devices.count == 42)
    }
}

@Suite("1.6.0: demo declarations, details and history")
@MainActor
struct DemoSoftwareUpdateDetailsTests {
    private func demo() throws -> (DemoMode, JamfPlatform.Client, DemoSource) {
        let defaults = UserDefaults(suiteName: "jtkit-demo-sw16-\(UUID().uuidString)")!
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        DemoSoftwareUpdate.install(on: demo.jamfPlatformServer)
        let source = try #require(demo.source(for: .demoJamfPlatform))
        let client = try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                             recorder: RequestRecorder(session: source.session, log: nil), sleep: { _ in })
        return (demo, client, source)
    }

    private func device(_ number: Int) throws -> DemoSoftwareUpdate.Device {
        try #require(DemoSoftwareUpdate.devices.first { $0.number == number })
    }

    @Test("Each device lists the declarations it holds; per declaration, every device that reported it")
    func perDeclaration() async throws {
        let (_, client, _) = try demo()
        let mac = try device(202)
        let status = try #require(try await client.softwareUpdateStatus(managementID: mac.managementID, kind: .computer))
        let mine = status.declarationIdentifiers.filter { $0.hasPrefix("Blueprint_\(DemoSoftwareUpdate.macBlueprintID)") }
        #expect(Set(mine) == Set(DemoSoftwareUpdate.macPairs.flatMap { [$0.configuration, $0.activation] }))
        #expect(status.declarationIdentifiers.contains("com.contoso.wifi"))

        let first = try #require(DemoSoftwareUpdate.macPairs.first)
        let reports = try #require(try await client.declarationReports(declarationIdentifier: first.configuration))
        // every Mac the Blueprint reaches (not the Loaner Macs), each once
        #expect(reports.count == DemoSoftwareUpdate.macs.count - 2)
        let syncing = try device(205).platformID, uncovered = try device(209).platformID
        #expect(reports.first { $0.deviceID == mac.platformID }?.status == .successful)
        #expect(reports.first { $0.deviceID == syncing }?.status == .awaitingSync)
        let activations = try #require(try await client.declarationReports(declarationIdentifier: first.activation))
        // a predicate false for the device: Info.Predicate with the predicate
        let other = try #require(activations.first { $0.deviceID == uncovered })
        #expect(other.reasons.first?.code == "Info.Predicate")
        #expect(other.reasons.first?.details.first?.description?.contains(#"MATCHES "^27[.]0([.][0-1])?$""#) == true)
        #expect(try await client.declarationReports(declarationIdentifier: "Blueprint_unknown_s1_c1_sys_cfg9") == nil)
    }

    @Test("The Platform device list, every device, a page at a time")
    func deviceList() async throws {
        let (_, client, _) = try demo()
        let devices = try await client.devices(pageSize: 5)
        #expect(devices.count == DemoSoftwareUpdate.devices.count)
        #expect(Set(devices.compactMap(\.serialNumber)) == Set(DemoSoftwareUpdate.devices.map(\.serial)))
        #expect(devices.first { $0.serialNumber == DemoSoftwareUpdate.devices[0].serial }?.id == DemoSoftwareUpdate.devices[0].platformID)
    }

    @Test("Like Jamf’s, the declaration’s device list answers 400 without a filter")
    func needsFilter() {
        let server = DemoSoftwareUpdateServer()
        let url = URL(string: "https://x.demo.invalid/ddm/report/v1/declarations/\(DemoSoftwareUpdate.macPairs[0].configuration)/devices")!
        #expect(server.respond(to: DemoRequest(method: "GET", url: url)).status == 400)
        let filtered = URL(string: url.absoluteString + "?filter=active%3D%3Dtrue")!
        #expect(server.respond(to: DemoRequest(method: "GET", url: filtered)).status == 200)
    }

    @Test("An invalid and a failed declaration, awaiting sync, and the iPhone step not for iPads")
    func iPadDeclarations() async throws {
        let (_, client, _) = try demo()
        let step1 = DemoSoftwareUpdate.iPadPairs[0], step2 = DemoSoftwareUpdate.iPadPairs[1]
        let reports = try #require(try await client.declarationReports(declarationIdentifier: step1.configuration))
        func report(_ number: Int) throws -> JamfPlatform.DeclarationReport? {
            let id = try device(number).platformID
            return reports.first { $0.deviceID == id }
        }
        #expect(try report(109)?.validity == .invalid)
        #expect(try report(113)?.reasons.first?.code == "Error.ConfigurationFailed")
        #expect(try report(110)?.status == .awaitingSync)
        #expect(try report(111)?.status == .pending)
        #expect(try report(107) == nil, "a device without a status report reports no declarations")
        let iPhone = try #require(try await client.declarationReports(declarationIdentifier: step2.activation))
        #expect(iPhone.allSatisfy { $0.active == false && $0.reasons.first?.code == "Info.Predicate" })
    }

    @Test("Details: unsupervised, a beta, a Rapid Security Response, battery health, FileVault and the bootstrap token")
    func details() async throws {
        let (_, client, _) = try demo()
        let groups = try await client.jamfProGroups()
        let iPads = try await client.members(of: groups[0])
        #expect(iPads.first { $0.name == "Field iPad 13" }?.supervised == false)
        let beta = try #require(try await client.softwareUpdateStatus(managementID: device(210).managementID, kind: .computer))
        #expect(beta.osVersion == "28.0" && beta.betaEnrollment == "macOS 28 Developer Beta")

        let rsr = try #require(try await client.softwareUpdateStatus(managementID: device(201).managementID, kind: .computer))
        #expect(rsr.supplementalExtraVersion == "(a)" && rsr.supplementalBuild == "26B5060a")
        #expect(rsr.batteryHealth == "normal")
        let battery = try await client.softwareUpdateStatus(managementID: device(203).managementID, kind: .computer)
        #expect(battery?.batteryHealth == "service-recommended")

        let computers = try await client.computerGroups()
        var macs = try await client.members(of: try #require(computers.first { $0.isSmart }))
        macs += try await client.members(of: try #require(computers.first { !$0.isSmart }))
        #expect(macs.first { $0.name == "Studio Mac 05" }?.diskEncryption?.bootPartitionFileVault2State == "UNENCRYPTED")
        #expect(macs.first { $0.name == "Studio Mac 01" }?.diskEncryption?.bootPartitionFileVault2State == "ENCRYPTED")
        #expect(macs.first { $0.name == "Studio Mac 02" }?.bootstrapTokenEscrowedStatus == "NOT_ESCROWED")
        #expect(macs.first { $0.name == "Studio Mac 07" }?.osVersion == "27.0.2")

        let items = try #require(try await client.statusItems(managementID: device(201).managementID, kind: .computer))
        #expect(items.contains { $0.key == "management.declarations" && $0.valueKind == .string })
        #expect(items.allSatisfy { $0.valueKind != nil })
    }

    @Test("Earlier refreshes: another rule four and five days back, a pilot group two and three days back")
    func pastRefreshes() {
        let past = DemoSoftwareUpdate.pastRefreshes()
        #expect(past.count == 10)
        let mac = past.filter { $0.blueprintID == DemoSoftwareUpdate.macBlueprintID }
        #expect(mac.map(\.daysAgo) == [5, 4, 3, 2, 1])
        #expect(mac.filter { $0.enforcement == .semantic(minorEnforceAfterDays: 14, deploymentTime: "17:00") }.map(\.daysAgo) == [5, 4])
        #expect(mac.filter { $0.extraScopeGroup != nil }.map(\.daysAgo) == [3, 2])
        #expect(mac.first { $0.extraScopeGroup != nil }?.extraScopeGroup?.kind == .computer)
        // fewer devices on target each day back
        #expect(mac.map(\.onTarget.count) == mac.map(\.onTarget.count).sorted())
        let iPad = past.filter { $0.blueprintID == DemoSoftwareUpdate.iPadBlueprintID }
        #expect(iPad.first?.enforcement.isSpecific(version: "27.0.1") == true)
        #expect(iPad.last?.enforcement.isSpecific(version: DemoSoftwareUpdate.targetVersion) == true)
    }

    @Test("Apple’s release data can be made unreachable, and back")
    func unreachable() async throws {
        let (demo, _, source) = try demo()
        let client = AppleReleases.Client(recorder: RequestRecorder(session: source.session, log: nil), userAgent: "Demo",
                                          sofaURL: DemoAppleReleaseServer.sofaURL, gdmfURL: DemoAppleReleaseServer.gdmfURL)
        demo.appleReleaseServer.isUnreachable = true
        let failed = try? await client.catalog()
        #expect(failed == nil || failed?.releases.isEmpty == true)
        demo.appleReleaseServer.isUnreachable = false
        #expect(try await client.catalog().releases.isEmpty == false)
    }
}

private extension JamfPlatform.SoftwareUpdateBlock.Enforcement {
    func isSpecific(version: String) -> Bool {
        if case .specific(let target, _, _) = self { return target == version }
        return false
    }
}
