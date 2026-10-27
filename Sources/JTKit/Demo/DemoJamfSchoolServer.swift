import Foundation

/// An in-memory Jamf School holding `DemoWorld`'s Contoso Academy devices:
/// the fleet (whole, by serial, by group), one device, groups, locations, the
/// ADE placeholders, commands, asset tag, moving location and trash. Like the
/// real service it signs every request with Network ID and API key, and
/// reports errors in the body (also under HTTP 200). It sends no device owner.
public nonisolated final class DemoJamfSchoolServer: DemoServer, @unchecked Sendable {
    public static let locations = [(1, "Contoso Academy – Main Campus"), (2, "Contoso Academy – North Campus")]
    /// Groups: (id, name, device numbers).
    static let groups: [(String, String, ClosedRange<Int>)] = [
        (DemoSamples.schoolGroupIDs[0], "Year 7 iPads", 31...38), (DemoSamples.schoolGroupIDs[1], "Lab Macs", 39...40),
    ]

    struct Record {
        let device: DemoWorld.Device
        var assetTag: String
        var locationID = 1
        var managed = true
        var inTrash = false
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var commandsValue: [(action: String, udid: String)] = []
    private let authorization: String
    private let scenario: DemoScenario?
    private let now: Date

    /// Commands received: the action (`refresh`, `restart`, …) and the device.
    public var commands: [(action: String, udid: String)] { lock.withLock { commandsValue } }

    /// - Parameter apiKey: the key every request must carry with the demo connection's Network ID.
    public init(apiKey: String = DemoSecretStore().secret(for: "") ?? "", scenario: DemoScenario? = nil, now: Date = Date()) {
        authorization = "Basic " + Data("\(Connection.demoJamfSchool.clientID):\(apiKey)".utf8).base64EncodedString()
        self.scenario = scenario
        self.now = now
        for device in DemoWorld.devices(managedBy: .jamfSchool) {
            records[device.udid] = Record(device: device, assetTag: device.assetTag,
                                          locationID: device.isComputer ? 2 : 1)
        }
    }

    /// A device's current asset tag, or nil when it isn't there.
    public func assetTag(serial: String) -> String? {
        lock.withLock { records.values.first { $0.device.serial == serial.uppercased() }?.assetTag }
    }

    public func location(serial: String) -> Int? {
        lock.withLock { records.values.first { $0.device.serial == serial.uppercased() }?.locationID }
    }

    public func respond(to request: DemoRequest) -> DemoResponse {
        lock.withLock {
            guard DemoJSON.header("Authorization", in: request) == authorization else {
                return DemoJSON.response(401, ["code": 401, "message": "Unauthorized"])
            }
            let parts = request.pathSegments
            guard parts.first == "api" else { return Self.message(404, "NotFound") }
            let path = Array(parts.dropFirst())
            if scenario == .missingPermission, path.first == "devices" {
                return DemoJSON.response(403, ["code": 403, "message": "ApiKeyNotAllowed"])
            }
            switch (request.method, path) {
            case ("GET", ["devices"]):
                return list(request.query)
            case ("GET", ["devices", "groups"]):
                return DemoJSON.response(200, ["code": 200, "count": Self.groups.count, "deviceGroups": Self.groups.map {
                    ["id": Int($0.0) ?? 0, "name": $0.1, "isSmartGroup": false, "members": $0.2.count] as [String: Any]
                }])
            case ("GET", ["locations"]):
                return DemoJSON.response(200, ["code": 200, "locations": Self.locations.map {
                    ["id": $0.0, "name": $0.1, "isDistrict": false] as [String: Any]
                }])
            case ("GET", ["dep"]):
                guard DemoJSON.header("X-Server-Protocol-Version", in: request) == "3" else {
                    return Self.message(400, "MissingParameter")
                }
                let placeholders = DemoWorld.devices.filter { $0.appleServerID == DemoWorld.jamfSchoolServerID }
                    .map { ["serialNumber": $0.serial, "status": "assigned", "profileName": "Contoso Academy"] }
                return DemoJSON.response(200, ["code": 200, "placeholders": placeholders])
            case ("PUT", ["devices", "migrate"]):
                return move(request.body)
            case ("GET", let p) where p.count == 2 && p[0] == "devices":
                guard let record = records[p[1]] else { return DemoJSON.response(200, ["code": 404, "message": "DeviceNotFound"]) }
                return DemoJSON.response(200, ["code": 200, "device": json(record, detail: true)])
            case ("DELETE", let p) where p.count == 2 && p[0] == "devices":
                guard records[p[1]] != nil else { return DemoJSON.response(200, ["code": 404, "message": "DeviceNotFound"]) }
                records[p[1]]?.inTrash = true
                records[p[1]]?.managed = false
                return DemoJSON.response(200, ["code": 200, "message": "DeviceDeleted"])
            case ("POST", let p) where p.count == 3 && p[0] == "devices":
                return action(p[2], udid: p[1], body: request.body)
            default:
                return Self.message(404, "NotFound")
            }
        }
    }

    private func list(_ query: [String: String]) -> DemoResponse {
        var matches = records.values.sorted { $0.device.number < $1.device.number }
        if let serial = query["serialnumber"] {
            matches = matches.filter { $0.device.serial == serial.uppercased() }
        }
        if let groups = query["groups"] {
            let wanted = groups.split(separator: ",").map(String.init)
            let numbers = Self.groups.filter { wanted.contains($0.0) }.flatMap { Array($0.2) }
            matches = matches.filter { numbers.contains($0.device.number) }
        }
        return DemoJSON.response(200, ["code": 200, "count": matches.count, "devices": matches.map { json($0, detail: false) }])
    }

    private func json(_ record: Record, detail: Bool) -> [String: Any] {
        let device = record.device
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Brussels")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let checkin = formatter.string(from: now.addingTimeInterval(-Double(device.lastContactDaysAgo) * 86_400 - 3_600))
        var json: [String: Any] = [
            "UDID": device.udid,
            "serialNumber": device.serial,
            "name": device.name,
            "assetTag": record.assetTag,
            "model": ["name": device.model, "identifier": device.modelIdentifier, "type": device.isComputer ? "mac" : "iPad"],
            "os": ["prefix": device.isComputer ? "macOS" : "iPadOS", "version": device.osVersion],
            "class": device.isComputer ? "mac" : "ipad",
            "isManaged": record.managed,
            "isSupervised": true,
            "inTrash": record.inTrash,
            "locationId": record.locationID,
            "groups": Self.groups.filter { $0.2.contains(device.number) }.map(\.0),
            "enrollType": "dep",
            "depProfile": "Contoso Academy",
            "lastCheckin": checkin,
        ]
        if detail {
            json["lastCheckin"] = ["date": checkin, "timezone": "Europe/Brussels"]
            json["hasPasscode"] = true
            json["passcodeCompliant"] = true
            json["isBootstrapStored"] = device.isComputer
        }
        return json
    }

    private func action(_ action: String, udid: String, body: Data) -> DemoResponse {
        guard records[udid] != nil else { return DemoJSON.response(200, ["code": 404, "message": "DeviceNotFound"]) }
        switch action {
        case "details":
            let form = DemoJSON.form(body)
            if let tag = form["assetTag"] { records[udid]?.assetTag = tag }
            return DemoJSON.response(200, ["code": 200, "message": "DeviceDetailsUpdated"])
        case "refresh", "restart", "wipe", "unenroll":
            commandsValue.append((action, udid))
            if action == "unenroll" { records[udid]?.managed = false }
            return DemoJSON.response(200, ["code": 200, "message": "CommandSent"])
        default:
            return Self.message(404, "NotFound")
        }
    }

    private func move(_ body: Data) -> DemoResponse {
        let object = DemoJSON.object(body) ?? [:]
        guard let udids = object["udids"] as? [String], !udids.isEmpty else { return Self.message(400, "UDIDArrayEmpty") }
        let location = (object["locationId"] as? String).flatMap(Int.init) ?? (object["locationId"] as? Int) ?? 0
        guard Self.locations.contains(where: { $0.0 == location }) else { return Self.message(200, "LocationNotFound", code: 404) }
        var moved: [String] = [], notFound: [String] = [], same: [String] = []
        for udid in udids {
            guard let record = records[udid] else { notFound.append(udid); continue }
            if record.locationID == location { same.append(udid); continue }
            records[udid]?.locationID = location
            moved.append(udid)
        }
        return DemoJSON.response(200, ["code": 200, "devicesMoved": moved, "devicesNotFound": notFound,
                                       "devicesLocationSame": same, "devicesMoveFailed": []])
    }

    private static func message(_ status: Int, _ message: String, code: Int? = nil) -> DemoResponse {
        DemoJSON.response(status, ["code": code ?? status, "message": message])
    }
}
