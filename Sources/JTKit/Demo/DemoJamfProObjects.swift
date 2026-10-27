import CryptoKit
import Foundation

/// A general in-memory Jamf Pro object store behind a demo Jamf Pro server
/// (`DemoJamfProServer(objects:)`), for an app that copies objects between
/// tenants (JamfMigrator): every object type it reads and writes, on both of
/// Jamf Pro's APIs, from the same objects.
///
/// - **Classic API** (`/JSSResource/…`): lists as JSON (`{"policies": [{id,
///   name}]}`) or XML, details as XML, create with `POST …/id/0` answering
///   `<policy><id>n</id></policy>`, `PUT` merged into the stored object as
///   Jamf does (an icon-only `PUT` keeps the rest of the policy), `DELETE`.
///   A duplicate name is refused with 409 "Duplicate name", a missing object
///   with 404, both as Jamf's HTML pages. A written `<password>` reads back
///   as `<password_sha256>`, as Jamf never returns a password.
/// - **Jamf Pro API** (`/api/…`): lists with `page` / `page-size` and
///   `totalCount`, details, create answering `{"id", "href"}`, `PUT`
///   (replace), `PATCH` (merge-patch), `DELETE`, the settings pages (one
///   object, read and updated), the Jamf Pro version.
/// - Jamf's special cases: PreStages keep a `versionLock` (a `PUT` with an
///   old one is refused with 409 `OPTIMISTIC_LOCK_FAILED`), get a
///   `profileUuid` and their own nested block IDs, and never return the
///   admin or Recovery Lock password; a patch title is created by
///   subscribing through the Classic API and then only accepts
///   `application/merge-patch+json`; patch policies are created under their
///   title; Self Service icons upload and download; ADE instances and the
///   device groups by platform ID (`/api/v2/groups`) are listed.
///
/// What's written stays until the app quits. The `missingPermission`
/// scenario refuses a few types on the store it's given to, with Jamf's 403.
public nonisolated final class DemoJamfProObjects: @unchecked Sendable {

    // MARK: What the store holds

    /// A Classic resource: its list's container, the root element of one
    /// object, and the path component before an ID.
    struct ClassicKind {
        let container: String
        let root: String
        var idPath = "id"
        /// Answered but never written by the app (patch sources).
        var readOnly = false
    }

    static let classicKinds: [String: ClassicKind] = [
        "sites": ClassicKind(container: "sites", root: "site"),
        "networksegments": ClassicKind(container: "network_segments", root: "network_segment"),
        "userextensionattributes": ClassicKind(container: "user_extension_attributes", root: "user_extension_attribute"),
        "ldapservers": ClassicKind(container: "ldap_servers", root: "ldap_server"),
        "users": ClassicKind(container: "users", root: "user"),
        "usergroups": ClassicKind(container: "user_groups", root: "user_group"),
        "directorybindings": ClassicKind(container: "directory_bindings", root: "directory_binding"),
        "softwareupdateservers": ClassicKind(container: "software_update_servers", root: "software_update_server"),
        "advancedcomputersearches": ClassicKind(container: "advanced_computer_searches", root: "advanced_computer_search"),
        "advancedusersearches": ClassicKind(container: "advanced_user_searches", root: "advanced_user_search"),
        "osxconfigurationprofiles": ClassicKind(container: "os_x_configuration_profiles", root: "os_x_configuration_profile"),
        "mobiledeviceconfigurationprofiles": ClassicKind(container: "configuration_profiles", root: "configuration_profile"),
        "macapplications": ClassicKind(container: "mac_applications", root: "mac_application"),
        "mobiledeviceapplications": ClassicKind(container: "mobile_device_applications", root: "mobile_device_application"),
        "ebooks": ClassicKind(container: "ebooks", root: "ebook"),
        "classes": ClassicKind(container: "classes", root: "class"),
        "restrictedsoftware": ClassicKind(container: "restricted_software", root: "restricted_software"),
        "licensedsoftware": ClassicKind(container: "licensed_software", root: "licensed_software"),
        "printers": ClassicKind(container: "printers", root: "printer"),
        "dockitems": ClassicKind(container: "dock_items", root: "dock_item"),
        "policies": ClassicKind(container: "policies", root: "policy"),
        "patchpolicies": ClassicKind(container: "patch_policies", root: "patch_policy"),
        "webhooks": ClassicKind(container: "webhooks", root: "webhook"),
        "patchinternalsources": ClassicKind(container: "patch_internal_sources", root: "patch_internal_source", readOnly: true),
        "patchexternalsources": ClassicKind(container: "patch_external_sources", root: "patch_external_source", readOnly: true),
    ]

    /// A Jamf Pro API list.
    struct ProKind {
        /// The field holding the object's unique name.
        var nameKey = "name"
        /// Listed as a bare array, not a page (patch title configurations).
        var bareArray = false
        /// Answered but never written by the app (ADE instances).
        var readOnly = false
        /// Created only by subscribing through the Classic API (patch titles).
        var createdBySubscription = false
        /// Accepts only `application/merge-patch+json` for PATCH (patch titles).
        var mergePatchOnly = false
        var isPreStage = false
    }

    static let proKinds: [String: ProKind] = [
        "v1/categories": ProKind(),
        "v1/buildings": ProKind(),
        "v1/departments": ProKind(),
        "v1/computer-extension-attributes": ProKind(),
        "v1/mobile-device-extension-attributes": ProKind(),
        "v1/scripts": ProKind(),
        "v1/packages": ProKind(nameKey: "packageName"),
        "v1/distribution-points": ProKind(),
        "v1/accounts": ProKind(nameKey: "username"),
        "v3/computer-groups/smart-groups": ProKind(),
        "v3/computer-groups/static-groups": ProKind(),
        "v2/mobile-device-groups/smart-groups": ProKind(),
        "v2/mobile-device-groups/static-groups": ProKind(),
        "v1/advanced-mobile-device-searches": ProKind(),
        "v3/patch-software-title-configurations": ProKind(nameKey: "displayName", bareArray: true,
                                                          createdBySubscription: true, mergePatchOnly: true),
        "v1/app-installers/deployments": ProKind(),
        "v2/enrollment-customizations": ProKind(nameKey: "displayName"),
        "v3/computer-prestages": ProKind(nameKey: "displayName", isPreStage: true),
        "v3/mobile-device-prestages": ProKind(nameKey: "displayName", isPreStage: true),
        "v1/device-enrollments": ProKind(readOnly: true),
        "v1/volume-purchasing-locations": ProKind(),
        "v1/self-service/branding/macos": ProKind(nameKey: "brandingName"),
    ]

    /// Jamf's App Catalog (`/api/v1/app-installers/titles`): the same on
    /// every tenant, read only.
    static var appInstallerTitles: [[String: Any]] { [
        ("0BC", "Google Chrome", "Google"), ("0C4", "Mozilla Firefox", "Mozilla"),
        ("1D2", "Microsoft Teams", "Microsoft"), ("1F0", "Slack", "Slack Technologies"),
        ("2A7", "Zoom", "Zoom Video Communications"), ("2C1", "1Password", "AgileBits"),
    ].map { ["id": $0.0, "titleName": $0.1, "publisher": $0.2, "bundleId": "", "version": "1.0"] } }

    /// The settings pages: one object each, read and updated, never listed.
    static let settingsPaths: Set<String> = [
        "v3/check-in", "v2/computer-inventory-collection-settings", "v2/smtp-server", "v1/self-service/settings",
        "v1/reenrollment", "v2/local-admin-password/settings", "v1/onboarding", "v3/sso",
    ]

    /// The device group lists behind `/api/v2/groups`, with their platform's name.
    private static let groupLists: [(path: String, type: String, smart: Bool)] = [
        ("v3/computer-groups/smart-groups", "COMPUTER", true), ("v3/computer-groups/static-groups", "COMPUTER", false),
        ("v2/mobile-device-groups/smart-groups", "MOBILE", true), ("v2/mobile-device-groups/static-groups", "MOBILE", false),
    ]

    private let lock = NSLock()
    /// Classic objects by resource, then ID. Accounts are "accounts/users" and "accounts/groups".
    private var classic: [String: [Int: DemoXML]] = [:]
    /// Jamf Pro API objects by list path, then ID.
    private var pro: [String: [Int: [String: Any]]] = [:]
    private var settings: [String: [String: Any]] = [:]
    private var icons: [Int: (name: String, data: Data)] = [:]
    private var nextID = 1000
    private var writeCountValue = 0
    private var requestCountValue = 0
    /// The host answering, for `href` and icon addresses.
    let host: String
    let version: String
    /// Paths refused with 403 (the `missingPermission` scenario), e.g. "JSSResource/webhooks".
    private let refused: Set<String>

    /// Every request answered, sign-ins excluded.
    public var requestCount: Int { lock.withLock { requestCountValue } }
    /// Creates, updates and deletes that succeeded.
    public var writeCount: Int { lock.withLock { writeCountValue } }

    init(host: String, version: String, seed: DemoJamfProObjectSamples.Seed, refusing refused: Set<String> = []) {
        self.host = host
        self.version = version
        self.refused = refused
        for (resource, objects) in seed.classic {
            for (id, xml) in objects {
                guard var node = DemoXML.parse(xml) else { continue }
                Self.storeForm(&node, resource: resource, id: id)
                classic[resource, default: [:]][id] = node
            }
        }
        for (path, objects) in seed.pro {
            for object in objects {
                guard let id = Int("\(object["id"] ?? "")") else { continue }
                pro[path, default: [:]][id] = object
            }
        }
        settings = seed.settings
        for (id, icon) in seed.icons { icons[id] = icon }
    }

    /// The Jamf Pro behind "Contoso (Demo)"'s Platform gateway (`/pro/…` and
    /// `/proclassic/…`): Contoso's objects, with Automated Device Enrollment,
    /// Apps and Books and Self Service branding set up.
    public static func contosoPlatform() -> DemoJamfProObjects {
        var seed = DemoJamfProObjectSamples.source
        seed.pro["v1/volume-purchasing-locations"] = [DemoJamfProObjectSamples.volumePurchasingLocation(id: 1)]
        seed.pro["v1/self-service/branding/macos"] = [DemoJamfProObjectSamples.branding(id: 1)]
        return DemoJamfProObjects(host: DemoSamples.platformHost, version: "11.33.1-t1761000000000", seed: seed)
    }

    /// Contoso's golden master, for "Contoso Source (Demo)".
    public static func contosoSource() -> DemoJamfProObjects {
        DemoJamfProObjects(host: DemoJamfProObjectSamples.sourceHost, version: "11.33.1-t1761000000000",
                           seed: DemoJamfProObjectSamples.source)
    }

    /// A fresh Contoso tenant with Jamf's built-ins and a few objects already
    /// there, for "Contoso Destination (Demo)". The `missingPermission`
    /// scenario refuses its webhooks and single sign-on settings.
    public static func contosoDestination(scenario: DemoScenario? = nil) -> DemoJamfProObjects {
        DemoJamfProObjects(host: DemoJamfProObjectSamples.destinationHost, version: "11.34.0-t1763000000000",
                           seed: DemoJamfProObjectSamples.destination,
                           refusing: scenario == .missingPermission ? ["JSSResource/webhooks", "api/v3/sso"] : [])
    }

    // MARK: An app's own sample objects

    /// Adds Jamf Pro API objects at a list path (e.g. `"v1/app-installers/deployments"`),
    /// an app's own sample data after the ones already there. One whose ID
    /// is already there replaces it in place; one without a numeric ID is skipped.
    public func add(_ objects: [LosslessJSON.Object], at path: String) {
        lock.withLock {
            for object in objects {
                guard let stored = DemoJSON.object(LosslessJSON.object(object).serialized()),
                      let id = Int("\(stored["id"] ?? "")") else { continue }
                pro[path, default: [:]][id] = stored
                nextID = max(nextID, id)
            }
        }
    }

    // MARK: For tests and the app's checks

    /// The names of the objects at a list path as the app requests it, e.g.
    /// `"JSSResource/policies"`, `"JSSResource/accounts/groups"` or
    /// `"api/v1/categories"`, sorted.
    public func names(at path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        return lock.withLock {
            if parts.first == "JSSResource" {
                let resource = parts.dropFirst().joined(separator: "/")
                return (classic[resource] ?? [:]).values.map(\.objectName).sorted()
            }
            let key = parts.dropFirst().joined(separator: "/")
            let nameKey = Self.proKinds[key]?.nameKey ?? "name"
            return (pro[key] ?? [:]).values.map { "\($0[nameKey] ?? "")" }.sorted()
        }
    }

    /// A Classic object's XML as the store holds it, found by name.
    public func classicXML(_ resource: String, named name: String) -> String? {
        lock.withLock { classic[resource]?.values.first { $0.objectName == name }?.xml() }
    }

    /// A Jamf Pro API object as the store holds it, found by name.
    public func proObject(_ path: String, named name: String) -> LosslessJSON? {
        let nameKey = Self.proKinds[path]?.nameKey ?? "name"
        return lock.withLock {
            guard let object = pro[path]?.values.first(where: { "\($0[nameKey] ?? "")" == name }),
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? LosslessJSON(data: data)
        }
    }

    /// A settings page as the store holds it, e.g. `"v3/check-in"`.
    public func settingsPage(_ path: String) -> LosslessJSON? {
        lock.withLock {
            guard let object = settings[path], let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? LosslessJSON(data: data)
        }
    }

    // MARK: Requests

    /// Answers a signed-in request; `parts` are the path's segments.
    func respond(to request: DemoRequest, parts: [String]) -> DemoResponse {
        lock.withLock {
            requestCountValue += 1
            let joined = parts.joined(separator: "/")
            if refused.contains(where: { joined == $0 || joined.hasPrefix($0 + "/") }) {
                return parts.first == "JSSResource" ? Self.classicError(403, "Forbidden", "You do not have access to this resource")
                    : DemoJamfProServer.error(403, "INVALID_PRIVILEGE", "Forbidden: the demo's missingPermission scenario")
            }
            switch parts.first {
            case "JSSResource": return classicRequest(request, Array(parts.dropFirst()))
            case "api": return proRequest(request, Array(parts.dropFirst()))
            default: return DemoJamfProServer.error(404, "NOT_FOUND", "No such resource in demo mode.")
            }
        }
    }

    // MARK: Classic API

    private func classicRequest(_ request: DemoRequest, _ path: [String]) -> DemoResponse {
        guard let resource = path.first else { return Self.classicNotFound() }
        if resource == "accounts" { return accounts(request, Array(path.dropFirst())) }
        if resource == "patchsoftwaretitles", request.method == "POST", path.count == 3, path[1] == "id" {
            return subscribe(request.body)
        }
        guard let kind = Self.classicKinds[resource] else { return Self.classicNotFound() }
        switch (request.method, path.count) {
        case ("GET", 1):
            return classicList(resource, kind: kind, container: kind.container, root: kind.root, request: request)
        case ("GET", 3) where path[1] == kind.idPath:
            guard let id = Int(path[2]), let node = classic[resource]?[id] else { return Self.classicNotFound() }
            return Self.xmlResponse(200, node.xml())
        case ("GET", 3) where path[1] == "name":
            guard let node = classic[resource]?.values.first(where: { $0.objectName == path[2] }) else {
                return Self.classicNotFound()
            }
            return Self.xmlResponse(200, node.xml())
        case ("POST", 3) where path[1] == kind.idPath && !kind.readOnly:
            return classicCreate(resource, root: kind.root, body: request.body)
        case ("POST", 4) where resource == "patchpolicies" && path[1] == "softwaretitleconfig" && path[2] == "id":
            guard let titleID = Int(path[3]), pro["v3/patch-software-title-configurations"]?[titleID] != nil else {
                return Self.classicNotFound()
            }
            return classicCreate(resource, root: kind.root, body: request.body, patchTitleID: titleID)
        case ("PUT", 3) where path[1] == kind.idPath && !kind.readOnly:
            return classicUpdate(resource, root: kind.root, id: Int(path[2]), body: request.body)
        case ("DELETE", 3) where path[1] == kind.idPath && !kind.readOnly:
            return classicDelete(resource, root: kind.root, id: Int(path[2]))
        default:
            return Self.classicError(405, "Method Not Allowed", "The request method is not supported here")
        }
    }

    /// `/JSSResource/accounts`: users (`userid`) and groups (`groupid`) in one list.
    private func accounts(_ request: DemoRequest, _ path: [String]) -> DemoResponse {
        if request.method == "GET", path.isEmpty {
            let users = (pro["v1/accounts"] ?? [:]).sorted { $0.key < $1.key }
                .map { ["id": $0.key, "name": "\($0.value["username"] ?? "")"] as [String: Any] }
            let groups = (classic["accounts/groups"] ?? [:]).sorted { $0.key < $1.key }
                .map { ["id": $0.key, "name": $0.value.objectName] as [String: Any] }
            return DemoJSON.response(200, ["accounts": ["users": users, "groups": groups]])
        }
        guard path.count == 2, path[0] == "groupid" else {
            return Self.classicError(404, "Not Found", "Only account groups are kept in demo mode")
        }
        let resource = "accounts/groups"
        switch request.method {
        case "GET":
            guard let id = Int(path[1]), let node = classic[resource]?[id] else { return Self.classicNotFound() }
            return Self.xmlResponse(200, node.xml())
        case "POST": return classicCreate(resource, root: "group", body: request.body)
        case "PUT": return classicUpdate(resource, root: "group", id: Int(path[1]), body: request.body)
        case "DELETE": return classicDelete(resource, root: "group", id: Int(path[1]))
        default: return Self.classicError(405, "Method Not Allowed", "The request method is not supported here")
        }
    }

    private func classicList(_ resource: String, kind: ClassicKind, container: String, root: String,
                             request: DemoRequest) -> DemoResponse {
        let objects = (classic[resource] ?? [:]).sorted { $0.key < $1.key }
        let accept = DemoJSON.header("Accept", in: request) ?? ""
        if accept.contains("json") {
            let entries = objects.map { ["id": $0.key, "name": $0.value.objectName] as [String: Any] }
            return DemoJSON.response(200, [container: entries])
        }
        var list = DemoXML(name: container, children: [DemoXML(name: "size", text: "\(objects.count)")])
        for (id, node) in objects {
            list.children.append(DemoXML(name: root, children: [DemoXML(name: "id", text: "\(id)"),
                                                                DemoXML(name: "name", text: node.objectName)]))
        }
        return Self.xmlResponse(200, list.xml())
    }

    private func classicCreate(_ resource: String, root: String, body: Data, patchTitleID: Int? = nil) -> DemoResponse {
        guard var node = DemoXML.parse(String(decoding: body, as: UTF8.self)) else {
            return Self.classicError(400, "Bad Request", "Unable to parse XML")
        }
        let name = node.objectName
        guard !name.isEmpty else { return Self.classicError(409, "Conflict", "Error: Name is required") }
        if (classic[resource] ?? [:]).values.contains(where: { $0.objectName == name }) {
            return Self.classicError(409, "Conflict", "Error: Duplicate name")
        }
        let id = newID()
        node.name = root
        if let patchTitleID {
            node.set("software_title_configuration_id", to: "\(patchTitleID)", in: "general")
        }
        Self.storeForm(&node, resource: resource, id: id)
        classic[resource, default: [:]][id] = node
        writeCountValue += 1
        return Self.created(root: root, id: id)
    }

    private func classicUpdate(_ resource: String, root: String, id: Int?, body: Data) -> DemoResponse {
        guard let id, var stored = classic[resource]?[id] else { return Self.classicNotFound() }
        guard let change = DemoXML.parse(String(decoding: body, as: UTF8.self)) else {
            return Self.classicError(400, "Bad Request", "Unable to parse XML")
        }
        stored.merge(change)
        let name = stored.objectName
        if (classic[resource] ?? [:]).contains(where: { $0.key != id && $0.value.objectName == name }) {
            return Self.classicError(409, "Conflict", "Error: Duplicate name")
        }
        Self.storeForm(&stored, resource: resource, id: id)
        classic[resource]?[id] = stored
        writeCountValue += 1
        return Self.created(root: root, id: id)
    }

    private func classicDelete(_ resource: String, root: String, id: Int?) -> DemoResponse {
        guard let id, classic[resource]?[id] != nil else { return Self.classicNotFound() }
        classic[resource]?[id] = nil
        writeCountValue += 1
        return Self.xmlResponse(200, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><\(root)><id>\(id)</id></\(root)>")
    }

    /// `POST /JSSResource/patchsoftwaretitles/id/0`: subscribes to a title of
    /// a patch source, which creates its patch title configuration.
    private func subscribe(_ body: Data) -> DemoResponse {
        guard let node = DemoXML.parse(String(decoding: body, as: UTF8.self)) else {
            return Self.classicError(400, "Bad Request", "Unable to parse XML")
        }
        let nameID = node.child("name_id")?.text ?? ""
        let sourceID = Int(node.child("source_id")?.text ?? "") ?? -1
        let source = (classic["patchinternalsources"]?[sourceID] ?? classic["patchexternalsources"]?[sourceID])?.objectName
        guard let source, !nameID.isEmpty else {
            return Self.classicError(409, "Conflict", "Error: Problem with patch source")
        }
        let titles = pro["v3/patch-software-title-configurations"] ?? [:]
        if titles.values.contains(where: { "\($0["softwareTitleNameId"] ?? "")" == nameID }) {
            return Self.classicError(409, "Conflict", "Error: Duplicate name")
        }
        let id = newID()
        let name = node.child("name")?.text ?? nameID
        pro["v3/patch-software-title-configurations", default: [:]][id] = [
            "id": "\(id)", "displayName": name, "softwareTitleId": "\(id)", "softwareTitleNameId": nameID,
            "softwareTitleName": name, "patchSourceName": source, "patchSourceEnabled": true, "jamfOfficial": true,
            "categoryId": "-1", "siteId": "-1", "uiNotifications": false, "emailNotifications": false,
            "extensionAttributes": [] as [Any], "packages": [] as [Any],
        ]
        writeCountValue += 1
        return Self.created(root: "patch_software_title", id: id)
    }

    /// What Jamf stores for a written object: its ID where Jamf shows it,
    /// and a hash in place of any password.
    private static func storeForm(_ node: inout DemoXML, resource: String, id: Int) {
        node.setID(id)
        node.hidePasswords()
    }

    private static func created(root: String, id: Int) -> DemoResponse {
        xmlResponse(201, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><\(root)><id>\(id)</id></\(root)>")
    }

    static func xmlResponse(_ status: Int, _ xml: String) -> DemoResponse {
        DemoResponse(status: status, headers: ["Content-Type": "application/xml;charset=UTF-8"], body: Data(xml.utf8))
    }

    /// Jamf's Classic error page.
    static func classicError(_ status: Int, _ title: String, _ message: String) -> DemoResponse {
        let html = "<html><head><title>Status page</title></head><body><p>\(title)</p><p>\(message)</p></body></html>"
        return DemoResponse(status: status, headers: ["Content-Type": "text/html;charset=UTF-8"], body: Data(html.utf8))
    }

    private static func classicNotFound() -> DemoResponse {
        classicError(404, "Not Found", "The server has not found anything matching the request URI")
    }

    // MARK: Jamf Pro API

    private func proRequest(_ request: DemoRequest, _ path: [String]) -> DemoResponse {
        let key = path.joined(separator: "/")
        let method = request.method
        if method == "GET", key == "v1/jamf-pro-version" {
            return DemoJSON.response(200, ["version": version])
        }
        if Self.settingsPaths.contains(key) { return settingsRequest(request, key) }
        if key == "v1/icon", method == "POST" { return uploadIcon(request) }
        if path.count == 4, path[0] == "v1", path[1] == "icon", path[2] == "download", method == "GET" {
            guard let id = Int(path[3]), let icon = icons[id] else { return Self.proNotFound() }
            return DemoResponse(status: 200, headers: ["Content-Type": "image/png"], body: icon.data)
        }
        if key == "v2/groups", method == "GET" { return page(platformGroups(), request) }
        if let answer = setupRequest(request, key) { return answer }
        if let kind = Self.proKinds[key] {
            switch method {
            case "GET":
                let objects = (pro[key] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
                return kind.bareArray ? DemoJSON.response(200, objects) : page(objects, request)
            case "POST" where !kind.readOnly && !kind.createdBySubscription:
                return proCreate(key, kind: kind, body: request.body)
            default:
                return DemoJamfProServer.error(405, "METHOD_NOT_ALLOWED", "Method not allowed")
            }
        }
        let listKey = path.dropLast().joined(separator: "/")
        guard let kind = Self.proKinds[listKey], let id = path.last.flatMap({ Int($0) }) else { return Self.proNotFound() }
        guard pro[listKey]?[id] != nil else { return Self.proNotFound() }
        switch method {
        case "GET":
            return DemoJSON.response(200, pro[listKey]?[id] ?? [:])
        case "PUT" where !kind.readOnly && !kind.mergePatchOnly:
            return proUpdate(listKey, kind: kind, id: id, body: request.body, merge: false)
        case "PATCH" where !kind.readOnly:
            let type = DemoJSON.header("Content-Type", in: request) ?? ""
            if kind.mergePatchOnly, !type.contains("merge-patch+json") {
                return DemoJamfProServer.error(415, "UNSUPPORTED_MEDIA_TYPE", "Content type '\(type)' not supported")
            }
            return proUpdate(listKey, kind: kind, id: id, body: request.body, merge: true)
        case "DELETE" where !kind.readOnly:
            pro[listKey]?[id] = nil
            writeCountValue += 1
            return DemoJSON.empty(204)
        default:
            return DemoJamfProServer.error(405, "METHOD_NOT_ALLOWED", "Method not allowed")
        }
    }

    private func proCreate(_ key: String, kind: ProKind, body: Data) -> DemoResponse {
        guard var object = DemoJSON.object(body) else {
            return DemoJamfProServer.error(400, "INVALID_FIELD", "The body is not valid JSON.")
        }
        let name = "\(object[kind.nameKey] ?? "")"
        guard !name.isEmpty else { return DemoJamfProServer.error(400, "INVALID_FIELD", "must not be blank", field: kind.nameKey) }
        if (pro[key] ?? [:]).values.contains(where: { "\($0[kind.nameKey] ?? "")" == name }) {
            return DemoJamfProServer.error(400, "DUPLICATE_FIELD", "\(kind.nameKey) must be unique", field: kind.nameKey)
        }
        let id = newID()
        object["id"] = "\(id)"
        if kind.isPreStage { Self.createPreStage(&object, id: id) }
        if key == "v1/volume-purchasing-locations" {
            // Jamf reads the token and never returns it; Apple's details come back instead.
            object["serviceToken"] = nil
            object.merge(DemoJamfProObjectSamples.volumePurchasingLocation(id: id, name: name)) { stored, _ in stored }
        }
        pro[key, default: [:]][id] = object
        writeCountValue += 1
        return DemoJSON.response(201, ["id": "\(id)", "href": "https://\(host)/api/\(key)/\(id)"])
    }

    private func proUpdate(_ key: String, kind: ProKind, id: Int, body: Data, merge: Bool) -> DemoResponse {
        guard let stored = pro[key]?[id], let change = DemoJSON.object(body) else {
            return DemoJamfProServer.error(400, "INVALID_FIELD", "The body is not valid JSON.")
        }
        var object = merge ? Self.mergePatch(stored, change) : change
        object["id"] = "\(id)"
        if kind.isPreStage {
            let sent = (change["versionLock"] as? Int) ?? -1
            guard sent == (stored["versionLock"] as? Int ?? 0) else {
                return DemoJamfProServer.error(409, "OPTIMISTIC_LOCK_FAILED", "Optimistic lock failed", field: "versionLock")
            }
            Self.updatePreStage(&object, stored: stored)
        }
        let name = "\(object[kind.nameKey] ?? "")"
        if (pro[key] ?? [:]).contains(where: { $0.key != id && "\($0.value[kind.nameKey] ?? "")" == name }) {
            return DemoJamfProServer.error(400, "DUPLICATE_FIELD", "\(kind.nameKey) must be unique", field: kind.nameKey)
        }
        pro[key]?[id] = object
        writeCountValue += 1
        return DemoJSON.response(200, object)
    }

    private func settingsRequest(_ request: DemoRequest, _ key: String) -> DemoResponse {
        switch request.method {
        case "GET":
            return DemoJSON.response(200, settings[key] ?? [:])
        case "PUT", "PATCH":
            guard let change = DemoJSON.object(request.body) else {
                return DemoJamfProServer.error(400, "INVALID_FIELD", "The body is not valid JSON.")
            }
            let object = request.method == "PATCH" ? Self.mergePatch(settings[key] ?? [:], change) : change
            // secrets are written but never read back
            settings[key] = Self.withoutSecrets(object)
            writeCountValue += 1
            return DemoJSON.response(200, settings[key] ?? [:])
        default:
            return DemoJamfProServer.error(405, "METHOD_NOT_ALLOWED", "Method not allowed")
        }
    }

    /// A tenant's setup pages, as a deployment tool reads and writes them:
    /// the server address, the App Catalog, the group lists, Automated Device
    /// Enrollment's key and token upload, and the Jamf Protect link. Nil for
    /// any other path.
    private func setupRequest(_ request: DemoRequest, _ key: String) -> DemoResponse? {
        switch (request.method, key) {
        case ("GET", "v1/jamf-pro-server-url"):
            return DemoJSON.response(200, ["url": "https://\(host)", "unsecuredEnrollmentUrl": ""])
        case ("GET", "v1/app-installers/titles"):
            return page(Self.appInstallerTitles, request)
        case ("GET", "v1/computer-groups"):
            return DemoJSON.response(200, groups(["v3/computer-groups/smart-groups", "v3/computer-groups/static-groups"])
                .map { ["id": "\($0.id)", "name": $0.name, "smartGroup": $0.smart] })
        case ("GET", "v1/mobile-device-groups"):
            return DemoJSON.response(200, groups(["v2/mobile-device-groups/smart-groups", "v2/mobile-device-groups/static-groups"])
                .map { ["id": $0.id, "name": $0.name, "isSmartGroup": $0.smart] })
        case ("GET", "v1/device-enrollments/public-key"):
            return DemoResponse(status: 200, headers: ["Content-Type": "application/x-pem-file"],
                                body: Data(DemoJamfProObjectSamples.adePublicKey.utf8))
        case ("POST", "v1/device-enrollments/upload-token"):
            guard let body = DemoJSON.object(request.body), !"\(body["encodedToken"] ?? "")".isEmpty else {
                return DemoJamfProServer.error(400, "INVALID_FIELD", "encodedToken must not be blank", field: "encodedToken")
            }
            let id = newID()
            let file = "\(body["tokenFileName"] ?? "")"
            let name = file.hasSuffix(".p7m") ? String(file.dropLast(4)) : file
            // the token itself is never kept, as Jamf never returns it
            pro["v1/device-enrollments", default: [:]][id] = [
                "id": "\(id)", "name": name.isEmpty ? "Contoso ABM" : name, "supervisionIdentityId": "-1", "siteId": "-1",
                "serverName": "Contoso Jamf Pro", "serverUuid": DemoSamples.uuid(0x7300 + id % 0x100),
                "tokenExpirationDate": DemoJamfProObjectSamples.inAYear(),
            ]
            writeCountValue += 1
            return DemoJSON.response(201, ["id": "\(id)", "href": "https://\(host)/api/v1/device-enrollments/\(id)"])
        case ("GET", "v1/jamf-protect"):
            return DemoJSON.response(200, settings[key] ?? ["autoInstall": false, "syncStatus": "NOT_REGISTERED"])
        case ("POST", "v1/jamf-protect/register"):
            guard let body = DemoJSON.object(request.body), let url = body["protectUrl"] as? String, !url.isEmpty else {
                return DemoJamfProServer.error(400, "INVALID_FIELD", "protectUrl must not be blank", field: "protectUrl")
            }
            // the password is used once and never kept
            settings["v1/jamf-protect"] = [
                "id": "1", "apiClientId": "\(body["clientId"] ?? "")", "apiClientName": "Jamf Pro",
                "registrationId": DemoSamples.uuid(0x7400), "protectUrl": url,
                "lastSyncTime": DemoJamfProObjectSamples.now(), "syncStatus": "COMPLETED", "autoInstall": true,
            ]
            writeCountValue += 1
            return DemoJSON.response(201, settings["v1/jamf-protect"] ?? [:])
        default:
            return nil
        }
    }

    /// The groups in `lists`, in ID order, with whether they're smart.
    private func groups(_ lists: [String]) -> [(id: Int, name: String, smart: Bool)] {
        lists.flatMap { list in
            (pro[list] ?? [:]).map { (id: $0.key, name: "\($0.value["name"] ?? "")", smart: list.hasSuffix("smart-groups")) }
        }.sorted { $0.id < $1.id }
    }

    private func uploadIcon(_ request: DemoRequest) -> DemoResponse {
        let text = String(decoding: request.body, as: UTF8.self)
        guard text.contains("name=\"file\"") else {
            return DemoJamfProServer.error(400, "INVALID_FIELD", "A file is required", field: "file")
        }
        let name = text.range(of: "filename=\"").flatMap { start in
            text[start.upperBound...].firstIndex(of: "\"").map { String(text[start.upperBound..<$0]) }
        } ?? "icon.png"
        let id = newID()
        icons[id] = (name, request.body)
        writeCountValue += 1
        return DemoJSON.response(201, ["id": id, "name": name, "url": "https://\(host)/icon?id=\(id)"])
    }

    /// Every device group as the Platform namespaces see it: `groupPlatformId`.
    private func platformGroups() -> [[String: Any]] {
        Self.groupLists.flatMap { list in
            (pro[list.path] ?? [:]).sorted { $0.key < $1.key }.map { id, group -> [String: Any] in
                let offset = list.type == "COMPUTER" ? 0x7100 : 0x7200
                return ["groupPlatformId": DemoSamples.uuid(offset + (list.smart ? 0 : 0x80) + id % 0x80),
                        "groupJamfProId": "\(id)", "groupName": "\(group["name"] ?? "")",
                        "groupType": list.type, "smart": list.smart]
            }
        }
    }

    /// A new PreStage: its profile UUID, version lock 0 and nested block IDs
    /// of its own, without the passwords Jamf never returns.
    private static func createPreStage(_ object: inout [String: Any], id: Int) {
        object["versionLock"] = 0
        object["profileUuid"] = DemoSamples.uuid(0x8000 + id % 0x1000)
        object["recoveryLockPassword"] = nil
        for block in ["locationInformation", "purchasingInformation", "accountSettings"] {
            guard var nested = object[block] as? [String: Any] else { continue }
            nested["id"] = "\(id)"
            nested["versionLock"] = 0
            nested["adminPassword"] = nil
            object[block] = nested
        }
    }

    /// An updated PreStage: version locks move on, its profile UUID and
    /// nested IDs stay.
    private static func updatePreStage(_ object: inout [String: Any], stored: [String: Any]) {
        object["versionLock"] = (stored["versionLock"] as? Int ?? 0) + 1
        object["profileUuid"] = stored["profileUuid"]
        object["recoveryLockPassword"] = nil
        for block in ["locationInformation", "purchasingInformation", "accountSettings"] {
            guard var nested = object[block] as? [String: Any] else { continue }
            let old = stored[block] as? [String: Any] ?? [:]
            nested["id"] = old["id"] ?? nested["id"]
            nested["versionLock"] = (old["versionLock"] as? Int ?? 0) + 1
            nested["adminPassword"] = nil
            object[block] = nested
        }
    }

    /// JSON merge-patch (RFC 7396): objects merge, `null` removes, anything else replaces.
    static func mergePatch(_ target: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var result = target
        for (key, value) in patch {
            if value is NSNull {
                result[key] = nil
            } else if let nested = value as? [String: Any] {
                result[key] = mergePatch(result[key] as? [String: Any] ?? [:], nested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Settings pages never return their passwords.
    private static func withoutSecrets(_ object: [String: Any]) -> [String: Any] {
        var result = [String: Any]()
        for (key, value) in object where !key.lowercased().hasSuffix("password") {
            result[key] = (value as? [String: Any]).map(withoutSecrets) ?? value
        }
        return result
    }

    private func page(_ items: [[String: Any]], _ request: DemoRequest) -> DemoResponse {
        let size = max(Int(request.query["page-size"] ?? "") ?? 100, 1)
        let index = max(Int(request.query["page"] ?? "") ?? 0, 0)
        let slice = items.dropFirst(index * size).prefix(size)
        return DemoJSON.response(200, ["totalCount": items.count, "results": Array(slice)])
    }

    private static func proNotFound() -> DemoResponse {
        DemoJamfProServer.error(404, "NOT_FOUND", "Not found")
    }

    private func newID() -> Int {
        nextID += 1
        return nextID
    }
}

// MARK: - XML

/// A small XML tree for the Classic store: elements in order, their text and
/// attributes. Parsed and written back as Jamf does, so a payload reads back
/// as it was written.
nonisolated struct DemoXML {
    var name: String
    var attributes: [(String, String)] = []
    var text = ""
    var children: [DemoXML] = []

    init(name: String, text: String = "", children: [DemoXML] = []) {
        self.name = name
        self.text = text
        self.children = children
    }

    static func parse(_ xml: String) -> DemoXML? {
        let builder = Builder()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    func child(_ name: String) -> DemoXML? {
        children.first { $0.name == name }
    }

    /// The object's name: in `<general>` or `<connection>` (LDAP servers) when it has one.
    var objectName: String {
        for block in ["general", "connection"] {
            if let name = child(block)?.child("name")?.text { return name }
        }
        return child("name")?.text ?? ""
    }

    /// Sets the object's ID where Jamf shows it: first in `<general>` or
    /// `<connection>`, else first in the object.
    mutating func setID(_ id: Int) {
        for block in ["general", "connection"] {
            if let index = children.firstIndex(where: { $0.name == block }) {
                children[index].setOwnID(id)
                return
            }
        }
        setOwnID(id)
    }

    private mutating func setOwnID(_ id: Int) {
        children.removeAll { $0.name == "id" }
        children.insert(DemoXML(name: "id", text: "\(id)"), at: 0)
    }

    /// Sets `<tag>` inside `<block>` (or the object, without one) to `value`.
    mutating func set(_ tag: String, to value: String, in block: String) {
        if let index = children.firstIndex(where: { $0.name == block }) {
            children[index].children.removeAll { $0.name == tag }
            children[index].children.append(DemoXML(name: tag, text: value))
        } else {
            children.removeAll { $0.name == tag }
            children.append(DemoXML(name: tag, text: value))
        }
    }

    /// Every written `<password>` becomes the `<password_sha256>` Jamf returns.
    mutating func hidePasswords() {
        if name == "password", children.isEmpty, !text.isEmpty {
            name = "password_sha256"
            attributes = [("since", "9.23")]
            text = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        for index in children.indices { children[index].hidePasswords() }
    }

    /// A Classic PUT: each element sent replaces the stored one of that name;
    /// blocks whose elements all have different names merge element by
    /// element (an icon-only PUT keeps the rest of `<self_service>`), lists
    /// (`<scripts>` with several `<script>`) are replaced whole.
    mutating func merge(_ change: DemoXML) {
        for element in change.children {
            if let index = children.firstIndex(where: { $0.name == element.name }) {
                if !element.children.isEmpty, element.hasDistinctChildren, children[index].hasDistinctChildren,
                   !children[index].children.isEmpty {
                    children[index].merge(element)
                } else {
                    children[index] = element
                }
            } else {
                children.append(element)
            }
        }
    }

    private var hasDistinctChildren: Bool {
        Set(children.map(\.name)).count == children.count
    }

    func xml(declaration: Bool = true) -> String {
        (declaration ? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" : "") + element()
    }

    private func element() -> String {
        let attrs = attributes.map { " \($0.0)=\"\(Self.escape($0.1))\"" }.joined()
        if children.isEmpty {
            return text.isEmpty ? "<\(name)\(attrs)/>" : "<\(name)\(attrs)>\(Self.escape(text))</\(name)>"
        }
        return "<\(name)\(attrs)>" + children.map { $0.element() }.joined() + "</\(name)>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private nonisolated final class Builder: NSObject, XMLParserDelegate {
        var stack: [DemoXML] = []
        var root: DemoXML?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            var node = DemoXML(name: elementName)
            node.attributes = attributes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            guard var node = stack.popLast() else { return }
            if !node.children.isEmpty || node.text.allSatisfy(\.isWhitespace) { node.text = "" }
            if stack.isEmpty {
                root = node
            } else {
                stack[stack.count - 1].children.append(node)
            }
        }
    }
}
