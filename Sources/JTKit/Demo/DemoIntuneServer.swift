import Foundation

/// An in-memory Intune tenant, "Contoso Intune (Demo)", holding `DemoWorld`'s
/// Intune devices: Entra's client-credentials sign-in (on
/// `login.microsoftonline.com`) and Graph v1.0 `managedDevices` (on
/// `graph.microsoft.com`): the list with paging, device actions (answered
/// 204, accepted, as Graph does) and deleting a record.
///
/// The rest of Graph is a general store of the tenant's objects (Settings
/// Catalog, configurations, compliance, scripts, filters, apps, groups and
/// more; `DemoGraphStore`), with app uploads to a fake storage host
/// (`storageHost`). It answers the demo sign-in's token
/// (`DemoMode.microsoftSignIn()`, in place of Microsoft's interactive
/// sign-in) as well as the tokens it issued itself.
///
/// Register it for every host in `DemoIntuneServer.hosts`; the demo network
/// answers them inside the app, so nothing reaches Microsoft.
public nonisolated final class DemoIntuneServer: DemoServer, @unchecked Sendable {
    public static let signInHost = "login.microsoftonline.com"
    public static let graphHost = "graph.microsoft.com"
    /// Where app content is uploaded in demo mode, in place of Azure Storage.
    public static let storageHost = "contoso-storage.\(DemoNetwork.reservedDomain)"
    public static let hosts = [signInHost, graphHost, storageHost]

    /// The demo sign-in's access token: fixed, obviously fake, accepted by
    /// this server only. Never a token from Microsoft.
    public static let delegatedToken = "demo-graph-delegated-token"

    struct Record {
        let device: DemoWorld.Device
        var retired = false
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var tokens: Set<String> = []
    private var actionsValue: [(action: String, id: String)] = []
    private let scenario: DemoScenario?
    private let now: Date
    private let pageSize: Int
    private let store: DemoGraphStore

    /// Actions received: `retire`, `rebootNow`, … and the managed device ID.
    public var actions: [(action: String, id: String)] { lock.withLock { actionsValue } }

    /// - Parameter pageSize: devices per page at most (Graph's is 1,000), to test paging.
    public init(scenario: DemoScenario? = nil, now: Date = Date(), pageSize: Int = 1_000) {
        self.scenario = scenario
        self.now = now
        self.pageSize = max(pageSize, 1)
        store = DemoGraphStore(scenario: scenario, now: now, pageSize: max(pageSize, 1))
        for device in DemoWorld.devices(managedBy: .intune) {
            records[device.intuneID] = Record(device: device)
        }
    }

    /// Whether Intune still holds a record of the device.
    public func hasRecord(serial: String) -> Bool {
        lock.withLock { records.values.contains { $0.device.serial == serial.uppercased() } }
    }

    // MARK: The tenant's objects

    /// Adds an app's own sample objects to a list of the tenant, e.g.
    /// `deviceManagement/deviceConfigurations` (the path without the
    /// version). An object with an ID already there replaces it; one without
    /// gets an ID in the fake range.
    public func add(_ objects: [Data], to path: String) {
        let parsed = objects.compactMap(DemoJSON.object)
        lock.withLock { store.add(parsed, to: path) }
    }

    /// The tenant's objects in a list (the path without the version), as
    /// stored, as JSON.
    public func objects(at path: String) -> [Data] {
        lock.withLock {
            store.objects(at: path).compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        }
    }

    /// Adds Settings Catalog definitions to the tenant's catalog, e.g. the
    /// ones an app's baseline uses. Contoso's catalog has only what its own
    /// policy uses.
    public func add(definitions: [DemoSettingDefinition]) {
        lock.withLock { store.add(definitions) }
    }

    /// The bytes of every upload completed on the storage host.
    public var uploadedBytes: Int { lock.withLock { store.uploadedBytes } }

    /// Requests answered by the general store and the storage host (not the
    /// sign-in or `managedDevices`).
    public var storeRequestCount: Int { lock.withLock { store.requestCount } }

    public func respond(to request: DemoRequest) -> DemoResponse {
        lock.withLock {
            switch request.url.host()?.lowercased() {
            case Self.signInHost: signIn(request)
            case Self.graphHost: graph(request)
            case Self.storageHost: store.storage(request)
            default: Self.error(404, "ResourceNotFound", "No such host in demo mode.")
            }
        }
    }

    private func signIn(_ request: DemoRequest) -> DemoResponse {
        let form = DemoJSON.form(request.body)
        guard request.method == "POST",
              request.pathSegments == [DemoWorld.intuneTenantID, "oauth2", "v2.0", "token"] else {
            return DemoJSON.response(400, ["error": "invalid_tenant",
                                           "error_description": "AADSTS90002: Tenant not found. (demo mode)"])
        }
        guard form["grant_type"] == "client_credentials", form["client_id"] == Connection.demoIntune.clientID,
              !(form["client_secret"] ?? "").isEmpty, form["scope"] == "https://graph.microsoft.com/.default" else {
            return DemoJSON.response(401, ["error": "invalid_client",
                                           "error_description": "AADSTS7000215: Invalid client secret provided. (demo mode)"])
        }
        let token = "demo-graph-token-\(tokens.count + 1)"
        tokens.insert(token)
        return DemoJSON.response(200, ["token_type": "Bearer", "expires_in": 3599, "access_token": token])
    }

    private func graph(_ request: DemoRequest) -> DemoResponse {
        guard let token = DemoJSON.bearer(request), tokens.contains(token) || token == Self.delegatedToken else {
            return Self.error(401, "InvalidAuthenticationToken", "Access token is empty.")
        }
        let path = request.pathSegments
        guard path.count >= 3, path[0] == "v1.0", path[1] == "deviceManagement", path[2] == "managedDevices" else {
            return store.graph(request)
        }
        if scenario == .missingPermission {
            return Self.error(403, "Forbidden", "Application is not authorized to perform this operation.")
        }
        switch (request.method, path.count) {
        case ("GET", 3):
            return list(request)
        case ("DELETE", 4):
            guard records[path[3]] != nil else { return Self.error(404, "ResourceNotFound", "Device not found.") }
            records[path[3]] = nil
            return DemoJSON.empty(204)
        case ("POST", 5):
            guard records[path[3]] != nil else { return Self.error(404, "ResourceNotFound", "Device not found.") }
            let known = ["syncDevice", "rebootNow", "shutDown", "remoteLock", "resetPasscode", "retire", "wipe"]
            guard known.contains(path[4]) else { return Self.error(400, "BadRequest", "Unknown action.") }
            actionsValue.append((path[4], path[3]))
            if path[4] == "retire" { records[path[3]]?.retired = true }
            return DemoJSON.empty(204)
        default:
            return Self.error(405, "MethodNotAllowed", "Not supported in demo mode.")
        }
    }

    private func list(_ request: DemoRequest) -> DemoResponse {
        let top = min(Int(request.query["$top"] ?? "") ?? pageSize, pageSize)
        let skip = Int(request.query["$skiptoken"] ?? "") ?? 0
        let all = records.values.sorted { $0.device.number < $1.device.number }
        let page = all.dropFirst(skip).prefix(top)
        var body: [String: Any] = [
            "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#deviceManagement/managedDevices",
            "value": page.map(json),
        ]
        if skip + top < all.count, request.query["$top"] != "1" {
            var components = URLComponents()
            components.scheme = "https"
            components.host = Self.graphHost
            components.path = "/v1.0/deviceManagement/managedDevices"
            components.queryItems = [URLQueryItem(name: "$top", value: "\(top)"), URLQueryItem(name: "$skiptoken", value: "\(skip + top)")]
            body["@odata.nextLink"] = components.url?.absoluteString
        }
        return DemoJSON.response(200, body)
    }

    private func json(_ record: Record) -> [String: Any] {
        let device = record.device
        return [
            "id": device.intuneID,
            "serialNumber": device.serial,
            "deviceName": device.name,
            "operatingSystem": device.isComputer ? "macOS" : (device.family == .iPad ? "iPadOS" : "iOS"),
            "osVersion": device.osVersion,
            "enrolledDateTime": DemoWorld.iso(daysAgo: 120 + Double(device.number), from: now),
            "lastSyncDateTime": DemoWorld.iso(daysAgo: Double(device.lastContactDaysAgo) + 0.05, from: now),
            "managementCertificateExpirationDate": DemoWorld.iso(daysAgo: -240, from: now),
            "isEncrypted": true,
            "isSupervised": true,
            "managementAgent": record.retired ? "unknown" : "mdm",
            "complianceState": device.number % 4 == 0 ? "noncompliant" : "compliant",
            "deviceEnrollmentType": "appleBulkWithUser",
        ]
    }

    private static func error(_ status: Int, _ code: String, _ message: String) -> DemoResponse {
        DemoGraphStore.error(status, code, message)
    }
}
