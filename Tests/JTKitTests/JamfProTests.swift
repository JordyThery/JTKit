import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

private let proServer = URL(string: "https://school.jamfcloud.com")!
private let environmentID = "e77c1408-10c8-4007-b177-abc9157fbcaa"

/// A client for a Jamf Pro server reached directly, with a fixed token.
private func proClient(_ server: MockServer, log: ActivityLog? = nil,
                       signIn: SignInMethod = .apiClient) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: proServer, scope: .organization, server: .jamfPro, signIn: signIn,
                            tokens: FixedToken("tok"),
                            recorder: RequestRecorder(session: server.session, log: log, service: "Jamf Pro"),
                            sleep: { _ in }, random: { 0 })
}

/// The same through the Platform API gateway.
private func gatewayClient(_ server: MockServer) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!, scope: .environment(environmentID),
                            tokens: FixedToken("tok"), recorder: RequestRecorder(session: server.session, log: nil),
                            sleep: { _ in }, random: { 0 })
}

private func queryValues(_ request: RecordedRequest, _ name: String) -> [String] {
    URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
        .filter { $0.name == name }.compactMap(\.value) ?? []
}

private func thrown<E: Error>(_ type: E.Type, _ body: @Sendable () async throws -> Void) async -> E? {
    do {
        try await body()
        return nil
    } catch let error as E {
        return error
    } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
    }
}

/// Computers as `v4/computers-inventory` answers them (trimmed from Jamf Pro 11.33).
private func computersPage(_ records: [String], total: Int? = nil) -> String {
    #"{"totalCount":\#(total ?? records.count),"results":[\#(records.joined(separator: ","))]}"#
}

private func computerJSON(id: String = "12", serial: String = "C02XK1JHJG5H") -> String {
    #"""
    {"id":"\#(id)","udid":"55900BDC-347C-58B1-D249-F32244B11D30",
     "general":{"name":"Lab Mac 4","assetTag":"A-1001","lastCheckIn":"2026-10-20T08:12:33.123Z","lastContact":null,
       "reportDate":"2026-10-19T07:00:00.12Z","lastEnrolledDate":"2025-02-01T10:00:00Z",
       "mdmProfileExpiration":"2027-02-01T10:00:00Z","managementId":"aa-bb","remoteManagement":{"managed":true},
       "supervised":true,"enrolledViaAutomatedDeviceEnrollment":true,
       "enrollmentMethod":{"id":"3","objectName":"Staff Macs","objectType":"Computer PreStage"},
       "site":{"id":"-1","name":"None"},"extensionAttributes":[{"definitionId":"1","values":["secret-ea"]}]},
     "hardware":{"serialNumber":"\#(serial)","model":"MacBook Air (M2, 2022)","modelIdentifier":"Mac14,2"},
     "operatingSystem":{"name":"macOS","version":"26.1","build":"25B78"},
     "diskEncryption":{"fileVault2Enabled":true,"individualRecoveryKeyValidityStatus":"VALID",
       "bootPartitionEncryptionDetails":{"partitionFileVault2State":"ENCRYPTED","partitionFileVault2Percent":100}},
     "userAndLocation":{"username":"jane","realname":"Jane Doe","email":"jane@school.example","departmentId":"-1","buildingId":"4","room":"B12"},
     "localUserAccounts":[{"username":"admin"}]}
    """#
}

private func mobileJSON(id: String = "77", serial: String = "F9FXK2Q3HGMN", udid: String = "00008030-001A2B3C4D5E802E") -> String {
    #"""
    {"mobileDeviceId":"\#(id)","deviceType":"iOS",
     "general":{"displayName":"Cart iPad 3","udid":"\#(udid)","assetTag":"T-3","osVersion":"26.0.1","osBuild":"23A355",
       "managed":true,"supervised":"true","managementId":"cc-dd","lastInventoryUpdateDate":"2026-10-20T08:12:33.123Z",
       "lastEnrolledDate":"2025-03-01T09:00:00.99Z","siteId":"2",
       "enrollmentMethodPrestage":{"mobileDevicePrestageId":"5","profileName":"Carts"}},
     "hardware":{"serialNumber":"\#(serial)","model":"iPad (10th generation)","modelIdentifier":"iPad13,18"},
     "security":{"passcodePresent":true,"passcodeCompliant":1,"hardwareEncryption":3},
     "userAndLocation":{"username":"cart3","realName":"Cart Three","emailAddress":"cart3@school.example","departmentId":"-1"}}
    """#
}

// MARK: - Lookups

@Suite("Jamf Pro lookups")
@MainActor
struct JamfProLookupTests {
    @Test("Serials and UDIDs: letters, digits and hyphens only, refused before sending")
    func identifiers() throws {
        #expect(try JamfPro.validatedIdentifier(" C02XK1JHJG5H ") == "C02XK1JHJG5H")
        #expect(try JamfPro.validatedIdentifier("00008030-001A2B3C4D5E802E") == "00008030-001A2B3C4D5E802E")
        for bad in ["", "C02\"||id==1", "C02 X", "C02,X", "Ç02", String(repeating: "A", count: 65)] {
            #expect(throws: JamfPlatform.APIError.self) { try JamfPro.validatedIdentifier(bad) }
        }
    }

    @Test("A computer by serial: v4 inventory, the sections, a quoted filter, read with v4's field names")
    func computerBySerial() async throws {
        let server = MockServer { _ in .json(200, computersPage([computerJSON()])) }
        let match = try await proClient(server).computer(serial: "C02XK1JHJG5H")
        let sent = try #require(server.requests.first)
        #expect(sent.path == "/api/v4/computers-inventory")
        #expect(queryValues(sent, "section") == ["GENERAL", "HARDWARE", "OPERATING_SYSTEM", "USER_AND_LOCATION"])
        #expect(sent.queryValue("filter") == #"hardware.serialNumber=="C02XK1JHJG5H""#)
        #expect(sent.queryValue("page") == "0")

        let computer = try #require(match.record)
        #expect(computer.id == "12")
        #expect(computer.general?.name == "Lab Mac 4")
        #expect(computer.general?.assetTag == "A-1001")
        #expect(computer.general?.managed == true)
        #expect(computer.general?.lastCheckIn == JamfPlatform.date(from: "2026-10-20T08:12:33.123Z"))
        #expect(computer.general?.reportDate != nil, "two decimals are read too")
        #expect(computer.general?.enrollmentMethod?.objectName == "Staff Macs")
        #expect(computer.general?.site?.name == "None")
        #expect(computer.hardware?.model == "MacBook Air (M2, 2022)")
        #expect(computer.operatingSystem?.version == "26.1")
        #expect(computer.diskEncryption?.bootPartitionFileVault2Percent == 100)
        #expect(computer.userAndLocation?.realName == "Jane Doe")
        #expect(computer.userAndLocation?.email == "jane@school.example")
        #expect(computer.userAndLocation?.departmentID == nil, "-1 is none")
        #expect(computer.userAndLocation?.buildingID == "4")
    }

    @Test("v1's lastContactTime is still read as the last check-in")
    func olderCheckInName() throws {
        let json = #"{"id":"1","general":{"lastContactTime":"2026-10-20T08:12:33Z"}}"#
        let computer = try JSONDecoder().decode(JamfPro.Computer.self, from: Data(json.utf8))
        #expect(computer.general?.lastCheckIn == JamfPlatform.date(from: "2026-10-20T08:12:33Z"))
    }

    @Test("Through the Platform API gateway: the pro/ path and the Environment ID")
    func throughGateway() async throws {
        let server = MockServer { _ in .json(200, computersPage([computerJSON()])) }
        _ = try await gatewayClient(server).computer(serial: "C02XK1JHJG5H")
        let sent = try #require(server.requests.first)
        #expect(sent.path == "/pro/v4/computers-inventory")
        #expect(sent.header("X-Environment-Id") == environmentID)
    }

    @Test("Only an exact serial counts; two records for one serial are ambiguous")
    func exactMatch() async throws {
        let other = MockServer { _ in .json(200, computersPage([computerJSON(serial: "C02XK1JHJG5X")])) }
        #expect(try await proClient(other).computer(serial: "C02XK1JHJG5H") == .none)

        let lower = MockServer { _ in .json(200, computersPage([computerJSON()])) }
        #expect(try await proClient(lower).computer(serial: "c02xk1jhjg5h").record != nil, "case aside")

        let two = MockServer { _ in .json(200, computersPage([computerJSON(id: "1"), computerJSON(id: "2")])) }
        #expect(try await proClient(two).computer(serial: "C02XK1JHJG5H") == .several(2))

        let none = MockServer { _ in .json(200, computersPage([])) }
        #expect(try await proClient(none).computer(serial: "C02XK1JHJG5H") == .none)
    }

    @Test("A computer by UDID")
    func computerByUDID() async throws {
        let server = MockServer { _ in .json(200, computersPage([computerJSON()])) }
        let match = try await proClient(server).computer(udid: "55900BDC-347C-58B1-D249-F32244B11D30")
        #expect(server.requests.first?.queryValue("filter") == #"udid=="55900BDC-347C-58B1-D249-F32244B11D30""#)
        #expect(match.record?.id == "12")
    }

    @Test("A mobile device by serial and by UDID: v2 detail, read leniently")
    func mobileDevice() async throws {
        let page = #"{"totalCount":1,"results":[\#(mobileJSON())]}"#
        let server = MockServer { _ in .json(200, page) }
        let client = try proClient(server)
        let bySerial = try #require(try await client.mobileDevice(serial: "F9FXK2Q3HGMN").record)
        let byUDID = try #require(try await client.mobileDevice(udid: "00008030-001A2B3C4D5E802E").record)
        #expect(server.requests.map(\.path) == ["/api/v2/mobile-devices/detail", "/api/v2/mobile-devices/detail"])
        #expect(queryValues(server.requests[0], "section") == ["GENERAL", "HARDWARE", "USER_AND_LOCATION"])
        #expect(server.requests[0].queryValue("filter") == #"serialNumber=="F9FXK2Q3HGMN""#)
        #expect(server.requests[1].queryValue("filter") == #"udid=="00008030-001A2B3C4D5E802E""#)
        #expect(bySerial == byUDID)
        #expect(bySerial.id == "77")
        #expect(bySerial.udid == "00008030-001A2B3C4D5E802E")
        #expect(bySerial.general?.supervised == true, "\"true\" as text")
        #expect(bySerial.general?.siteID == "2")
        #expect(bySerial.general?.enrollmentPreStageName == "Carts")
        #expect(bySerial.security?.passcodeCompliant == true, "1 as a flag")
        #expect(bySerial.security?.hardwareEncryption == 3)
        #expect(bySerial.userAndLocation?.realName == "Cart Three")
        #expect(bySerial.userAndLocation?.email == "cart3@school.example")
    }

    /// A record that never enrolled: Jamf’s list has no general section for
    /// it (device type "Unknown"), so the lookup reads the record by ID once
    /// more for its name (seen on Jamf Pro 11.33). It reads
    /// `v2/mobile-devices/{id}`, never `…/detail`, which carries the unlock
    /// token. That answer has no asset tag on a real Jamf Pro, so the asset
    /// tag comes from Classic’s General subset.
    nonisolated private static let unenrolledListed = #"{"totalCount":1,"results":[{"mobileDeviceId":"9","deviceType":"Unknown","hardware":{"serialNumber":"JTKTEST0001"}}]}"#
    nonisolated private static let unenrolledSingle = #"{"id":"9","name":"Test iPad","udid":"00000000-0000000000000001","managed":false,"osVersion":"","site":{"id":"-1","name":"None"},"ios":{"supervised":false}}"#
    nonisolated private static func classicGeneral(assetTag: String) -> String {
        #"{"mobile_device":{"general":{"id":9,"display_name":"Test iPad","name":"Test iPad","asset_tag":"\#(assetTag)","serial_number":"JTKTEST0001","udid":"00000000-0000000000000001"}}}"#
    }

    /// Answers the list, the single record and the General subset; a test
    /// can replace one of them.
    private static func unenrolledServer(listed: String = unenrolledListed, single: MockResponse? = nil,
                                         general: MockResponse? = nil) -> MockServer {
        MockServer { request in
            if request.path.hasSuffix("/mobiledevices/id/9/subset/General") { return general ?? .json(200, classicGeneral(assetTag: "TAG-1")) }
            if request.path.hasSuffix("/mobile-devices/9") { return single ?? .json(200, unenrolledSingle) }
            return .json(200, listed)
        }
    }

    @Test("A mobile device that never enrolled gets its name from its own record and its asset tag from Classic’s General subset")
    func unenrolledMobileDevice() async throws {
        let server = Self.unenrolledServer()
        let record = try #require(try await proClient(server).mobileDevice(serial: "JTKTEST0001").record)
        #expect(server.requests.map(\.path) == ["/api/v2/mobile-devices/detail", "/api/v2/mobile-devices/9",
                                                "/JSSResource/mobiledevices/id/9/subset/General"])
        #expect(server.requests[2].header("Accept") == "application/json")
        #expect(record.general?.displayName == "Test iPad")
        #expect(record.general?.assetTag == "TAG-1")
        #expect(record.general?.managed == false)
        #expect(record.general?.siteID == nil, "-1 is none")
        #expect(record.udid == "00000000-0000000000000001")
        #expect(record.serialNumber == "JTKTEST0001")

        // An enrolled record already has its general section: no second read.
        let enrolled = MockServer { _ in .json(200, #"{"totalCount":1,"results":[\#(mobileJSON())]}"#) }
        _ = try await proClient(enrolled).mobileDevice(serial: "F9FXK2Q3HGMN")
        #expect(enrolled.requests.count == 1)
    }

    @Test("A never-enrolled device whose own record has an asset tag isn’t read in Classic")
    func unenrolledWithAssetTag() async throws {
        let single = #"{"id":"9","name":"Test iPad","assetTag":"TAG-2"}"#
        let server = Self.unenrolledServer(single: .json(200, single))
        let record = try #require(try await proClient(server).mobileDevice(serial: "JTKTEST0001").record)
        #expect(record.general?.assetTag == "TAG-2")
        #expect(server.requests.map(\.path) == ["/api/v2/mobile-devices/detail", "/api/v2/mobile-devices/9"])
    }

    @Test("A Classic General subset that fails or has an empty asset tag leaves the record found, with its name, without an asset tag",
          arguments: [MockResponse.json(403, "{}"), .json(500, "{}"), .json(200, "not json"),
                      .json(200, #"{"mobile_device":{"general":{"asset_tag":""}}}"#)])
    func unenrolledWithoutClassic(general: MockResponse) async throws {
        let single = try #require(try await proClient(Self.unenrolledServer(general: general)).mobileDevice(serial: "JTKTEST0001").record)
        #expect(single.general?.displayName == "Test iPad")
        #expect(single.general?.assetTag == nil)

        let batch = try await proClient(Self.unenrolledServer(general: general)).mobileDevices(serials: ["JTKTEST0001"])
        #expect(batch.records["JTKTEST0001"]?.general?.displayName == "Test iPad")
        #expect(batch.records["JTKTEST0001"]?.general?.assetTag == nil)
        #expect(batch.failures.isEmpty)
    }

    /// Both lookups, directly and through the gateway: exactly the list, the
    /// record without the unlock token and Classic’s General subset; never
    /// `…/detail` for one device, the whole Classic record or its Security subset.
    @Test("A never-enrolled lookup reads exactly these paths, and the asset tag comes back")
    func unenrolledRequestPaths() async throws {
        let direct = ["/api/v2/mobile-devices/detail", "/api/v2/mobile-devices/9", "/JSSResource/mobiledevices/id/9/subset/General"]
        let gateway = ["/pro/v2/mobile-devices/detail", "/pro/v2/mobile-devices/9", "/proclassic/mobiledevices/id/9/subset/General"]
        for (makeClient, paths) in [({ try proClient($0) } as (MockServer) throws -> JamfPlatform.Client, direct), ({ try gatewayClient($0) }, gateway)] {
            let single = Self.unenrolledServer()
            let match = try await makeClient(single).mobileDevice(serial: "JTKTEST0001")
            #expect(match.record?.general?.assetTag == "TAG-1")
            #expect(single.requests.map(\.path) == paths)

            let many = Self.unenrolledServer()
            let batch = try await makeClient(many).mobileDevices(serials: ["JTKTEST0001"])
            #expect(batch.records["JTKTEST0001"]?.general?.assetTag == "TAG-1")
            #expect(many.requests.map(\.path) == paths)

            for path in single.requests.map(\.path) + many.requests.map(\.path) {
                #expect(!path.hasSuffix("/9/detail"), "never the record with the unlock token")
                #expect(!path.lowercased().contains("security"), "never the Security subset")
                #expect(!path.hasSuffix("/mobiledevices/id/9"), "never the whole Classic record")
            }
        }
    }

    /// The same for the lookup of many serials at once.
    @Test("Many serials at once: a mobile device that never enrolled gets its name and asset tag; an enrolled one isn’t read again")
    func unenrolledMobileDevicesInABatch() async throws {
        let listed = #"{"totalCount":2,"results":[{"mobileDeviceId":"9","deviceType":"Unknown","hardware":{"serialNumber":"JTKTEST0001"}},\#(mobileJSON())]}"#
        let server = Self.unenrolledServer(listed: listed)
        let batch = try await proClient(server).mobileDevices(serials: ["JTKTEST0001", "F9FXK2Q3HGMN"])
        #expect(batch.records["JTKTEST0001"]?.general?.displayName == "Test iPad")
        #expect(batch.records["JTKTEST0001"]?.general?.assetTag == "TAG-1")
        #expect(batch.records["F9FXK2Q3HGMN"]?.general?.assetTag == "T-3")
        #expect(server.requests.map(\.path) == ["/api/v2/mobile-devices/detail", "/api/v2/mobile-devices/9",
                                                "/JSSResource/mobiledevices/id/9/subset/General"])

        // A record that can’t be read leaves it found, without a name, and
        // Classic isn’t asked.
        let failing = Self.unenrolledServer(listed: listed, single: .json(500, "{}"))
        let partial = try await proClient(failing).mobileDevices(serials: ["JTKTEST0001"])
        #expect(partial.records["JTKTEST0001"] != nil)
        #expect(partial.records["JTKTEST0001"]?.general == nil)
        #expect(partial.failures.isEmpty)
        #expect(!failing.requests.contains { $0.path.contains("JSSResource") })

        // Without the general section asked for, nothing more is read.
        let lean = MockServer { _ in .json(200, listed) }
        _ = try await proClient(lean).mobileDevices(serials: ["JTKTEST0001"], sections: [.hardware])
        #expect(lean.requests.count == 1)
    }

    @Test("Odd values never lose a record; an unreadable result is skipped, not fatal")
    func tolerant() async throws {
        let odd = #"{"id":12,"udid":null,"general":{"managed":"yes","remoteManagement":"oops","name":7},"hardware":{"serialNumber":"C02XK1JHJG5H"},"newSection":{"x":1}}"#
        let server = MockServer { _ in .json(200, computersPage([odd, "42"], total: 2)) }
        let computer = try #require(try await proClient(server).computer(serial: "C02XK1JHJG5H").record)
        #expect(computer.id == "12")
        #expect(computer.general?.name == "7")
        #expect(computer.general?.managed == nil)
        #expect(computer.operatingSystem == nil, "a section not in the answer")
    }

    @Test("Pages are read until totalCount; a list that never ends is an error")
    func paging() async throws {
        let server = MockServer { request in
            let page = Int(request.queryValue("page") ?? "") ?? 0
            let records = (0..<(page == 0 ? 100 : 50)).map { computerJSON(id: "\(page * 100 + $0)") }
            return .json(200, computersPage(records, total: 150))
        }
        #expect(try await proClient(server).computer(serial: "C02XK1JHJG5H") == .several(150))
        #expect(server.requests.count == 2)

        let fullPage = (0..<100).map { computerJSON(id: "\($0)") }.joined(separator: ",")
        let endless = MockServer { _ in .json(200, #"{"results":[\#(fullPage)]}"#) }
        let error = await thrown(JamfPlatform.APIError.self) { _ = try await proClient(endless).computers(serials: ["C02XK1JHJG5H"]).records }
        #expect(error == nil, "a batch reports it per serial")
        let batch = try await proClient(endless).computers(serials: ["C02XK1JHJG5H"])
        guard case .pageLimitReached? = batch.failures["C02XK1JHJG5H"]?.kind else {
            Issue.record("Expected the page limit, got \(String(describing: batch.failures))")
            return
        }
    }
}

// MARK: - Batches

@Suite("Jamf Pro batch lookups")
@MainActor
struct JamfProBatchTests {
    @Test("50 serials per request, quoted in a list filter; duplicates and blanks skipped; bad serials not sent")
    func batches() async throws {
        let serials = (0..<120).map { String(format: "C02SERIAL%03d", $0) }
        let server = MockServer { request in
            let filter = request.queryValue("filter") ?? ""
            let found = serials.filter { filter.contains("\"\($0)\"") }.prefix(1).map { computerJSON(id: $0, serial: $0) }
            return .json(200, computersPage(found))
        }
        let batch = try await proClient(server).computers(serials: serials + ["c02serial000", "", "BAD\"SERIAL"])
        let filters = server.requests.compactMap { $0.queryValue("filter") }
        #expect(filters.count == 3)
        #expect(filters.allSatisfy { $0.hasPrefix("hardware.serialNumber=in=(\"") })
        #expect(filters.map { $0.components(separatedBy: ",").count }.sorted() == [20, 50, 50])
        #expect(batch.records.count == 3, "the first serial of each group answered")
        #expect(batch.records["C02SERIAL000"]?.id == "C02SERIAL000")
        #expect(batch.failures.keys.sorted() == ["BAD\"SERIAL"])
        #expect(!filters.joined().contains("BAD"))
    }

    @Test("A refused list filter (HTTP 400) falls back to one serial at a time")
    func refusedFilter() async throws {
        let server = MockServer { request in
            let filter = request.queryValue("filter") ?? ""
            if filter.contains("=in=") {
                return .json(400, #"{"httpStatus":400,"errors":[{"code":"INVALID_FIELD","field":"filter","description":"bad"}]}"#)
            }
            return filter.contains("C02A") ? .json(200, computersPage([computerJSON(serial: "C02A")])) : .json(200, computersPage([]))
        }
        let batch = try await proClient(server).computers(serials: ["C02A", "C02B"])
        #expect(server.requests.count == 3)
        #expect(server.requests.dropFirst().compactMap { $0.queryValue("filter") } == [#"hardware.serialNumber=="C02A""#, #"hardware.serialNumber=="C02B""#])
        #expect(batch.records.keys.sorted() == ["C02A"])
        #expect(batch.failures.isEmpty)
    }

    @Test("A 400 that a one-serial lookup gets too fails the whole group after one probe, not one request per serial")
    func refusedNotForTheFilter() async throws {
        let server = MockServer { _ in .json(400, #"{"httpStatus":400,"errors":[{"code":"INVALID_FIELD","field":"section","description":"bad"}]}"#) }
        let serials = (0..<50).map { String(format: "C02S%03d", $0) }
        let batch = try await proClient(server).computers(serials: serials)
        #expect(server.requests.count == 2, "the list, then one probe")
        #expect(server.requests.last?.queryValue("filter") == #"hardware.serialNumber=="C02S000""#)
        #expect(batch.records.isEmpty)
        #expect(batch.failures.count == 50)
        #expect(batch.failures.values.allSatisfy { $0.status == 400 })
    }

    @Test("Another error fails the whole group, with the privilege named")
    func otherError() async throws {
        let server = MockServer { _ in .json(403, #"{"httpStatus":403,"errors":[]}"#) }
        let batch = try await proClient(server).mobileDevices(serials: ["F9A", "F9B"])
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.queryValue("filter") == #"serialNumber=in=("F9A","F9B")"#)
        #expect(batch.failures.keys.sorted() == ["F9A", "F9B"])
        #expect(batch.failures["F9A"]?.message().contains("“Read Mobile Devices”") == true)
    }
}

// MARK: - Writes, version, recording

@Suite("Jamf Pro asset tags and version")
@MainActor
struct JamfProWriteTests {
    @Test("A computer’s asset tag: PATCH v4 detail, the general section, repeated after a server error")
    func computerAssetTag() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() == 1 ? .json(503, "{}") : .json(200, "{}") }
        try await proClient(server).setAssetTag("A-2002", computerID: "12")
        #expect(server.requests.count == 2, "safe to repeat")
        let sent = try #require(server.requests.last)
        #expect(sent.method == "PATCH")
        #expect(sent.path == "/api/v4/computers-inventory-detail/12")
        let body = try JSONSerialization.jsonObject(with: sent.body) as? [String: [String: String]]
        #expect(body == ["general": ["assetTag": "A-2002"]])
    }

    @Test("A mobile device’s asset tag: PATCH v2; an empty tag clears it")
    func mobileAssetTag() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        try await proClient(server).setAssetTag("", mobileDeviceID: "77")
        let sent = try #require(server.requests.last)
        #expect(sent.path == "/api/v2/mobile-devices/77")
        #expect(sent.bodyString == #"{"assetTag":""}"#)
    }

    @Test("An ID can’t reach another path: it is refused before sending")
    func pathSegment() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let error = await thrown(JamfPlatform.APIError.self) {
            try await proClient(server).setAssetTag("x", computerID: "12/../../v1/users")
        }
        #expect(server.requests.isEmpty)
        guard case .refused? = error?.kind else {
            Issue.record("Expected a refusal, got \(String(describing: error))")
            return
        }
    }

    @Test("The Jamf Pro version")
    func version() async throws {
        let server = MockServer { _ in .json(200, #"{"version":"11.33.1-t1792501724838"}"#) }
        #expect(try await proClient(server).jamfProVersion().version == "11.33.1-t1792501724838")
        #expect(server.requests.first?.path == "/api/v1/jamf-pro-version")
    }

    @Test("A lookup’s answer isn’t recorded by default; with .results, only the sections asked for, user and location hidden")
    func recording() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in .json(200, computersPage([computerJSON()])) }
        let client = try proClient(server, log: log)
        _ = try await client.computer(serial: "C02XK1JHJG5H")
        #expect(log.entries.last?.request?.responseBody == nil)

        _ = try await client.computer(serial: "C02XK1JHJG5H", sections: [.general, .userAndLocation], recording: .results)
        let recorded = try #require(log.entries.last?.request?.responseBody)
        #expect(recorded.contains("Lab Mac 4"))
        #expect(!recorded.contains("MacBook Air"), "a section not asked for")
        #expect(!recorded.contains("admin"), "local accounts never")
        #expect(!recorded.contains("Jane Doe"))
        #expect(!recorded.contains("secret-ea"), "extension attributes hidden")
    }
}

// MARK: - Hints

@Suite("Jamf Pro hints")
@MainActor
struct JamfProHintTests {
    @Test("A refused request names the privilege: the API role for an API client")
    func privilegeAPIClient() async throws {
        let server = MockServer { _ in .json(403, "{}") }
        let error = await thrown(JamfPlatform.APIError.self) { _ = try await proClient(server).computer(serial: "C02A") }
        #expect(error?.message().contains("The API role is missing the “Read Computers” privilege. Add it in Jamf Pro under Settings › API Roles and Clients.") == true)
    }

    @Test("… and the user account’s privileges for username and password")
    func privilegeUser() async throws {
        let server = MockServer { _ in .json(403, "{}") }
        let error = await thrown(JamfPlatform.APIError.self) {
            try await proClient(server, signIn: .usernamePassword).setAssetTag("x", mobileDeviceID: "1")
        }
        #expect(error?.message().contains("The user account is missing the “Update Mobile Devices” privilege. Add it in Jamf Pro under Settings › User Accounts and Groups.") == true)
    }

    @Test("A paged list that needs several privileges names them all when refused")
    func pagedListPrivileges() async throws {
        let server = MockServer { _ in .json(403, "{}") }
        let error = await thrown(JamfPlatform.APIError.self) {
            _ = try await proClient(server).allPages("pro/v1/things", privileges: [.readSmartUserGroups, .readStaticUserGroups]) { $0 }
        }
        #expect(error?.message().contains("The API role is missing one of these privileges: “Read Smart User Groups”, “Read Static User Groups”.") == true)
    }

    @Test("Without a known privilege, the general wording")
    func unknownPrivilege() async throws {
        let server = MockServer { _ in .json(403, "{}") }
        let error = await thrown(JamfPlatform.APIError.self) { _ = try await proClient(server).json("pro/v1/something") }
        #expect(error?.message().contains("The API role is missing a privilege for this request.") == true)
    }

    @Test("A wrong password on a direct server: no region, no client secret")
    func signInUser() async throws {
        let server = MockServer { _ in .json(401, #"{"httpStatus":401,"errors":[]}"#) }
        let connection = Connection(name: "Lab", service: .jamfPro, signIn: .usernamePassword,
                                    serverURL: proServer.absoluteString, username: "jssadmin")
        let client = try JamfPlatform.Client(connection: connection, secret: { "wrong" },
                                             recorder: RequestRecorder(session: server.session, log: nil))
        let error = await thrown(JamfPlatform.APIError.self) { try await client.signIn() }
        let message = try #require(error?.message())
        #expect(server.requests.first?.path == "/api/v1/auth/token")
        #expect(message.contains("Check the username and password."))
        #expect(!message.contains("region"))
        #expect(!message.contains("client secret"))
    }

    @Test("A wrong API client on a direct server: no region, the client enabled in Jamf Pro")
    func signInAPIClient() async throws {
        let server = MockServer { _ in .json(401, #"{"error":"invalid_client"}"#) }
        let connection = Connection(name: "Lab", service: .jamfPro, signIn: .apiClient,
                                    serverURL: proServer.absoluteString, clientID: "abc")
        let client = try JamfPlatform.Client(connection: connection, secret: { "wrong" },
                                             recorder: RequestRecorder(session: server.session, log: nil))
        let error = await thrown(JamfPlatform.APIError.self) { try await client.signIn() }
        let message = try #require(error?.message())
        #expect(message.contains("Check the client ID and client secret, and that the API client is enabled in Jamf Pro under Settings › API Roles and Clients."))
        #expect(!message.contains("region"))
    }

    @Test("The Platform API keeps its wording")
    func platformUnchanged() async throws {
        let server = MockServer { _ in .json(403, #"{"httpStatus":403,"errors":[{"code":"BAD_PERMISSIONS"}]}"#) }
        let error = await thrown(JamfPlatform.APIError.self) { _ = try await gatewayClient(server).computer(serial: "C02A") }
        let message = try #require(error?.message())
        #expect(message.contains("Check its permissions in Jamf Account."))
        #expect(!message.contains("API Roles and Clients"))
    }

    @Test("A bad serial is refused with its own message, before anything is sent")
    func invalidIdentifier() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let error = await thrown(JamfPlatform.APIError.self) { _ = try await proClient(server).mobileDevice(udid: "x\" or 1==1") }
        #expect(server.requests.isEmpty)
        #expect(error?.message().contains("isn’t a serial number or UDID") == true)
    }
}

// MARK: - Jamf School

private func schoolClient(_ server: MockServer, log: ActivityLog? = nil, sleeps: SleepLog = SleepLog()) throws -> JamfSchool.Client {
    try JamfSchool.Client(address: "school.jamfcloud.com/api/", networkID: " 999001 ", apiKey: "KEY123 ",
                          recorder: RequestRecorder(session: server.session, log: log, service: "Jamf School"),
                          sleep: { try await sleeps.sleep($0) }, random: { 0 })
}

/// A device as the list answers it (flags as booleans, check-in as text).
private let schoolListDevice = #"""
{"UDID":"00008030-001A2B3C4D5E802E","serialNumber":"F9FXK2Q3HGMN","name":"Cart iPad 3","assetTag":"",
 "model":{"name":"iPad (10th generation)","identifier":"iPad13,18","type":{"id":1}},"os":{"prefix":"iOS","version":"26.0.1"},
 "owner":{},"isManaged":true,"isSupervised":false,"inTrash":false,"locationId":0,"groups":["Carts"],
 "lastCheckin":"2026-10-20 08:12:33","class":"ipad","notes":"private note"}
"""#

/// The same device from `devices/{udid}` (flags as 0/1, check-in with the time zone).
private let schoolDetailDevice = #"""
{"code":200,"device":{"UDID":"00008030-001A2B3C4D5E802E","serialNumber":"F9FXK2Q3HGMN","name":"Cart iPad 3","assetTag":"T-3",
 "model":{"name":"iPad (10th generation)","identifier":"iPad13,18"},"os":{"prefix":"iOS","version":"26.0.1"},
 "owner":{"name":"Jane Doe","username":"jane","email":"jane@school.example"},"isManaged":1,"isSupervised":0,
 "hasPasscode":true,"passcodeCompliant":1,"lastCheckin":{"date":"2026-10-20 08:12:33.000000","timezone_type":3,"timezone":"Asia/Tokyo"}}}
"""#

@Suite("Jamf School client")
@MainActor
struct JamfSchoolTests {
    @Test("The address is cleaned up; a missing Network ID or API key is refused")
    func address() throws {
        #expect(JamfSchool.baseURL("school.jamfcloud.com/api/")?.absoluteString == "https://school.jamfcloud.com")
        #expect(JamfSchool.baseURL("https://school.jamfcloud.com//")?.absoluteString == "https://school.jamfcloud.com")
        #expect(JamfSchool.baseURL("http://school.jamfcloud.com") == nil)
        #expect(JamfSchool.baseURL("  ") == nil)
        let server = MockServer { _ in .json(200, "{}") }
        #expect(throws: JamfSchool.APIError.self) {
            try JamfSchool.Client(address: "school.jamfcloud.com", networkID: "", apiKey: "k",
                                  recorder: RequestRecorder(session: server.session, log: nil))
        }
    }

    @Test("A device by serial: Basic Network ID and API key, hidden in the log; lenient fields")
    func bySerial() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in .json(200, #"{"code":200,"count":1,"devices":[\#(schoolListDevice)]}"#) }
        let device = try #require(try await schoolClient(server, log: log).device(serial: "f9fxk2q3hgmn").record)
        let sent = try #require(server.requests.first)
        #expect(sent.url.absoluteString == "https://school.jamfcloud.com/api/devices?serialnumber=f9fxk2q3hgmn")
        #expect(sent.header("Authorization") == "Basic " + Data("999001:KEY123".utf8).base64EncodedString())
        let recorded = try #require(log.entries.last?.request?.requestHeaders.first { $0.name == "Authorization" })
        #expect(recorded.value == "Basic <redacted>")
        #expect(device.udid == "00008030-001A2B3C4D5E802E")
        #expect(device.assetTag == nil, "an empty string is none")
        #expect(device.ownerName == nil)
        #expect(device.isSupervised == false)
        #expect(device.modelIdentifier == "iPad13,18")
        #expect(device.groups == ["Carts"])
        #expect(device.lastCheckIn != nil)
    }

    @Test("Details: 0/1 flags, the check-in read in the instance’s time zone")
    func details() async throws {
        let server = MockServer { _ in .json(200, schoolDetailDevice) }
        let device = try #require(try await schoolClient(server).device(udid: "00008030-001A2B3C4D5E802E"))
        #expect(server.requests.first?.path == "/api/devices/00008030-001A2B3C4D5E802E")
        #expect(device.isManaged == true)
        #expect(device.passcodeCompliant == true)
        #expect(device.ownerEmail == "jane@school.example")
        #expect(device.timeZone == "Asia/Tokyo")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(calendar.component(.hour, from: try #require(device.lastCheckIn)) == 23, "08:12 in Tokyo is 23:12 UTC")
    }

    @Test("DeviceNotFound means no match; any other 404 means a wrong address")
    func notFound() async throws {
        let missing = MockServer { _ in .json(404, #"{"code":404,"message":"DeviceNotFound"}"#) }
        #expect(try await schoolClient(missing).device(udid: "00008030-0000") == nil)
        let wrong = MockServer { _ in .json(404, #"{"error":{"message":"Not found","code":404}}"#) }
        let error = await thrown(JamfSchool.APIError.self) { _ = try await schoolClient(wrong).device(udid: "00008030-0000") }
        #expect(error?.status == 404)
        #expect(error?.message().contains("Check the Jamf School server URL, e.g. https://yourschool.jamfcloud.com.") == true)
    }

    @Test("DeviceNotFound on a serial lookup is no match, with a 404 or under HTTP 200; another 404 is still an error")
    func serialNotFound() async throws {
        for answer in [MockResponse.json(404, #"{"code":404,"message":"DeviceNotFound"}"#), .json(200, #"{"message":"DeviceNotFound"}"#)] {
            let server = MockServer { _ in answer }
            #expect(try await schoolClient(server).device(serial: "F9FXK2Q3HGMN") == .none)
        }
        let wrong = MockServer { _ in .json(404, #"{"error":{"message":"Not found","code":404}}"#) }
        let error = await thrown(JamfSchool.APIError.self) { _ = try await schoolClient(wrong).device(serial: "F9FXK2Q3HGMN") }
        #expect(error?.status == 404)
    }

    @Test("A failure under HTTP 200 is a failure, with the API key hint")
    func failureUnder200() async throws {
        let server = MockServer { _ in .json(200, #"{"code":403,"message":"Forbidden"}"#) }
        let error = await thrown(JamfSchool.APIError.self) { _ = try await schoolClient(server).groups() }
        #expect(error?.status == 403)
        let message = try #require(error?.message())
        #expect(message.contains("HTTP 403"))
        #expect(message.contains("Organization › Settings › API"))
    }

    @Test("A known failure message counts without a code")
    func failureMessage() async throws {
        let server = MockServer { _ in .json(200, #"{"message":"DeviceNotActive"}"#) }
        let error = await thrown(JamfSchool.APIError.self) { try await schoolClient(server).setAssetTag("x", udid: "ABC") }
        #expect(error?.message().contains("trashed or inactive") == true)
    }

    @Test("An answer that isn’t a device list is never read as no devices")
    func notJamfSchool() async throws {
        let server = MockServer { _ in .json(200, "<html>Sign in</html>", headers: ["Content-Type": "text/html"]) }
        let error = await thrown(JamfSchool.APIError.self) { _ = try await schoolClient(server).device(serial: "F9A") }
        guard case .invalidResponse? = error?.kind else {
            Issue.record("Expected an unreadable answer, got \(String(describing: error))")
            return
        }
        #expect(error?.message().contains("Check the Jamf School server URL, e.g. https://yourschool.jamfcloud.com.") == true)
    }

    @Test("A 429 is waited out and retried")
    func tooManyRequests() async throws {
        let calls = Counter()
        let sleeps = SleepLog()
        let server = MockServer { _ in
            calls.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "3"]) : .json(200, #"{"devices":[]}"#)
        }
        #expect(try await schoolClient(server, sleeps: sleeps).device(serial: "F9A") == .none)
        #expect(server.requests.count == 2)
        #expect(sleeps.recorded == [.seconds(3)])
    }

    @Test("The asset tag is form-encoded strictly: a + survives")
    func assetTag() async throws {
        let server = MockServer { _ in .json(200, #"{"code":200,"message":"DeviceDetailsSaved"}"#) }
        try await schoolClient(server).setAssetTag("A+B 1", udid: "00008030-001A")
        let sent = try #require(server.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.path == "/api/devices/00008030-001A/details")
        #expect(sent.bodyString == "assetTag=A%2BB%201")
        #expect(sent.header("Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
    }

    @Test("Groups in either spelling, locations, and ADE placeholders without removed ones")
    func lists() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/api/devices/groups": .json(200, #"{"code":200,"DeviceGroups":[{"id":4,"name":"Carts","isSmartGroup":0,"members":"12"}]}"#)
            case "/api/locations": .json(200, #"{"locations":[{"id":"1","name":"Main","isDistrict":true}]}"#)
            default: .json(200, #"{"code":200,"placeholders":[{"serialNumber":"F9A","status":"assigned"},{"serialNumber":"F9B","status":"removed"}]}"#)
            }
        }
        let client = try schoolClient(server)
        let groups = try await client.groups()
        #expect(groups.first?.id == "4")
        #expect(groups.first?.members == 12)
        #expect(try await client.locations().first?.isDistrict == true)
        #expect(try await client.enrollmentPlaceholders().compactMap(\.serialNumber) == ["F9A"])
        #expect(server.requests.last?.header("X-Server-Protocol-Version") == "3")
    }

    @Test("Test Connection needs a device list back")
    func testConnection() async throws {
        let good = MockServer { _ in .json(200, #"{"code":200,"count":0,"devices":[]}"#) }
        try await schoolClient(good).testConnection()
        #expect(good.requests.first?.queryValue("serialnumber") == "CONNECTIONCHECK")
        let wrong = MockServer { _ in .json(200, "{}") }
        #expect(await thrown(JamfSchool.APIError.self) { try await schoolClient(wrong).testConnection() } != nil)
    }
}

// MARK: - Action entries

@Suite("Action entries")
@MainActor
struct ActionEntryTests {
    private let app = ActivityLogAppInfo(name: "Serial Number Reader", version: "2.0", build: "2", system: "macOS 26")

    @Test("An action names what the user did; its devices are masked in the bug-report export")
    func action() {
        let log = ActivityLog()
        log.recordAction("Restarted iPhone F9FXK2Q3HGMN over USB", devices: ["F9FXK2Q3HGMN", "0x1A2B3C4D5E"])
        log.recordAction("Entered DFU", note: "The command failed (exit 1).", failed: true,
                         service: "USB", devices: ["0x1A2B3C4D5E"])
        let entries = log.entries
        #expect(entries.map(\.category) == ["Action", "Action"])
        #expect(entries[0].isFailure == false)
        #expect(entries[1].isFailure == true)
        #expect(entries[1].service == "USB")

        let masked = ActivityLogExport.text(entries, masked: true, app: app)
        #expect(!masked.contains("F9FXK2Q3HGMN"))
        #expect(!masked.contains("0x1A2B3C4D5E"))
        #expect(masked.contains("<device 1>"))
        let unmasked = ActivityLogExport.text(entries, masked: false, app: app)
        #expect(unmasked.contains("F9FXK2Q3HGMN"))
    }
}
