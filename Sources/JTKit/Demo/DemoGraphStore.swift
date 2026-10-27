import Foundation

/// A Contoso Intune tenant's objects, in memory, as Microsoft Graph keeps
/// them: the general store behind `DemoIntuneServer` for Intune Deployer
/// (ROADMAP step 10). Lists with paging, `$filter`, `$select` and `$expand`;
/// create, update (PATCH and PUT), delete; `/assign`, compliance rules,
/// Settings Catalog settings and definitions; groups, `me`, the organization
/// and its Apple tokens; and app uploads to a fake storage host
/// (`DemoIntuneServer.storageHost`).
///
/// What Graph does that a client has to cope with is kept: v1.0 and beta show
/// the same objects but beta-only lists refuse v1.0; script lists leave out
/// `scriptContent`; a Settings Catalog policy's settings are their own list;
/// compliance rules come only with `$expand`; an upload's states move on when
/// they are read, so nothing has to wait. Not thread-safe on its own: the
/// server calls it under its lock.
nonisolated final class DemoGraphStore {
    typealias Object = [String: Any]

    private struct Entry {
        var id: String
        var object: Object
    }

    /// Lists by path, without the version and without type casts
    /// (`deviceAppManagement/mobileApps/{id}/contentVersions`).
    private var lists: [String: [Entry]] = [:]
    private var definitions: [String: DemoSettingDefinition] = [:]
    /// Blocks received by the storage host, per file, and the committed blobs.
    private var blocks: [String: [String: Int]] = [:]
    private var blobs: [String: Int] = [:]
    private var nextNumber = 0x6000
    private let scenario: DemoScenario?
    private let now: Date
    let pageSize: Int

    private(set) var requestCount = 0

    /// Lists every tenant has, empty or not.
    static let knownLists: Set<String> = [
        "deviceManagement/configurationPolicies",
        "deviceManagement/deviceConfigurations",
        "deviceManagement/deviceCompliancePolicies",
        "deviceManagement/deviceShellScripts",
        "deviceManagement/deviceCustomAttributeShellScripts",
        "deviceManagement/assignmentFilters",
        "deviceManagement/depOnboardingSettings",
        "deviceManagement/configurationSettings",
        "deviceAppManagement/mobileApps",
        "groups",
        "organization",
    ]

    /// Lists Graph has only in beta: v1.0 answers 400, as Graph does.
    static let betaOnly: Set<String> = [
        "deviceManagement/configurationPolicies",
        "deviceManagement/deviceShellScripts",
        "deviceManagement/deviceCustomAttributeShellScripts",
        "deviceManagement/assignmentFilters",
        "deviceManagement/depOnboardingSettings",
        "deviceManagement/configurationSettings",
    ]

    init(scenario: DemoScenario?, now: Date, pageSize: Int) {
        self.scenario = scenario
        self.now = now
        self.pageSize = pageSize
        seed()
    }

    // MARK: - For the server's public API

    func add(_ objects: [Object], to path: String) {
        let key = Self.key(path.split(separator: "/").map(String.init))
        for var object in objects {
            let id = object["id"] as? String ?? newID()
            object["id"] = id
            if let index = lists[key]?.firstIndex(where: { $0.id == id }) {
                lists[key]?[index].object = object
            } else {
                lists[key, default: []].append(Entry(id: id, object: object))
            }
        }
    }

    func objects(at path: String) -> [Object] {
        lists[Self.key(path.split(separator: "/").map(String.init))]?.map(\.object) ?? []
    }

    func add(_ newDefinitions: [DemoSettingDefinition]) {
        for definition in newDefinitions { definitions[definition.id] = definition }
    }

    var uploadedBytes: Int { blobs.values.reduce(0, +) }

    // MARK: - Graph

    func graph(_ request: DemoRequest) -> DemoResponse {
        requestCount += 1
        guard let version = request.pathSegments.first, version == "v1.0" || version == "beta" else {
            return Self.error(400, "BadRequest", "Invalid version.")
        }
        let segments = Array(request.pathSegments.dropFirst())
        let key = Self.key(segments)
        let top = Self.topList(of: key)
        if version == "v1.0", let top, Self.betaOnly.contains(top) {
            let segment = top.split(separator: "/").last.map(String.init) ?? top
            return Self.error(400, "BadRequest", "Resource not found for the segment '\(segment)'.")
        }
        if scenario == .missingPermission, request.method != "GET" {
            return refusedWrite(key)
        }
        switch request.method {
        case "GET": return get(key, request)
        case "POST": return post(key, request)
        case "PATCH": return patch(key, request)
        case "PUT": return put(key, request)
        case "DELETE": return delete(key)
        default: return Self.error(405, "MethodNotAllowed", "Not supported in demo mode.")
        }
    }

    /// Graph's own 403 for a write the signed-in account's token isn't
    /// allowed: Entra's wording for groups, Intune's for the rest.
    private func refusedWrite(_ key: String) -> DemoResponse {
        if key.hasPrefix("groups") {
            return Self.error(403, "Authorization_RequestDenied", "Insufficient privileges to complete the operation.")
        }
        let scope = key.hasPrefix("deviceAppManagement") ? "DeviceManagementApps.ReadWrite.All"
            : key.contains("Script") ? "DeviceManagementScripts.ReadWrite.All"
            : "DeviceManagementConfiguration.ReadWrite.All"
        return Self.error(403, "Forbidden",
                          "Application is not authorized to perform this operation. Application must have one of the following scopes: \(scope)")
    }

    // MARK: GET

    private func get(_ key: String, _ request: DemoRequest) -> DemoResponse {
        switch key {
        case "me":
            return DemoJSON.response(200, select(me, request))
        case "deviceManagement/applePushNotificationCertificate":
            return DemoJSON.response(200, select(apnsCertificate, request))
        case "deviceManagement/configurationSettings":
            let all = definitions.values.sorted { $0.id < $1.id }.map(\.json)
            return list(all, key: key, request)
        default:
            break
        }
        if key.hasPrefix("deviceManagement/configurationSettings/") {
            let id = String(key.dropFirst("deviceManagement/configurationSettings/".count))
            guard let definition = definitions[id] else { return Self.notFound() }
            return DemoJSON.response(200, select(definition.json, request))
        }
        if isList(key) {
            if key.hasSuffix("/files") || key.hasSuffix("/contentVersions") { advanceUploads(in: key) }
            return list((lists[key] ?? []).map(\.object), key: key, request)
        }
        guard var object = item(key) else { return Self.notFound() }
        if key.contains("/files/") {
            advanceUpload(key)
            object = item(key) ?? object
        }
        return DemoJSON.response(200, shown(object, key: Self.parent(of: key), request: request, inList: false))
    }

    private func list(_ objects: [Object], key: String, _ request: DemoRequest) -> DemoResponse {
        var matching = objects
        if let filter = request.query["$filter"], !filter.isEmpty {
            // the catalog's platform filter is the service's business; the
            // demo catalog holds only what an app adds
            if key != "deviceManagement/configurationSettings" {
                guard let predicate = Self.predicate(filter) else {
                    return Self.error(400, "BadRequest", "Invalid filter clause: \(filter)")
                }
                matching = matching.filter(predicate)
            }
        }
        let top = min(Int(request.query["$top"] ?? "") ?? pageSize, pageSize)
        let skip = Int(request.query["$skiptoken"] ?? "") ?? 0
        let page = matching.dropFirst(skip).prefix(max(top, 1))
        var body: Object = [
            "@odata.context": "https://\(DemoIntuneServer.graphHost)/\(request.pathSegments[0])/$metadata#\(key)",
            "value": page.map { shown($0, key: key, request: request, inList: true) },
        ]
        if skip + page.count < matching.count {
            var components = URLComponents()
            components.scheme = "https"
            components.host = DemoIntuneServer.graphHost
            components.path = request.url.path(percentEncoded: false)
            var items = request.query.filter { $0.key != "$skiptoken" && $0.key != "$top" }
                .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            items.append(URLQueryItem(name: "$top", value: "\(top)"))
            items.append(URLQueryItem(name: "$skiptoken", value: "\(skip + page.count)"))
            components.queryItems = items
            body["@odata.nextLink"] = components.url?.absoluteString
        }
        return DemoJSON.response(200, body)
    }

    /// An object as Graph shows it: hidden parts only on request.
    private func shown(_ object: Object, key: String, request: DemoRequest, inList: Bool) -> Object {
        var shown = object
        let expand = request.query["$expand"] ?? ""
        if !expand.contains("scheduledActionsForRule") { shown["scheduledActionsForRule"] = nil }
        if inList, key.hasSuffix("ShellScripts") { shown["scriptContent"] = nil }
        if expand.contains("assignments"), let id = object["id"] as? String {
            shown["assignments"] = (lists["\(key)/\(id)/assignments"] ?? []).map(\.object)
        }
        return select(shown, request)
    }

    private func select(_ object: Object, _ request: DemoRequest) -> Object {
        guard let select = request.query["$select"], !select.isEmpty else { return object }
        let wanted = Set(select.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            .union(["id", "@odata.type"])
        return object.filter { wanted.contains($0.key) }
    }

    /// `name eq 'value'` (Graph compares case-insensitively), joined by `and`.
    private static func predicate(_ filter: String) -> ((Object) -> Bool)? {
        var clauses: [(String, String)] = []
        for part in filter.components(separatedBy: " and ") {
            let pieces = part.trimmingCharacters(in: .whitespaces).components(separatedBy: " eq ")
            guard pieces.count == 2 else { return nil }
            var value = pieces[1].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 else { return nil }
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            clauses.append((pieces[0].trimmingCharacters(in: .whitespaces), value))
        }
        return { object in
            clauses.allSatisfy { name, value in
                (object[name] as? String)?.caseInsensitiveCompare(value) == .orderedSame
            }
        }
    }

    // MARK: POST

    private static let actions: Set<String> = ["assign", "scheduleActionsForRules", "commit", "renewUpload"]

    private func post(_ key: String, _ request: DemoRequest) -> DemoResponse {
        guard let body = DemoJSON.object(request.body) ?? (request.body.isEmpty ? [:] : nil) else {
            return Self.error(400, "BadRequest", "The request body isn't valid JSON.")
        }
        let action = key.split(separator: "/").last.map(String.init) ?? ""
        if Self.actions.contains(action) {
            let target = Self.parent(of: key)
            guard item(target) != nil else { return Self.notFound() }
            return perform(action, on: target, body: body)
        }
        guard isList(key) || item(Self.parent(of: key)) != nil else { return Self.notFound() }
        return DemoJSON.response(201, create(body, in: key))
    }

    private func create(_ body: Object, in key: String) -> Object {
        var object = body
        let id = key.hasSuffix("/contentVersions") ? "\((lists[key]?.count ?? 0) + 1)" : newID()
        object["id"] = id
        let stamp = DemoWorld.iso(daysAgo: 0, from: now)
        if !key.contains("/contentVersions") {
            object["createdDateTime"] = stamp
            object["lastModifiedDateTime"] = stamp
        }
        switch key {
        case "deviceManagement/configurationPolicies":
            object["settingCount"] = storeSettings(&object, policy: "\(key)/\(id)")
        case "deviceAppManagement/mobileApps":
            object["publishingState"] = object["publishingState"] ?? "notPublished"
        case "groups":
            object["groupTypes"] = object["groupTypes"] ?? []
        default:
            if key.hasSuffix("/files") {
                object["uploadState"] = "azureStorageUriRequestPending"
                object["isCommitted"] = false
            }
        }
        lists[key, default: []].append(Entry(id: id, object: object))
        return object
    }

    /// A Settings Catalog policy's settings live in their own list.
    private func storeSettings(_ object: inout Object, policy: String) -> Int {
        let settings = object["settings"] as? [Object] ?? []
        object["settings"] = nil
        lists["\(policy)/settings"] = settings.enumerated().map { index, setting in
            var setting = setting
            setting["id"] = "\(index)"
            return Entry(id: "\(index)", object: setting)
        }
        return settings.count
    }

    private func perform(_ action: String, on target: String, body: Object) -> DemoResponse {
        switch action {
        case "assign":
            let entries = body.values.compactMap { $0 as? [Object] }.first ?? []
            lists["\(target)/assignments"] = entries.map { entry in
                var entry = entry
                let id = newID()
                entry["id"] = id
                return Entry(id: id, object: entry)
            }
            // apps and scripts answer 204; the others list what's assigned
            if target.hasPrefix("deviceAppManagement") || target.contains("ShellScripts") {
                return DemoJSON.empty(204)
            }
            return DemoJSON.response(200, ["value": (lists["\(target)/assignments"] ?? []).map(\.object)])
        case "scheduleActionsForRules":
            update(target) { $0["scheduledActionsForRule"] = body["deviceComplianceScheduledActionForRules"] ?? [] }
            return DemoJSON.empty(204)
        case "commit":
            // the encryption key in the body isn't kept
            let fileID = Self.lastSegment(target)
            let complete = blobs[fileID] != nil
            update(target) { $0["uploadState"] = complete ? "commitFilePending" : "commitFileFailed" }
            return DemoJSON.empty(204)
        case "renewUpload":
            update(target) { $0["uploadState"] = "azureStorageUriRenewalPending" }
            return DemoJSON.empty(204)
        default:
            return Self.notFound()
        }
    }

    // MARK: PATCH, PUT, DELETE

    private func patch(_ key: String, _ request: DemoRequest) -> DemoResponse {
        guard let body = DemoJSON.object(request.body) else {
            return Self.error(400, "BadRequest", "The request body isn't valid JSON.")
        }
        guard item(key) != nil else { return Self.notFound() }
        let stamp = DemoWorld.iso(daysAgo: 0, from: now)
        update(key) { object in
            for (name, value) in body where name != "id" { object[name] = value }
            object["lastModifiedDateTime"] = stamp
        }
        if body["committedContentVersion"] != nil { publishIfCommitted(key) }
        return DemoJSON.empty(204)
    }

    private func put(_ key: String, _ request: DemoRequest) -> DemoResponse {
        guard var body = DemoJSON.object(request.body) else {
            return Self.error(400, "BadRequest", "The request body isn't valid JSON.")
        }
        guard let old = item(key) else { return Self.notFound() }
        body["id"] = old["id"]
        body["createdDateTime"] = old["createdDateTime"]
        body["lastModifiedDateTime"] = DemoWorld.iso(daysAgo: 0, from: now)
        if Self.parent(of: key) == "deviceManagement/configurationPolicies" {
            body["settingCount"] = storeSettings(&body, policy: key)
        }
        update(key) { $0 = body }
        return DemoJSON.empty(204)
    }

    private func delete(_ key: String) -> DemoResponse {
        let parent = Self.parent(of: key)
        let id = Self.lastSegment(key)
        guard item(key) != nil else { return Self.notFound() }
        lists[parent]?.removeAll { $0.id == id }
        for list in lists.keys where list.hasPrefix(key + "/") { lists[list] = nil }
        return DemoJSON.empty(204)
    }

    // MARK: Uploads

    /// Reading a file moves its upload on: the storage address is ready, a
    /// commit is done. Nothing has to wait.
    private func advanceUpload(_ key: String) {
        let fileID = Self.lastSegment(key)
        let expires = DemoWorld.iso(daysAgo: -1.0 / 24, from: now)
        update(key) { file in
            switch file["uploadState"] as? String {
            case "azureStorageUriRequestPending":
                file["uploadState"] = "azureStorageUriRequestSuccess"
                file["azureStorageUri"] = Self.storageURI(fileID)
                file["azureStorageUriExpirationDateTime"] = expires
            case "azureStorageUriRenewalPending":
                file["uploadState"] = "azureStorageUriRenewalSuccess"
                file["azureStorageUri"] = Self.storageURI(fileID)
                file["azureStorageUriExpirationDateTime"] = expires
            case "commitFilePending":
                file["uploadState"] = "commitFileSuccess"
                file["isCommitted"] = true
            default:
                break
            }
        }
    }

    private func advanceUploads(in list: String) {
        for entry in lists[list] ?? [] { advanceUpload("\(list)/\(entry.id)") }
    }

    /// The app is published once the content version it names has a committed file.
    private func publishIfCommitted(_ app: String) {
        guard let version = item(app)?["committedContentVersion"] as? String else { return }
        let files = lists["\(app)/contentVersions/\(version)/files"] ?? []
        guard !files.isEmpty, files.allSatisfy({ $0.object["uploadState"] as? String == "commitFileSuccess" }) else { return }
        update(app) { $0["publishingState"] = "published" }
    }

    static func storageURI(_ fileID: String) -> String {
        "https://\(DemoIntuneServer.storageHost)/contoso-content/\(fileID).bin?sv=2026-01-01&sr=b&sp=w&sig=demo-signature"
    }

    /// The storage host: blocks, then the block list that makes the blob.
    func storage(_ request: DemoRequest) -> DemoResponse {
        requestCount += 1
        guard request.query["sig"] != nil else {
            return DemoResponse(status: 403, headers: ["Content-Type": "application/xml"],
                                body: Data("<Error><Code>AuthenticationFailed</Code></Error>".utf8))
        }
        let fileID = (request.pathSegments.last ?? "").replacingOccurrences(of: ".bin", with: "")
        guard request.method == "PUT", request.pathSegments.count == 2 else {
            return DemoResponse(status: 400, headers: [:], body: Data())
        }
        switch request.query["comp"] {
        case "block":
            guard let blockID = request.query["blockid"], !blockID.isEmpty else {
                return DemoResponse(status: 400, headers: [:], body: Data())
            }
            blocks[fileID, default: [:]][blockID] = request.body.count
            return DemoResponse(status: 201, headers: [:], body: Data())
        case "blocklist":
            let text = String(decoding: request.body, as: UTF8.self)
            let listed = text.components(separatedBy: "<Latest>").dropFirst()
                .compactMap { $0.components(separatedBy: "</Latest>").first }
            let received = blocks[fileID] ?? [:]
            guard !listed.isEmpty, listed.allSatisfy({ received[$0] != nil }) else {
                return DemoResponse(status: 400, headers: ["Content-Type": "application/xml"],
                                    body: Data("<Error><Code>InvalidBlockList</Code></Error>".utf8))
            }
            blobs[fileID] = listed.reduce(0) { $0 + (received[$1] ?? 0) }
            return DemoResponse(status: 201, headers: [:], body: Data())
        default:
            return DemoResponse(status: 400, headers: [:], body: Data())
        }
    }

    // MARK: - Paths

    /// Path segments without type casts (`microsoft.graph.mobileLobApp`).
    static func key(_ segments: [String]) -> String {
        segments.filter { !$0.hasPrefix("microsoft.graph.") }.joined(separator: "/")
    }

    private static func parent(of key: String) -> String {
        key.split(separator: "/").dropLast().joined(separator: "/")
    }

    private static func lastSegment(_ key: String) -> String {
        key.split(separator: "/").last.map(String.init) ?? ""
    }

    private static func topList(of key: String) -> String? {
        knownLists.first { key == $0 || key.hasPrefix($0 + "/") }
    }

    /// A list: one every tenant has, or a list below an object that exists.
    private func isList(_ key: String) -> Bool {
        if Self.knownLists.contains(key) || lists[key] != nil { return true }
        let parent = Self.parent(of: key)
        return !parent.isEmpty && item(parent) != nil && !Self.actions.contains(Self.lastSegment(key))
    }

    private func item(_ key: String) -> Object? {
        let id = Self.lastSegment(key)
        return lists[Self.parent(of: key)]?.first { $0.id == id }?.object
    }

    private func update(_ key: String, _ change: (inout Object) -> Void) {
        let parent = Self.parent(of: key)
        let id = Self.lastSegment(key)
        guard let index = lists[parent]?.firstIndex(where: { $0.id == id }) else { return }
        change(&lists[parent]![index].object)
    }

    private func newID() -> String {
        nextNumber += 1
        return DemoSamples.uuid(nextNumber)
    }

    private static func notFound() -> DemoResponse {
        error(404, "ResourceNotFound", "The requested resource does not exist.")
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> DemoResponse {
        DemoJSON.response(status, ["error": ["code": code, "message": message,
                                             "innerError": ["request-id": DemoSamples.uuid(0xeeee), "date": "2026-10-27T10:00:00"]]])
    }

    // MARK: - Contoso's tenant

    static let userID = DemoSamples.uuid(0xe711)
    static let username = "demo.sample@contoso.example"
    static let userDisplayName = "Demo Sample"

    private var me: Object {
        ["id": Self.userID, "displayName": Self.userDisplayName, "userPrincipalName": Self.username,
         "mail": Self.username, "givenName": "Demo", "surname": "Sample"]
    }

    private var apnsCertificate: Object {
        ["id": DemoSamples.uuid(0xe720), "appleIdentifier": "mdm@contoso.example",
         "topicIdentifier": "com.apple.mgmt.External.\(DemoSamples.uuid(0xe721))",
         "expirationDateTime": DemoWorld.iso(daysAgo: -212, from: now),
         "lastModifiedDateTime": DemoWorld.iso(daysAgo: 153, from: now),
         "certificateUploadStatus": NSNull(), "certificateUploadFailureReason": NSNull()]
    }

    private func seed() {
        let created = DemoWorld.iso(daysAgo: 90, from: now)
        func object(_ id: Int, _ fields: Object) -> Object {
            fields.merging(["id": DemoSamples.uuid(id), "createdDateTime": created, "lastModifiedDateTime": created]) { first, _ in first }
        }
        let note = "Created in the Intune admin center."
        lists["organization"] = [Entry(id: DemoWorld.intuneTenantID, object: [
            "id": DemoWorld.intuneTenantID, "displayName": DemoSamples.organization,
            "mobileDeviceManagementAuthority": "intune",
            "verifiedDomains": [["name": "contoso.example", "isDefault": true]],
        ])]
        add([
            object(0xe731, ["displayName": "Contoso Macs", "description": "Every Mac Contoso manages.", "groupTypes": [],
                            "mailEnabled": false, "securityEnabled": true, "mailNickname": "contoso-macs"]),
            object(0xe732, ["displayName": "Contoso iPads", "description": "Shared iPads.", "groupTypes": [],
                            "mailEnabled": false, "securityEnabled": true, "mailNickname": "contoso-ipads"]),
            object(0xe733, ["displayName": "Contoso Finance Macs", "description": "Macs of the finance team.",
                            "groupTypes": ["DynamicMembership"], "membershipRule": "(device.deviceCategory -eq \"Finance\")",
                            "mailEnabled": false, "securityEnabled": true, "mailNickname": "contoso-finance-macs"]),
        ], to: "groups")
        add([object(0xe741, ["name": "Contoso – FileVault", "description": note, "platforms": "macOS",
                             "technologies": "mdm", "settingCount": 1, "roleScopeTagIds": ["0"]])],
            to: "deviceManagement/configurationPolicies")
        lists["deviceManagement/configurationPolicies/\(DemoSamples.uuid(0xe741))/settings"] = [Entry(id: "0", object: [
            "id": "0",
            "settingInstance": [
                "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                "settingDefinitionId": "com.apple.mcx.filevault2_enable",
                "choiceSettingValue": ["value": "com.apple.mcx.filevault2_enable_0", "children": []],
            ],
        ])]
        add([object(0xe742, ["@odata.type": "#microsoft.graph.macOSCustomConfiguration", "displayName": "Contoso – Dock",
                             "description": note, "payloadName": "Dock", "payloadFileName": "dock.mobileconfig",
                             "payload": Data("<plist version=\"1.0\"><dict/></plist>".utf8).base64EncodedString(),
                             "deploymentChannel": "deviceChannel"])],
            to: "deviceManagement/deviceConfigurations")
        add([object(0xe743, ["@odata.type": "#microsoft.graph.macOSCompliancePolicy",
                             "displayName": "Contoso – macOS Compliance", "description": note,
                             "osMinimumVersion": "15.0", "storageRequireEncryption": true, "firewallEnabled": true,
                             "scheduledActionsForRule": [["ruleName": NSNull(), "scheduledActionConfigurations": [
                                ["actionType": "block", "gracePeriodHours": 0, "notificationTemplateId": "",
                                 "notificationMessageCCList": []]]]]])],
            to: "deviceManagement/deviceCompliancePolicies")
        add([object(0xe744, ["displayName": "Contoso – Set Computer Name", "description": note,
                             "fileName": "set-computer-name.sh", "runAsAccount": "system", "executionFrequency": "P1D",
                             "retryCount": 1, "blockExecutionNotifications": true,
                             "scriptContent": Data("#!/bin/zsh\n# Contoso sample script\nexit 0\n".utf8).base64EncodedString()])],
            to: "deviceManagement/deviceShellScripts")
        add([object(0xe745, ["displayName": "Contoso – Battery Cycle Count", "description": note,
                             "fileName": "battery-cycles.sh", "runAsAccount": "system", "customAttributeType": "integer",
                             "customAttributeName": "BatteryCycleCount",
                             "scriptContent": Data("#!/bin/zsh\necho 42\n".utf8).base64EncodedString()])],
            to: "deviceManagement/deviceCustomAttributeShellScripts")
        add([object(0xe746, ["displayName": "Contoso – Corporate Macs", "description": note, "platform": "macOS",
                             "rule": "(device.deviceOwnership -eq \"Corporate\")",
                             "assignmentFilterManagementType": "devices"])],
            to: "deviceManagement/assignmentFilters")
        add([
            object(0xe747, ["@odata.type": "#microsoft.graph.macOSPkgApp", "displayName": "Contoso Helpdesk",
                            "description": note, "publisher": "Contoso", "publishingState": "published",
                            "fileName": "ContosoHelpdesk.pkg", "primaryBundleId": "example.contoso.helpdesk",
                            "primaryBundleVersion": "2.4", "committedContentVersion": "1"]),
            object(0xe748, ["@odata.type": "#microsoft.graph.macOSMicrosoftEdgeApp", "displayName": "Microsoft Edge",
                            "description": "Microsoft Edge for macOS.", "publisher": "Microsoft",
                            "publishingState": "published", "channel": "stable"]),
        ], to: "deviceAppManagement/mobileApps")
        add([object(0xe749, ["tokenName": "Contoso Apple Business Manager", "appleIdentifier": "abm@contoso.example",
                             "tokenType": "dep", "tokenExpirationDateTime": DemoWorld.iso(daysAgo: -300, from: now),
                             "lastSuccessfulSyncDateTime": DemoWorld.iso(daysAgo: 0.2, from: now)])],
            to: "deviceManagement/depOnboardingSettings")
        add([DemoSettingDefinition(id: "com.apple.mcx.filevault2_enable", displayName: "Enable",
                                   options: [("com.apple.mcx.filevault2_enable_0", "On"),
                                             ("com.apple.mcx.filevault2_enable_1", "Off")])])
    }
}

/// A Settings Catalog setting definition in the demo tenant's catalog, e.g.
/// one an app's baseline uses (`DemoIntuneServer.add(definitions:)`).
public nonisolated struct DemoSettingDefinition: Sendable {
    public let id: String
    public let displayName: String
    /// A choice setting's options: their IDs and names.
    public let options: [(id: String, displayName: String)]

    public init(id: String, displayName: String, options: [(id: String, displayName: String)] = []) {
        self.id = id
        self.displayName = displayName
        self.options = options
    }

    var json: [String: Any] {
        var json: [String: Any] = [
            "@odata.type": options.isEmpty ? "#microsoft.graph.deviceManagementConfigurationSimpleSettingDefinition"
                : "#microsoft.graph.deviceManagementConfigurationChoiceSettingDefinition",
            "id": id, "displayName": displayName, "name": id.split(separator: "_").last.map(String.init) ?? id,
            "platforms": "macOS", "technologies": "mdm",
        ]
        if !options.isEmpty {
            json["options"] = options.map { ["itemId": $0.id, "displayName": $0.displayName, "name": $0.displayName] }
        }
        return json
    }
}
