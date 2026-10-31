import AppKit
import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

// Jamf Pro around a device: PreStages, ADE,
// compliance, DDM, declarations, sites, departments, buildings, the four
// secrets and their rules, copying a secret, and the privilege table checked
// against Jamf Pro’s own API description.

private func direct(_ server: MockServer, log: ActivityLog? = nil) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: URL(string: "https://jamf.example.com")!, scope: .organization, server: .jamfPro,
                            tokens: FixedToken("tok"),
                            recorder: RequestRecorder(session: server.session, log: log, service: "Jamf Pro"),
                            sleep: { _ in }, random: { 0 })
}

private func paths(_ server: MockServer) -> [String] { server.requests.map(\.path) }

// MARK: - The calls

@Suite("Jamf Pro: PreStages, ADE, compliance, DDM, sites")
struct JamfProManagementTests {

    @Test("PreStages: every page, sorted by ID")
    func preStages() async throws {
        let server = MockServer { request in
            let page = Int(request.queryValue("page") ?? "0") ?? 0
            let ids = page == 0 ? Array(1...100) : [101]
            let items = ids.map { #"{"id":"\#($0)","displayName":"P\#($0)","deviceEnrollmentProgramInstanceId":"9"}"# }
            return .json(200, #"{"totalCount":101,"results":[\#(items.joined(separator: ","))]}"#)
        }
        let prestages = try await direct(server).preStages(.computer)
        #expect(prestages.count == 101)
        #expect(prestages.last == JamfPro.PreStage(id: "101", displayName: "P101", enrollmentInstanceID: "9"))
        #expect(server.requests.allSatisfy { $0.path == "/api/v3/computer-prestages" && $0.queryValue("sort") == "id:asc" })
    }

    @Test("Scope changes read the version lock first; never repeated after a server error")
    func scope() async throws {
        let server = MockServer { request in
            if request.method == "GET" { return .json(200, #"{"versionLock":4}"#) }
            return request.path.hasSuffix("delete-multiple") ? .json(500, "{}") : .json(200, "{}")
        }
        let client = try direct(server)
        try await client.addToPreStage(.mobileDevice, id: "3", serials: ["S1"])
        #expect(paths(server) == ["/api/v2/mobile-device-prestages/3/scope", "/api/v2/mobile-device-prestages/3/scope"])
        #expect(server.requests[1].bodyString.contains(#""versionLock":4"#))
        await #expect(throws: JamfPlatform.APIError.self) { try await client.removeFromPreStage(.mobileDevice, id: "3", serials: ["S1"]) }
        #expect(server.requests.filter { $0.path.hasSuffix("delete-multiple") }.count == 1)
    }

    @Test("ADE: Apple’s server IDs and the serial → token map")
    func ade() async throws {
        let server = MockServer { request in
            if request.path.hasSuffix("/device-enrollments") {
                return .json(200, #"{"totalCount":2,"results":[{"id":"1","serverUuid":"AAA"},{"id":"2","serverUuid":""}]}"#)
            }
            return .json(200, #"{"totalCount":1,"results":[{"serialNumber":"c02"}]}"#)
        }
        let client = try direct(server)
        #expect(try await client.deviceEnrollmentServerIDs() == ["AAA"])
        #expect(try await client.deviceEnrollmentInstanceBySerial() == ["C02": "2"])
        #expect(server.requests.last?.queryValue("page-size") == "500")
    }

    @Test("Compliance: a list or one object; the applicable entry wins; recorded")
    func compliance() async throws {
        let server = MockServer { request in
            request.path.hasSuffix("/computer/7")
                ? .json(200, #"[{"applicable":false},{"applicable":true,"complianceState":"COMPLIANT","complianceVendor":"V"}]"#)
                : .json(200, #"{"applicable":true,"complianceState":"NON_COMPLIANT"}"#)
        }
        let log = await ActivityLog()
        let client = try direct(server, log: log)
        #expect(try await client.deviceCompliance(.computer, id: "7") == JamfPro.DeviceCompliance(applicable: true, state: "COMPLIANT", vendor: "V"))
        #expect(try await client.deviceCompliance(.mobileDevice, id: "12")?.state == "NON_COMPLIANT")
        #expect(await log.entries.allSatisfy { $0.request?.responseBody != nil })
    }

    @Test("DDM status: the items; none when refused or unknown")
    func ddm() async throws {
        let server = MockServer { request in
            request.path.contains("/M-1/")
                ? .json(200, #"{"statusItems":[{"key":"a","value":"1","lastUpdateTime":"2026-10-20T08:00:00.000"},{"value":"no key"}]}"#)
                : .json(403, "{}")
        }
        let client = try direct(server)
        #expect(try await client.ddmStatusItems(managementID: "M-1", kind: .computer)
                == [JamfPro.StatusItem(key: "a", value: "1", lastUpdateTime: "2026-10-20T08:00:00.000")])
        #expect(try await client.ddmStatusItems(managementID: "M-2", kind: .computer) == nil)
    }

    @Test("Jamf Pro’s flattened declarations: the Error detail first, a record without identifier only when invalid")
    func flattened() {
        let text = "{active=true, identifier=Blueprint_0F2C1B0A-1111-2222-3333-444455556666_s1, valid=invalid, reasons=[{code=C, description=D, details={Error=Target (15.7.3) is older [x]}}, {code=OnlyCode}]},{valid=valid},{valid=invalid, reasons=[{description=Broken}]}"
        let declarations = JamfPro.flattenedDeclarations(text)
        #expect(declarations.count == 2)
        #expect(declarations[0].reasons == ["Target (15.7.3) is older [x]", "OnlyCode"])
        #expect(declarations[0].blueprintID == "0F2C1B0A-1111-2222-3333-444455556666")
        #expect(declarations[1].identifier == "Unidentified declaration" && declarations[1].validity == "invalid")
        #expect(JamfPro.flattenedDeclarations(nil).isEmpty && JamfPro.flattenedDeclarations("garbage").isEmpty)
    }

    @Test("A declaration’s detail is read but never recorded")
    func declaration() async throws {
        let server = MockServer { _ in
            .json(200, #"{"declarations":[{"uuid":"u","type":"t","payloadJson":"{\"Password\":\"SECRET\"}"}]}"#)
        }
        let log = await ActivityLog()
        let details = try await direct(server, log: log).declaration(id: "d-1", kind: .mobileDevice)
        #expect(details == [JamfPro.DeclarationDetail(uuid: "u", type: "t", payload: #"{"Password":"SECRET"}"#)])
        #expect(await !ActivityLogExport.text(log.entries, masked: false).contains("SECRET"))
    }

    @Test("Sites in either shape; a site move is safe to repeat")
    func sites() async throws {
        let calls = Counter()
        let server = MockServer { request in
            if request.method == "PATCH" { return calls.next() == 1 ? .json(503, "{}") : .json(200, "{}") }
            return request.queryValue("x") == nil ? .json(200, #"{"results":[{"id":"1","name":"Main"}]}"#) : .json(200, "[]")
        }
        let client = try direct(server)
        #expect(try await client.sites() == [JamfPro.Site(id: "1", name: "Main")])
        try await client.setSite("1", computerID: "7")
        #expect(server.requests.filter { $0.method == "PATCH" }.count == 2)
        #expect(server.requests.last?.bodyString == #"{"general":{"siteId":"1"}}"#)
    }

    @Test("Department names: more than ten pages is an error, never a list cut short")
    func pageLimit() async throws {
        let server = MockServer { request in
            let page = Int(request.queryValue("page") ?? "0") ?? 0
            let items = (0..<1000).map { #"{"id":"\#(page * 1000 + $0)","name":"N"}"# }
            return .json(200, #"{"totalCount":20000,"results":[\#(items.joined(separator: ","))]}"#)
        }
        await #expect(throws: JamfPlatform.APIError.self) { _ = try await direct(server).departmentNames() }
        #expect(server.requests.count == 10)
    }
}

// MARK: - Secrets

@Suite("The four secrets")
struct JamfProSecretTests {

    @Test("Only LAPS rotates when viewed, so only LAPS asks first")
    func rules() throws {
        #expect(JamfPro.Secret.allCases.filter(\.rotatesWhenViewed) == [.localAdminPassword])
        let question = try #require(JamfPro.Secret.localAdminPassword.confirmation(account: "admin", rotation: "after 1 hour"))
        #expect(question.title == "Rotation after viewing")
        #expect(question.message == "Viewing the password for admin will cause Jamf Pro to rotate it after 1 hour.")
        #expect(JamfPro.Secret.allCases.filter { $0 != .localAdminPassword }.allSatisfy { $0.confirmation(account: nil, rotation: "") == nil })
        #expect(JamfPro.Secret.localAdminPassword.actionSummary(serial: "C02", account: "admin")
                == "Read the local administrator password for admin on C02, queuing a rotation")
        #expect(JamfPro.Secret.fileVaultRecoveryKey.privilege == .viewDiskEncryptionRecoveryKey)
    }

    @Test("Each read: its address, nothing recorded, nil when none is held")
    func reads() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/api/v4/computers-inventory/7/filevault": .json(200, #"{"personalRecoveryKey":"SECRET-1","individualRecoveryKeyValidityStatus":"VALID"}"#)
            case "/api/v4/computers-inventory/7/view-recovery-lock-password": .json(200, #"{"recoveryLockPassword":"SECRET-2"}"#)
            case "/api/v4/computers-inventory/7/view-device-lock-pin": .json(200, #"{"pin":"SECRET-3"}"#)
            case "/api/v2/local-admin-password/M-7/account/admin/g-1/password": .json(200, #"{"password":"SECRET-4"}"#)
            case "/api/v2/local-admin-password/M-7/account/jamf/password":
                .json(400, #"{"httpStatus":400,"errors":[{"code":"NOT_FOUND"}]}"#)
            default: .json(404, "{}")
            }
        }
        let log = await ActivityLog()
        let client = try direct(server, log: log)
        #expect(try await client.fileVaultKey(computerID: "7") == JamfPro.FileVaultKey(personalRecoveryKey: "SECRET-1", validityStatus: "VALID"))
        #expect(try await client.recoveryLockPassword(computerID: "7") == "SECRET-2")
        #expect(try await client.deviceLockPIN(computerID: "7") == "SECRET-3")
        #expect(try await client.localAdminPassword(managementID: "M-7", account: .init(username: "admin", guid: "g-1")) == "SECRET-4")
        #expect(try await client.localAdminPassword(managementID: "M-7", account: .init(username: "jamf")) == nil)
        #expect(try await client.fileVaultKey(computerID: "8") == nil)
        #expect(await !ActivityLogExport.text(log.entries, masked: false).contains("SECRET"))
        #expect(await log.entries.filter { $0.request?.contentsWithheld == true }.count == 6)
    }

    @Test("A failed read carries only the status and JTKit’s hints, never the server’s text")
    func failure() async throws {
        let server = MockServer { _ in
            .json(403, #"{"httpStatus":403,"traceId":"trace-SECRET","errors":[{"code":"X","description":"Could not return SECRET-key"}]}"#)
        }
        do {
            _ = try await direct(server).fileVaultKey(computerID: "7")
            Issue.record("read")
        } catch let error as JamfPlatform.APIError {
            #expect(!error.message().contains("SECRET"))
            #expect(error.message() == """
                HTTP 403 Forbidden
                The API role is missing the “View Disk Encryption Recovery Key” privilege. Add it in Jamf Pro under Settings › API Roles and Clients.
                """)
        }
    }

    @Test("LAPS accounts: empty without the privilege; the rotation time")
    func accounts() async throws {
        let server = MockServer { request in
            if request.path.hasSuffix("/settings") { return .json(200, #"{"passwordRotationTime":3600}"#) }
            return request.path.contains("/M-1/") ? .json(200, #"{"results":[{"username":"admin","guid":"g","userSource":"MDM"},{"username":""}]}"#) : .json(403, "{}")
        }
        let client = try direct(server)
        #expect(try await client.localAdminAccounts(managementID: "M-1") == [JamfPro.LocalAdminAccount(username: "admin", guid: "g", source: "MDM")])
        #expect(try await client.localAdminAccounts(managementID: "M-2").isEmpty)
        #expect(await client.localAdminRotationTime() == 3600)
    }
}

// MARK: - Copying a secret

@Suite("Copying a secret")
@MainActor
struct SecretPasteboardTests {

    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("JTKitTests.\(UUID().uuidString)"))
    }

    @Test("Concealed, and cleared after the delay while it still holds the secret")
    func cleared() async {
        let board = pasteboard()
        let sleeps = SleepLog()
        await SecretPasteboard.copy("SECRET", to: board, sleep: sleeps.sleep).value
        #expect(sleeps.recorded == [.seconds(60)])
        #expect(board.string(forType: .string) == nil)
    }

    @Test("Marked concealed while it is there")
    func concealed() {
        let board = pasteboard()
        SecretPasteboard.copy("SECRET", to: board, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }).cancel()
        #expect(board.string(forType: .string) == "SECRET")
        #expect(board.types?.contains(SecretPasteboard.concealedType) == true)
    }

    @Test("Something copied since is left alone")
    func leftAlone() async {
        let board = pasteboard()
        let gate = AsyncStream<Void>.makeStream()
        let task = SecretPasteboard.copy("SECRET", to: board, sleep: { _ in for await _ in gate.stream { return } })
        board.clearContents()
        board.setString("something else", forType: .string)
        gate.continuation.yield()
        await task.value
        #expect(board.string(forType: .string) == "something else")
    }
}

// MARK: - Privileges against Jamf Pro’s API description

@Suite("The privilege table against Jamf Pro’s API description")
struct PrivilegeTableTests {

    /// `x-required-privileges` per path and method, from Jamf Pro 11.33.1
    /// (Fixtures/jamf-pro-11.33.1-privileges.json; see its "source").
    static let description: [String: [String: [String]]] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/jamf-pro-11.33.1-privileges.json")
        struct File: Decodable { let paths: [String: [String: [String]]] }
        return (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)).paths) ?? [:]
    }()

    static var everyListed: Set<String> { Set(description.values.flatMap(\.values).flatMap { $0 }) }

    /// Table entries the description doesn’t list, and why. Anything else
    /// missing from it is a renamed or misspelled privilege.
    static let notInDescription: [String: String] = [
        "Delete Mobile Devices": "Classic API (mobiledevices/id/{id}); not in this description",
        "Send Inventory Requests to Mobile Devices": "checked by Jamf Pro for the Classic command; not in this description",
        "Send Computer Remote Lock Command": "checked by Jamf Pro for the command; the description lists only View MDM command information",
        "Send Mobile Device Remote Lock Command": "checked by Jamf Pro for the command; the description lists only View MDM command information",
        "Send Mobile Device Remove Passcode Command": "checked by Jamf Pro for the command; the description lists only View MDM command information",
        "Send Mobile Device Restart Device Command": "checked by Jamf Pro for the command; the description lists only View MDM command information",
        "Send Mobile Device Shut Down Command": "checked by Jamf Pro for the command; the description lists only View MDM command information",
        "Create Policies": "Classic API (policies); used by Jamf Deployer's preflight",
        "Read Patch Internal Source": "Classic API (patch sources)",
        "Read Patch External Source": "Classic API (patch sources)",
        "View License Serial": "deprecated: Jamf Pro names it View License Serial Numbers",
        "View License Serial Numbers": "Classic API (licensed software's serial numbers)",
        "Send Blank Push": "deprecated: not a Jamf Pro privilege",
    ]

    /// Table entries for objects only the Classic API serves (JamfMigrator
    /// copies them over `JSSResource`), which this description doesn’t cover.
    /// Their names follow Jamf Pro’s privilege list (checked in JamfMigrator’s
    /// docs/PERMISSIONS.md against a Jamf Pro 11.32 instance).
    static let classicOnly: Set<String> = [
        "Create Sites",
        "Update Sites",
        "Delete Sites",
        "Read Network Segments",
        "Create Network Segments",
        "Update Network Segments",
        "Delete Network Segments",
        "Read User Extension Attributes",
        "Create User Extension Attributes",
        "Update User Extension Attributes",
        "Delete User Extension Attributes",
        "Read Smart User Groups",
        "Create Smart User Groups",
        "Delete Smart User Groups",
        "Create Static User Groups",
        "Update Static User Groups",
        "Delete Static User Groups",
        "Read Directory Bindings",
        "Create Directory Bindings",
        "Update Directory Bindings",
        "Delete Directory Bindings",
        "Read Software Update Servers",
        "Create Software Update Servers",
        "Update Software Update Servers",
        "Delete Software Update Servers",
        "Read Advanced Computer Searches",
        "Create Advanced Computer Searches",
        "Update Advanced Computer Searches",
        "Delete Advanced Computer Searches",
        "Read Advanced User Searches",
        "Create Advanced User Searches",
        "Update Advanced User Searches",
        "Delete Advanced User Searches",
        "Read macOS Configuration Profiles",
        "Create macOS Configuration Profiles",
        "Update macOS Configuration Profiles",
        "Delete macOS Configuration Profiles",
        "Read iOS Configuration Profiles",
        "Create iOS Configuration Profiles",
        "Update iOS Configuration Profiles",
        "Delete iOS Configuration Profiles",
        "Read Mac Applications",
        "Create Mac Applications",
        "Update Mac Applications",
        "Delete Mac Applications",
        "Read Mobile Device Applications",
        "Create Mobile Device Applications",
        "Update Mobile Device Applications",
        "Delete Mobile Device Applications",
        "Create eBooks",
        "Update eBooks",
        "Delete eBooks",
        "Read Classes",
        "Create Classes",
        "Update Classes",
        "Delete Classes",
        "Read Restricted Software",
        "Create Restricted Software",
        "Update Restricted Software",
        "Delete Restricted Software",
        "Read Licensed Software",
        "Create Licensed Software",
        "Update Licensed Software",
        "Delete Licensed Software",
        "Read Printers",
        "Create Printers",
        "Update Printers",
        "Delete Printers",
        "Delete Policies",
        "Create Patch Policies",
        "Delete Patch Policies",
        "Read Webhooks",
        "Create Webhooks",
        "Update Webhooks",
        "Delete Webhooks",
    ]

    /// Every privilege name Jamf Pro 11.33.1 offers for an API role
    /// (Fixtures/jamf-pro-11.33.1-privilege-names.json, read from a test
    /// instance’s `GET api/v1/api-role-privileges` on 2026-10-26; names only).
    static let privilegeNames: Set<String> = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/jamf-pro-11.33.1-privilege-names.json")
        struct File: Decodable { let privileges: [String] }
        return Set((try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)).privileges) ?? [])
    }()

    /// Table entries marked deprecated: kept for old callers, not Jamf Pro names.
    static let deprecated: Set<String> = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/JTKit/Jamf/Pro/JamfPro.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Set(source.matches(of: /@available\(\*, deprecated[^\n]*\n\s*public static let \w+: Privilege = "([^"]+)"/)
            .map { String($0.1) })
    }()

    /// Every `Privilege` constant in JTKit’s table.
    static let table: [String] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/JTKit/Jamf/Pro/JamfPro.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return source.matches(of: /public static let \w+: Privilege = "([^"]+)"/).map { String($0.1) }
    }()

    @Test("The saved description is there and complete")
    func fixture() {
        #expect(Self.description.count > 400)
        #expect(Self.table.count > 40)
    }

    @Test("Every privilege in the table is one Jamf Pro offers for an API role")
    func privilegeList() {
        #expect(Self.privilegeNames.count == 525)
        for name in Self.table where !Self.deprecated.contains(name) {
            #expect(Self.privilegeNames.contains(name), "“\(name)” isn’t a Jamf Pro 11.33.1 privilege: renamed or misspelt?")
        }
    }

    @Test("Every privilege in the table is one Jamf Pro lists, or explained")
    func table() {
        for name in Self.table {
            #expect(Self.everyListed.contains(name) || Self.notInDescription[name] != nil || Self.classicOnly.contains(name),
                    "“\(name)” isn’t in Jamf Pro 11.33.1’s API description: renamed?")
        }
        for name in Array(Self.notInDescription.keys) + Self.classicOnly {
            #expect(!Self.everyListed.contains(name), "“\(name)” is in the description now: remove it from the exceptions")
        }
    }

    /// The description’s privileges for a request JTKit sent, nil when the
    /// path isn’t in it (the Classic API, the Platform API).
    static func listed(path: String, method: String) -> [String]? {
        guard path.hasPrefix("pro/") else { return nil }
        let wanted = path.dropFirst("pro".count).split(separator: "/")
        // the template with the most literal segments wins (detail over {id})
        let matches = description.compactMap { template, methods -> (literals: Int, privileges: [String])? in
            let parts = template.split(separator: "/")
            guard parts.count == wanted.count,
                  zip(parts, wanted).allSatisfy({ $0.hasPrefix("{") || $0 == $1 }),
                  let privileges = methods[method.lowercased()] else { return nil }
            return (parts.filter { !$0.hasPrefix("{") }.count, privileges)
        }
        return matches.max { $0.literals < $1.literals }?.privileges
    }

    @Test("Every Jamf Pro API request JTKit makes names a privilege the description gives for it")
    func requests() async throws {
        let seen = Locked<[(path: String, method: String, privileges: [String])]>([])
        let server = MockServer { request in
            if request.path.hasSuffix("/detail") && request.method == "GET" { return .json(200, #"{"ios":{"unlockToken":"t"}}"#) }
            return .json(200, #"{"totalCount":0,"results":[],"versionLock":1,"serialsByPrestageId":{},"statusItems":[],"declarations":[],"udidsNotProcessed":{"udids":[]},"errorUuids":[]}"#)
        }
        var client = try direct(server)
        client.observePrivileges = { path, method, privileges in
            seen.withLock { $0.append((path, method, privileges.map(\.rawValue))) }
        }
        let mac = MDMCommand.Target(serial: "C02", recordID: "7", kind: .computer, udid: "U-7", managementID: "M-7")
        let iPad = MDMCommand.Target(serial: "DMP", recordID: "12", kind: .mobileDevice, udid: "U-12", managementID: "M-12")
        // every Jamf Pro API call
        _ = try? await client.computer(serial: "C02")
        _ = try? await client.mobileDevice(serial: "DMP")
        _ = try? await client.computers(serials: ["C02"])
        _ = try? await client.mobileDevices(serials: ["DMP"])
        try? await client.setAssetTag("A", computerID: "7")
        try? await client.setAssetTag("A", mobileDeviceID: "12")
        for command in MDMCommand.allCases {
            _ = try? await client.send(command, to: [mac, iPad], pin: "123456")
        }
        try? await client.deleteComputer(id: "7")
        for family in JamfPro.PreStageFamily.allCases {
            _ = try? await client.preStages(family)
            _ = try? await client.preStageScope(family)
            try? await client.addToPreStage(family, id: "1", serials: ["C02"])
            try? await client.removeFromPreStage(family, id: "1", serials: ["C02"])
        }
        _ = try? await client.deviceEnrollmentServerIDs()
        _ = try? await client.deviceEnrollmentInstanceBySerial()
        _ = try? await client.deviceComplianceEnabled()
        _ = try? await client.deviceCompliance(.computer, id: "7")
        _ = try? await client.ddmStatusItems(managementID: "M-7", kind: .computer)
        _ = try? await client.ddmStatusItems(managementID: "M-12", kind: .mobileDevice)
        _ = try? await client.declaration(id: "d", kind: .computer)
        _ = try? await client.sites()
        try? await client.setSite("1", computerID: "7")
        try? await client.setSite("1", mobileDeviceID: "12")
        _ = try? await client.departmentNames()
        _ = try? await client.buildingNames()
        _ = try? await client.fileVaultKey(computerID: "7")
        _ = try? await client.recoveryLockPassword(computerID: "7")
        _ = try? await client.deviceLockPIN(computerID: "7")
        _ = try? await client.localAdminAccounts(managementID: "M-7")
        _ = try? await client.localAdminPassword(managementID: "M-7", account: .init(username: "admin", guid: "g"))
        _ = await client.localAdminRotationTime()

        let requests = seen.value.filter { !$0.path.hasPrefix("proclassic/") }
        #expect(requests.count > 40)
        for request in requests {
            guard let listed = Self.listed(path: request.path, method: request.method) else {
                Issue.record("\(request.method) \(request.path) isn’t in Jamf Pro 11.33.1’s API description")
                continue
            }
            if listed.isEmpty { continue }
            #expect(request.privileges.contains { listed.contains($0) },
                    "\(request.method) \(request.path) names \(request.privileges); the description lists \(listed)")
            for name in request.privileges where !listed.contains(name) {
                #expect(Self.notInDescription[name] != nil,
                        "\(request.method) \(request.path) also names “\(name)”, which the description doesn’t give for it")
            }
        }
    }

    @Test("A request needing two privileges names both")
    func twoPrivileges() async throws {
        let server = MockServer { _ in .json(403, "{}") }
        let result = try await direct(server).send(.lockMobile, to: [MDMCommand.Target(serial: "DMP", recordID: "12", kind: .mobileDevice, managementID: "M")])
        #expect(result.problems?.contains("The API role is missing one of these privileges: “View MDM command information in Jamf Pro API”, “Send Mobile Device Remote Lock Command”.") == true)
    }
}
