import CryptoKit
import Foundation

/// Apple’s sign-in for Apple Business and School Manager
/// (`account.apple.com`): it checks the signed client assertion against the
/// public key registered for the client ID, as Apple does, so JTKit’s real
/// sign-in code runs. Tokens carry their scope; the API servers accept only
/// their own.
public nonisolated final class DemoAppleSignInServer: DemoServer, @unchecked Sendable {
    public static let host = "account.apple.com"

    private let lock = NSLock()
    private let keys: [String: P256.Signing.PublicKey]
    private var count = 0

    /// - Parameter keys: by client ID, the public key of the private key that signs its assertions.
    public init(keys: [String: P256.Signing.PublicKey]) {
        self.keys = keys
    }

    public func respond(to request: DemoRequest) -> DemoResponse {
        lock.withLock {
            guard request.method == "POST", request.pathSegments == ["auth", "oauth2", "v2", "token"] else {
                return DemoJSON.response(404, ["error": "not_found"])
            }
            let form = DemoJSON.form(request.body)
            let clientID = form["client_id"] ?? ""
            guard form["grant_type"] == "client_credentials",
                  form["client_assertion_type"] == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                  let key = keys[clientID], Self.verify(form["client_assertion"] ?? "", clientID: clientID, key: key) else {
                return DemoJSON.response(400, ["error": "invalid_client", "error_description": "The client assertion is invalid. (demo mode)"])
            }
            let scope = form["scope"] ?? ""
            let expected = clientID.hasPrefix("SCHOOLAPI.") ? ABM.Service.school.scope : ABM.Service.business.scope
            guard scope == expected else {
                return DemoJSON.response(400, ["error": "invalid_scope", "error_description": "Unknown scope. (demo mode)"])
            }
            count += 1
            return DemoJSON.response(200, ["access_token": "demo-apple-\(scope)-\(count)", "token_type": "Bearer",
                                           "expires_in": 3600, "scope": scope])
        }
    }

    /// An ES256 JWT for this client, addressed to Apple’s sign-in, signed by `key`'s private key.
    static func verify(_ jwt: String, clientID: String, key: P256.Signing.PublicKey) -> Bool {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let header = decode(parts[0]).flatMap(DemoJSON.object), header["alg"] as? String == "ES256",
              let claims = decode(parts[1]).flatMap(DemoJSON.object),
              claims["iss"] as? String == clientID, claims["sub"] as? String == clientID,
              claims["aud"] as? String == ABM.TokenProvider.tokenURL.absoluteString,
              let raw = decode(parts[2]), let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else {
            return false
        }
        return key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8))
    }

    private static func decode(_ base64URL: String) -> Data? {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }
}

/// One Apple Business Manager or Apple School Manager organization of
/// `DemoWorld` (Contoso or Contoso Academy) on Apple’s own address: devices,
/// the organization read, MDM servers and their devices, AppleCare,
/// Activation Lock, the assigned server, built-in management (none here),
/// audit events (Business only), and the writes as activities. A write
/// changes the devices at once and its activity reports "in progress" on
/// the first check and "completed" after.
public nonisolated final class DemoAppleBusinessServer: DemoServer, @unchecked Sendable {
    struct Record {
        let device: DemoWorld.Device
        var serverID: String?
        var releasedDaysAgo: Double?
        var migrationStatus: String?
        var migrationDeadline: String?
    }

    struct Activity {
        var checks = 0
        var failed: Bool
    }

    public let organization: DemoWorld.Organization
    public let service: ABM.Service

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var activities: [String: Activity] = [:]
    private var activityTypesValue: [String] = []
    private var requestCountValue = 0
    private let scenario: DemoScenario?
    private let now: Date
    private let pageSize: Int

    /// Activity types received, e.g. `ASSIGN_DEVICES`.
    public var activityTypes: [String] { lock.withLock { activityTypesValue } }
    /// Every request answered.
    public var requestCount: Int { lock.withLock { requestCountValue } }

    /// - Parameter pageSize: list items per page at most, to test paging.
    public init(organization: DemoWorld.Organization, scenario: DemoScenario? = nil, now: Date = Date(), pageSize: Int = 1_000) {
        self.organization = organization
        service = organization == .contoso ? .business : .school
        self.scenario = scenario
        self.now = now
        self.pageSize = max(pageSize, 1)
        for device in DemoWorld.devices(in: organization) {
            records[device.serial] = Record(device: device, serverID: device.appleServerID,
                                            releasedDaysAgo: device.releasedDaysAgo.map(Double.init))
            order.append(device.serial)
        }
    }

    /// The server a device is assigned to now.
    public func assignedServer(serial: String) -> String? {
        lock.withLock { records[serial.uppercased()]?.serverID }
    }

    public func isReleased(serial: String) -> Bool {
        lock.withLock { records[serial.uppercased()]?.releasedDaysAgo != nil }
    }

    // MARK: Requests

    public func respond(to request: DemoRequest) -> DemoResponse {
        lock.withLock {
            requestCountValue += 1
            guard DemoJSON.bearer(request)?.hasPrefix("demo-apple-\(service.scope)-") == true else {
                return Self.error(401, "UNAUTHORIZED", "Unauthorized", "The access token is missing or invalid.")
            }
            let path = request.pathSegments
            guard path.first == "v1" else { return Self.notFound() }
            if scenario == .missingPermission {
                return Self.error(403, "FORBIDDEN", "Forbidden", "This API account can’t read devices. (demo mode)")
            }
            switch (request.method, Array(path.dropFirst())) {
            case ("GET", ["orgDevices"]):
                return list(order.compactMap { records[$0] }.map { ["type": "orgDevices", "id": $0.device.serial,
                                                                    "attributes": attributes($0)] }, request)
            case ("GET", let p) where p.count == 2 && p[0] == "orgDevices":
                guard let record = records[p[1].uppercased()] else { return Self.notFound() }
                return DemoJSON.response(200, ["data": ["type": "orgDevices", "id": record.device.serial,
                                                        "attributes": attributes(record)]])
            case ("GET", let p) where p.count == 3 && p[0] == "orgDevices":
                guard let record = records[p[1].uppercased()] else { return Self.notFound() }
                return deviceDetail(p[2], record)
            case ("GET", let p) where p.count == 4 && p[0] == "orgDevices" && p[2] == "relationships" && p[3] == "assignedServer":
                guard let record = records[p[1].uppercased()] else { return Self.notFound() }
                let data: Any = record.serverID.map { ["type": "mdmServers", "id": $0] } ?? NSNull()
                return DemoJSON.response(200, ["data": data])
            case ("GET", ["mdmServers"]):
                return list(DemoWorld.mdmServers(in: organization).map { server in [
                    "type": "mdmServers", "id": server.id,
                    "attributes": ["serverName": server.name, "serverType": "MDM",
                                   "createdDateTime": DemoWorld.iso(daysAgo: 700, from: now),
                                   "updatedDateTime": DemoWorld.iso(daysAgo: 30, from: now)],
                ] }, request)
            case ("GET", let p) where p.count == 4 && p[0] == "mdmServers" && p[2] == "relationships" && p[3] == "devices":
                guard DemoWorld.mdmServers(in: organization).contains(where: { $0.id == p[1] }) else { return Self.notFound() }
                return list(order.filter { records[$0]?.serverID == p[1] }.map { ["type": "orgDevices", "id": $0] }, request)
            case ("GET", ["mdmDevices"]):
                return DemoJSON.response(200, ["data": [], "meta": ["paging": ["limit": 100]]])
            case ("GET", ["auditEvents"]):
                guard service == .business else { return Self.notFound() }
                return auditEvents(serial: request.query["filter[subjectId]"] ?? "")
            case ("POST", ["orgDeviceActivities"]):
                return submit(request.body)
            case ("GET", let p) where p.count == 2 && p[0] == "orgDeviceActivities":
                return activity(id: p[1])
            default:
                return Self.notFound()
            }
        }
    }

    // MARK: Reads

    private func attributes(_ record: Record) -> [String: Any] {
        let device = record.device
        var attributes: [String: Any] = [
            "serialNumber": device.serial,
            "deviceModel": device.model,
            "productFamily": device.family.rawValue,
            "productType": device.modelIdentifier,
            "status": record.serverID == nil ? "UNASSIGNED" : "ASSIGNED",
            "addedToOrgDateTime": DemoWorld.iso(daysAgo: 400 - Double(device.number), from: now),
            "updatedDateTime": DemoWorld.iso(daysAgo: 3, from: now),
            "purchaseSourceType": "RESELLER",
            "purchaseSourceId": "ZZDEMO1",
            "color": device.isComputer ? "MIDNIGHT" : "SILVER",
            "deviceCapacity": device.isComputer ? "512GB" : "128GB",
            "partNumber": "ZZ\(String(format: "%03d", device.number))DM/A",
            "wifiMacAddress": String(format: "00:00:5e:00:53:%02x", device.number),
            "isMdmMigrationCapable": device.isComputer,
        ]
        if let order = device.orderNumber {
            attributes["orderNumber"] = order
            attributes["orderDateTime"] = DemoWorld.iso(daysAgo: 410 - Double(device.number), from: now)
        }
        if let released = record.releasedDaysAgo { attributes["releasedFromOrgDateTime"] = DemoWorld.iso(daysAgo: released, from: now) }
        if let status = record.migrationStatus { attributes["mdmMigrationStatus"] = status }
        if let deadline = record.migrationDeadline { attributes["mdmMigrationDeadlineDateTime"] = deadline }
        return attributes
    }

    private func deviceDetail(_ part: String, _ record: Record) -> DemoResponse {
        let device = record.device
        switch part {
        case "appleCareCoverage":
            let active = device.appleCareDaysLeft >= 0
            return DemoJSON.response(200, ["data": [[
                "type": "appleCareCoverage", "id": "\(device.serial)-AC",
                "attributes": [
                    "description": device.isComputer ? "AppleCare+ for Mac" : "AppleCare+",
                    "status": active ? "ACTIVE" : "INACTIVE",
                    "startDateTime": DemoWorld.iso(daysAgo: 1095 - Double(device.appleCareDaysLeft), from: now),
                    "endDateTime": DemoWorld.iso(daysAgo: -Double(device.appleCareDaysLeft), from: now),
                    "paymentType": "PAID_UP_FRONT", "isRenewable": false, "isCanceled": false,
                ] as [String: Any],
            ]], "meta": ["paging": ["limit": 100]]])
        case "activationLockStatus":
            return DemoJSON.response(200, ["data": ["type": "activationLockStatus", "id": device.serial,
                                                    "attributes": ["isLocked": false, "lockType": "NONE"]]])
        default:
            return Self.notFound()
        }
    }

    private func auditEvents(serial: String) -> DemoResponse {
        guard let record = records[serial.uppercased()] else {
            return DemoJSON.response(200, ["data": [], "meta": ["paging": [:]]])
        }
        let device = record.device
        var events: [[String: Any]] = [[
            "type": "auditEvents", "id": "\(device.serial)-1",
            "attributes": ["eventDateTime": DemoWorld.iso(daysAgo: 400 - Double(device.number), from: now),
                           "type": "DEVICE_ADDED_TO_ORG", "actorName": "Contoso Reseller", "outcome": "SUCCESS",
                           "eventDataPropertyKey": "deviceAddedToOrg",
                           "deviceAddedToOrg": ["purchaseSourceType": "RESELLER"]] as [String: Any],
        ]]
        if let server = DemoWorld.mdmServers(in: organization).first(where: { $0.id == device.appleServerID }) {
            events.append([
                "type": "auditEvents", "id": "\(device.serial)-2",
                "attributes": ["eventDateTime": DemoWorld.iso(daysAgo: 398 - Double(device.number), from: now),
                               "type": "DEVICE_ASSIGNED_TO_SERVER", "actorName": "Morgan Sample", "outcome": "SUCCESS",
                               "eventDataPropertyKey": "deviceAssignedToServer",
                               "deviceAssignedToServer": ["targetServerName": server.name]] as [String: Any],
            ])
        }
        return DemoJSON.response(200, ["data": events, "meta": ["paging": ["limit": 100]]])
    }

    /// Apple’s `limit` and `links.next` paging, on this organization’s address.
    private func list(_ items: [[String: Any]], _ request: DemoRequest) -> DemoResponse {
        let limit = min(Int(request.query["limit"] ?? "") ?? 100, pageSize)
        let start = Int(request.query["cursor"] ?? "") ?? 0
        var body: [String: Any] = ["data": Array(items.dropFirst(start).prefix(limit)),
                                   "meta": ["paging": ["limit": limit, "total": items.count]]]
        if start + limit < items.count, var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) {
            var query = (components.queryItems ?? []).filter { $0.name != "cursor" }
            query.append(URLQueryItem(name: "cursor", value: "\(start + limit)"))
            components.queryItems = query
            body["links"] = ["self": request.url.absoluteString, "next": components.url?.absoluteString ?? ""]
        } else {
            body["links"] = ["self": request.url.absoluteString]
        }
        return DemoJSON.response(200, body)
    }

    // MARK: Writes

    private func submit(_ body: Data) -> DemoResponse {
        guard let data = DemoJSON.object(body)?["data"] as? [String: Any],
              let attributes = data["attributes"] as? [String: Any],
              let type = attributes["activityType"] as? String else {
            return Self.error(400, "PARAMETER_ERROR.INVALID", "Invalid request", "The activity can’t be read.")
        }
        let relationships = data["relationships"] as? [String: Any] ?? [:]
        let serials = (((relationships["devices"] as? [String: Any])?["data"]) as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }.map { $0.uppercased() }
        let server = ((relationships["mdmServer"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
        let deadline = (attributes["activityTypeMetadata"] as? [String: Any])?["mdmMigrationDeadlineDateTime"] as? String
        guard !serials.isEmpty else {
            return Self.error(400, "PARAMETER_ERROR.REQUIRED", "Missing devices", "Choose at least one device.")
        }
        if type == "RELEASE_DEVICES", service != .business {
            return Self.error(400, "PARAMETER_ERROR.INVALID", "Invalid activity type", "Apple School Manager can’t release devices.")
        }
        if let server, !DemoWorld.mdmServers(in: organization).contains(where: { $0.id == server }) {
            return Self.error(404, "NOT_FOUND", "MDM server not found", "No such MDM server.")
        }
        var failed = false
        for serial in serials {
            guard records[serial] != nil, records[serial]?.releasedDaysAgo == nil else { failed = true; continue }
            switch type {
            case "ASSIGN_DEVICES":
                records[serial]?.serverID = server
            case "UNASSIGN_DEVICES":
                records[serial]?.serverID = nil
            case "RELEASE_DEVICES":
                records[serial]?.serverID = nil
                records[serial]?.releasedDaysAgo = 0
            case "ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE":
                records[serial]?.serverID = server
                records[serial]?.migrationStatus = "REQUESTED"
                records[serial]?.migrationDeadline = deadline
            case "UPDATE_MDM_MIGRATION_DEADLINE":
                records[serial]?.migrationDeadline = deadline
            case "CANCEL_MDM_MIGRATION":
                records[serial]?.migrationStatus = "FAILED"
            default:
                return Self.error(400, "PARAMETER_ERROR.INVALID", "Invalid activity type", "Unknown activity type.")
            }
        }
        activityTypesValue.append(type)
        let id = DemoSamples.uuid(0x8000 + activities.count + 1)
        activities[id] = Activity(failed: failed)
        return DemoJSON.response(201, ["data": ["type": "orgDeviceActivities", "id": id,
                                                "attributes": ["status": "IN_PROGRESS", "subStatus": "SUBMITTED",
                                                               "createdDateTime": DemoWorld.iso(daysAgo: 0, from: now)]]])
    }

    private func activity(id: String) -> DemoResponse {
        guard var activity = activities[id] else { return Self.notFound() }
        activity.checks += 1
        activities[id] = activity
        let done = activity.checks > 1
        let attributes: [String: Any] = done
            ? ["status": "COMPLETED", "subStatus": activity.failed ? "COMPLETED_WITH_FAILURE" : "COMPLETED_WITH_SUCCESS",
               "completedDateTime": DemoWorld.iso(daysAgo: 0, from: now)]
            : ["status": "IN_PROGRESS", "subStatus": "PROCESSING"]
        return DemoJSON.response(200, ["data": ["type": "orgDeviceActivities", "id": id, "attributes": attributes]])
    }

    private static func notFound() -> DemoResponse {
        error(404, "NOT_FOUND", "The specified resource does not exist", "There is no resource with this ID.")
    }

    private static func error(_ status: Int, _ code: String, _ title: String, _ detail: String) -> DemoResponse {
        DemoJSON.response(status, ["errors": [["id": DemoSamples.uuid(0xe000 + status), "status": "\(status)",
                                               "code": code, "title": title, "detail": detail]]])
    }
}
