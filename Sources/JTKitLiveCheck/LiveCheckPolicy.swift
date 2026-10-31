import Foundation

/// One request as the live check sees it, before it’s sent.
public nonisolated struct LiveRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.url = url
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }

    public init(_ request: URLRequest, body: Data?) {
        self.init(method: request.httpMethod ?? "GET", url: request.url ?? URL(filePath: "/"),
                  headers: request.allHTTPHeaderFields ?? [:], body: body ?? request.httpBody ?? Data())
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

extension LiveRequest: CustomStringConvertible {
    /// Method, host and path only: no query, header or body (they can hold
    /// tokens, secrets and serial numbers).
    public var description: String {
        "\(method) \(url.host() ?? "")\(url.path(percentEncoded: false))"
    }
}

/// What the live check decided about a request.
public nonisolated enum LiveDecision: Sendable, Equatable {
    case allow(Allowed)
    case refuse(String)

    public nonisolated struct Allowed: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case signIn, read
            /// A new object named `name`; recorded in the ledger when it succeeds.
            case create(name: String)
            /// A change to (or action on) an object in the ledger.
            case change
            case delete
        }
        public var kind: Kind
        public var role: String
        /// See `Ledger.Item.target`.
        public var target: String
        public var resource: String?
        public var id: String?
    }

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// The live-check rules, enforced before anything is sent:
/// 1. A host, environment, Entra tenant or Apple client ID not on the
///    allow-list is refused.
/// 2. Read-only tenants get GET only; besides that only sign-in and sign-out
///    at the exact Jamf, Microsoft and Apple token paths. Every Apple
///    activity (`orgDeviceActivities`) is refused.
/// 3. Full and create-and-remove tenants: a create is refused unless the
///    object’s name starts with the run’s prefix; an update or delete is
///    refused unless the object is in the ledger. MDM commands are refused.
/// 4. Graph: the bearer token’s tenant ID must be on the allow-list.
/// 5. Graph writes: no `$batch`; assignments only to a group (and
///    filter) this run created, never All devices or All users; compliance
///    actions only "block"; a permanent delete from Entra’s deleted items
///    only for a group this run created and removed.
/// 6. Jamf writes: no scope to all computers, all mobile devices or all
///    users, and every group in a scope is a group this run created.
public nonisolated final class LiveCheckPolicy: @unchecked Sendable {
    public let entries: [AllowList.Entry]
    public let includeProduction: Bool
    /// The run’s prefix, e.g. `"JTKTEST JD 1027-1432"`; every created object’s name starts with it.
    public let prefix: String
    public let ledger: Ledger
    /// Off during the release check’s first stages: every tenant is then
    /// treated as read only, whatever the allow-list says.
    public let writesAllowed: Bool

    private let lock = NSLock()
    /// Earlier runs’ JTKTEST groups in Entra’s recycle bin the sweep may
    /// purge, by target (`LiveCheckRun.adoptDeletedGroupForPurge`).
    private var purgeable: [String: Set<String>] = [:]
    /// Apple’s access tokens, which carry no organization, by the client they were issued to.
    private var appleTokens: [String: String] = [:]

    /// - Parameters:
    ///   - allowList: the loaded allow-list.
    ///   - roles: the roles this run uses; every other entry is refused.
    public init(allowList: AllowList, roles: Set<String>?, includeProduction: Bool, prefix: String, ledger: Ledger,
                writesAllowed: Bool = true) {
        entries = allowList.entries(roles: roles)
        self.writesAllowed = writesAllowed
        self.includeProduction = includeProduction
        self.prefix = prefix
        self.ledger = ledger
    }

    /// Allows the permanent delete of one deleted group (named as a test
    /// object; checked by `LiveCheckRun`).
    func allowPurge(target: String, id: String) {
        _ = lock.withLock { purgeable[target.lowercased(), default: []].insert(id.lowercased()) }
    }

    /// Remembers an Apple access token issued to an allow-listed client.
    func recordAppleToken(_ token: String, clientID: String) {
        lock.withLock { appleTokens[token] = clientID }
    }

    // MARK: Deciding

    public func decide(_ request: LiveRequest) -> LiveDecision {
        guard let host = request.url.host()?.lowercased(), request.url.scheme?.lowercased() == "https" else {
            return .refuse("Only https requests to allow-listed tenants are sent")
        }
        let path = request.url.path(percentEncoded: false)
        switch identify(request, host: host, path: path) {
        case .failure(let refusal):
            return .refuse(refusal.reason)
        case .success(let (entry, target, isSignIn)):
            if entry.production && !includeProduction {
                return .refuse("\(entry.role) is a production tenant; it’s only read with --include-production")
            }
            if isSignIn {
                return .allow(.init(kind: .signIn, role: entry.role, target: target, resource: nil, id: nil))
            }
            return decideAccess(request, entry: entry, target: target, path: path)
        }
    }

    struct Refusal: Error { var reason: String }

    /// Which allow-listed tenant a request is for, and whether it’s a sign-in.
    private func identify(_ request: LiveRequest, host: String, path: String) -> Result<(AllowList.Entry, String, Bool), Refusal> {
        let segments = path.split(separator: "/").map(String.init)

        // Jamf Platform gateway: one host per region; the environment is a header.
        if let region = Self.platformRegion(host: host) {
            let platform = entries.filter { $0.service == .jamfPlatform && $0.region?.lowercased() == region }
            if request.method == "POST" && segments == ["auth", "token"] {
                guard let entry = platform.first else { return .failure(Refusal(reason: "No allow-listed Jamf Platform tenant in region \(region)")) }
                return .success((entry, "platform-signin:\(region)", true))
            }
            guard let environment = request.header("X-Environment-Id")?.lowercased() else {
                return .failure(Refusal(reason: "A Jamf Platform request without an environment can’t be matched to the allow-list"))
            }
            guard let entry = platform.first(where: { $0.environmentID?.lowercased() == environment }) else {
                return .failure(Refusal(reason: "Jamf Platform environment \(environment) isn’t on the allow-list"))
            }
            return .success((entry, "platform:\(environment)", false))
        }

        // Microsoft sign-in: the tenant is the first path segment.
        if host == "login.microsoftonline.com" {
            guard let tenant = segments.first?.lowercased(),
                  let entry = entries.first(where: { $0.service == .intune && $0.entraTenantID?.lowercased() == tenant })
            else { return .failure(Refusal(reason: "This Microsoft tenant isn’t on the allow-list")) }
            guard request.method == "POST", Array(segments.dropFirst()) == ["oauth2", "v2.0", "token"] else {
                return .failure(Refusal(reason: "Only Microsoft’s token endpoint is allowed"))
            }
            return .success((entry, "intune:\(tenant)", true))
        }

        // Graph: the token says which tenant (rule 4).
        if host == "graph.microsoft.com" {
            guard let tenant = Self.bearerTenantID(request.header("Authorization")) else {
                return .failure(Refusal(reason: "A Graph request without a readable token tenant is refused"))
            }
            guard let entry = entries.first(where: { $0.service == .intune && $0.entraTenantID?.lowercased() == tenant }) else {
                return .failure(Refusal(reason: "Microsoft tenant \(tenant) isn’t on the allow-list"))
            }
            return .success((entry, "intune:\(tenant)", false))
        }

        // Apple sign-in: the client ID is in the form body.
        if host == "account.apple.com" {
            guard request.method == "POST", path == "/auth/oauth2/v2/token" else {
                return .failure(Refusal(reason: "Only Apple’s token endpoint is allowed"))
            }
            guard let clientID = Self.formValue("client_id", in: request.body),
                  let entry = entries.first(where: { Self.isApple($0.service) && $0.clientID == clientID })
            else { return .failure(Refusal(reason: "This Apple organization isn’t on the allow-list")) }
            return .success((entry, "apple:\(clientID)", true))
        }

        // Apple’s API: only tokens issued to an allow-listed client here.
        if host == "api-business.apple.com" || host == "api-school.apple.com" {
            let token = Self.bearer(request.header("Authorization"))
            guard let token, let clientID = lock.withLock({ appleTokens[token] }),
                  let entry = entries.first(where: { Self.isApple($0.service) && $0.clientID == clientID })
            else { return .failure(Refusal(reason: "An Apple request whose token wasn’t issued to an allow-listed organization")) }
            return .success((entry, "apple:\(clientID)", false))
        }

        // Jamf Pro and Jamf School, by hostname.
        guard let entry = entries.first(where: { ($0.service == .jamfPro || $0.service == .jamfSchool) && $0.hosts.contains(host) }) else {
            return .failure(Refusal(reason: "\(host) isn’t on the allow-list"))
        }
        let target = entry.host?.lowercased() ?? host
        let isSignIn = request.method == "POST" && Self.jamfSignInPaths.contains(path)
        return .success((entry, target, isSignIn))
    }

    private func decideAccess(_ request: LiveRequest, entry: AllowList.Entry, target: String, path: String) -> LiveDecision {
        let lowered = path.lowercased()
        let role = entry.role
        if Self.isApple(entry.service) && lowered.contains("orgdeviceactivities") {
            return .refuse("Apple Business or Apple School Manager activities are never run")
        }
        if Self.isSecretRead(lowered) || Self.selectsSecret(request.url) {
            return .refuse("Device secrets (FileVault key, Recovery Lock, lock PIN, local admin password, Activation Lock bypass code) are never read in a live check")
        }
        let isRead = request.method == "GET" || request.method == "HEAD"
        if isRead {
            return .allow(.init(kind: .read, role: role, target: target, resource: nil, id: nil))
        }
        guard entry.access != .readOnly else {
            return .refuse("\(role) is read only: \(request.method) refused")
        }
        guard writesAllowed else {
            return .refuse("Writes are off in this stage of the release check: \(request.method) refused")
        }
        if Self.isDeviceCommand(lowered, method: request.method) {
            return .refuse("Device commands are never sent in a live check")
        }
        if target.hasPrefix("intune:") {
            if let refusal = graphRefusal(request, target: target, path: lowered) { return .refuse(refusal) }
            if let deleted = Self.deletedItemID(path) {
                // Entra’s recycle bin: a permanent delete, only of a group
                // this run created (not one an earlier run left) and already
                // deleted.
                guard request.method == "DELETE" else { return .refuse("Only a permanent delete is sent to deleted items") }
                let ownGroup = ledger.item(target: target, resource: "groups", id: deleted).map { !$0.fromSweep && $0.removed } ?? false
                let adopted = lock.withLock { purgeable[target.lowercased()]?.contains(deleted.lowercased()) == true }
                guard ownGroup || adopted else {
                    return .refuse("deleted item \(deleted) isn’t a group this run created and removed, nor a JTKTEST group the sweep found: permanent delete refused")
                }
                return .allow(.init(kind: .delete, role: role, target: target, resource: "deleteditems", id: deleted))
            }
        }
        if !target.hasPrefix("intune:"), let refusal = jamfScopeRefusal(request, target: target) {
            return .refuse(refusal)
        }
        let reference = Self.objectReference(path)
        switch request.method {
        case "POST" where reference.id == nil || reference.isClassicCreate:
            guard let resource = reference.resource else { return .refuse("A POST with no object type is refused") }
            if let failure = ledger.saveFailure {
                return .refuse("Creates are refused once the ledger can’t be saved: \(failure)")
            }
            guard let name = Self.objectName(in: request.body) else {
                return .refuse("A create without a readable name is refused")
            }
            guard name.hasPrefix(prefix) else {
                return .refuse("“\(name)” doesn’t start with the run’s prefix “\(prefix)”")
            }
            return .allow(.init(kind: .create(name: name), role: role, target: target, resource: resource, id: nil))
        case "POST", "PUT", "PATCH", "DELETE":
            guard let resource = reference.resource, let id = reference.id else {
                return .refuse("A \(request.method) that names no object is refused (tenant-wide settings are never changed)")
            }
            guard ledger.contains(target: target, resource: resource, id: id) else {
                return .refuse("\(resource) \(id) wasn’t created by this run: \(request.method) refused")
            }
            return .allow(.init(kind: request.method == "DELETE" ? .delete : .change, role: role, target: target, resource: resource, id: id))
        default:
            return .refuse("\(request.method) is refused")
        }
    }

    // MARK: Graph

    /// Graph writes: no `$batch` (its requests can’t be checked one by one);
    /// assignments only to groups (and filters) this run created, never All
    /// devices, All users or any other group; compliance actions only "block"
    /// (retire, wipe, lock and notifications are device actions or reach people).
    private func graphRefusal(_ request: LiveRequest, target: String, path: String) -> String? {
        if path.split(separator: "/").contains("$batch") {
            return "Graph $batch is refused: the requests inside it can’t be checked one by one"
        }
        guard !request.body.isEmpty, let body = try? JSONSerialization.jsonObject(with: request.body) else { return nil }
        var refusal: String?
        Self.visitObjects(in: body) { object in
            guard refusal == nil else { return }
            if let action = object["actionType"] as? String, action.lowercased() != "block" {
                refusal = "Compliance action “\(action)” is refused: only “block” is sent in a live check"
                return
            }
            // An assignment target: its type says so, or it names a group.
            let type = (object["@odata.type"] as? String)?.lowercased() ?? ""
            guard type.hasSuffix("assignmenttarget") || object["groupId"] != nil else { return }
            switch type {
            case "#microsoft.graph.groupassignmenttarget", "#microsoft.graph.exclusiongroupassignmenttarget":
                break
            case "#microsoft.graph.alldevicesassignmenttarget":
                refusal = "An assignment to All devices is refused"
                return
            case "#microsoft.graph.alllicensedusersassignmenttarget":
                refusal = "An assignment to All users is refused"
                return
            default:
                refusal = "An assignment target of type “\(type.isEmpty ? "none" : type)” is refused"
                return
            }
            guard let group = object["groupId"] as? String,
                  let item = ledger.item(target: target, resource: "groups", id: group), !item.fromSweep, !item.removed
            else {
                refusal = "An assignment to group \(object["groupId"] as? String ?? "(none)") is refused: only a group this run created"
                return
            }
            if let filter = object["deviceAndAppManagementAssignmentFilterId"] as? String,
               !filter.isEmpty, filter != "00000000-0000-0000-0000-000000000000",
               ledger.item(target: target, resource: "assignmentfilters", id: filter) == nil {
                refusal = "An assignment with filter \(filter) is refused: only a filter this run created"
            }
        }
        return refusal
    }

    // MARK: Jamf scopes

    /// Jamf writes (Classic XML, Jamf Pro and Platform JSON): no scope to
    /// all computers, all mobile devices or all users, and every group in a
    /// scope or `deviceGroups` list is a group this run created. Exclusions
    /// and limitations only narrow a scope and aren’t checked.
    private func jamfScopeRefusal(_ request: LiveRequest, target: String) -> String? {
        guard !request.body.isEmpty else { return nil }
        if let body = try? JSONSerialization.jsonObject(with: request.body) {
            var refusal: String?
            Self.visitObjects(in: body) { object in
                for (key, value) in object where refusal == nil {
                    let key = Ledger.normalized(key)
                    if Self.allTargetKeys.contains(key) {
                        if (value as? Bool) == true || (value as? String)?.lowercased() == "true" {
                            refusal = "A scope to everyone (“\(key)”) is refused"
                        }
                    } else if Self.groupListKeys.contains(key) {
                        // IDs, or objects carrying one (`[{"id": 5}]`).
                        let ids = (value as? [Any] ?? [value]).compactMap { element -> String? in
                            let id = (element as? [String: Any])?["id"] ?? element
                            return (id as? String) ?? (id as? NSNumber)?.stringValue
                        }
                        if let other = ids.first(where: { !isRunGroup(target: target, id: $0) }) {
                            refusal = "A scope with group \(other) is refused: only a group this run created"
                        }
                    }
                }
            }
            return refusal
        }
        guard let document = try? XMLDocument(data: request.body, options: []),
              let scopes = try? document.nodes(forXPath: "//scope") as? [XMLElement] else {
            return String(decoding: request.body, as: UTF8.self).contains("<scope") ? "A scope that can’t be read is refused" : nil
        }
        for scope in scopes {
            for child in scope.children ?? [] where ["exclusions", "limitations", "limit_to_users"].contains(child.name ?? "") {
                child.detach()
            }
            for key in ["all_computers", "all_mobile_devices", "all_jss_users"] {
                if (scope.elements(forName: key).first?.stringValue ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "true" {
                    return "A scope to everyone (“\(key)”) is refused"
                }
            }
            // Every object a scope names: an element holding an <id> or <name>.
            let named = ((try? scope.nodes(forXPath: ".//*[id or name]")) as? [XMLElement]) ?? []
            for object in named {
                let kind = object.name ?? ""
                guard kind == "computer_group" || kind == "mobile_device_group" else {
                    return "A scope naming a \(kind) is refused: only groups this run created"
                }
                let id = object.elements(forName: "id").first?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !id.isEmpty, isRunGroup(target: target, id: id) else {
                    return "A scope with \(kind) \(id.isEmpty ? "(by name)" : id) is refused: only a group this run created"
                }
            }
        }
        return nil
    }

    static let allTargetKeys: Set<String> = ["allcomputers", "allmobiledevices", "alljssusers", "allusers", "alldevices"]
    static let groupListKeys: Set<String> = [
        "devicegroups", "devicegroupids", "computergroups", "computergroupids", "computergroupid",
        "mobiledevicegroups", "mobiledevicegroupids", "mobiledevicegroupid",
    ]

    /// A group (of any API) this run created and hasn’t removed.
    private func isRunGroup(target: String, id: String) -> Bool {
        ledger.items.contains { item in
            item.target == target.lowercased() && !item.fromSweep && !item.removed
                && ((item.resource.hasSuffix("groups") && item.id.lowercased() == id.lowercased())
                    || item.aliases.contains { $0.hasSuffix("groups/\(id.lowercased())") })
        }
    }

    /// Calls `visit` for every JSON object in `value`, nested ones included.
    static func visitObjects(in value: Any, _ visit: ([String: Any]) -> Void) {
        if let object = value as? [String: Any] {
            visit(object)
            for child in object.values { visitObjects(in: child, visit) }
        } else if let array = value as? [Any] {
            for child in array { visitObjects(in: child, visit) }
        }
    }

    /// `…/directory/deletedItems/{id}`: the ID, else nil.
    static func deletedItemID(_ path: String) -> String? {
        let segments = path.split(separator: "/").map(String.init)
        guard let index = segments.firstIndex(where: { $0.lowercased() == "deleteditems" }),
              index > 0, segments[index - 1].lowercased() == "directory", index + 1 < segments.count
        else { return nil }
        return segments[index + 1]
    }

    // MARK: Request parsing

    static let jamfSignInPaths: Set<String> = [
        "/api/oauth/token", "/api/v1/auth/token", "/api/v1/auth/invalidate-token", "/api/v1/auth/keep-alive",
    ]

    static func isApple(_ service: AllowList.Service) -> Bool {
        service == .appleBusinessManager || service == .appleSchoolManager
    }

    /// `us`, `eu`, `apac` for `<region>.api.jamfcloud.com`.
    static func platformRegion(host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts[1] == "api", parts[2] == "jamfcloud", parts[3] == "com" else { return nil }
        return String(parts[0])
    }

    static func isDeviceCommand(_ path: String, method: String) -> Bool {
        // Also refused on a device the run created: erase, unmanage
        // and remove-MDM-profile are actions on a device record, not changes
        // to a test object, and Platform device actions likewise.
        let markers = ["mdm-commands", "mdmcommands", "computercommands", "mobiledevicecommands",
                       "/commands", "remote-lock", "erase-device", "redeploy", "managed-software-updates/plans",
                       "/erase", "/unmanage", "remove-mdm-profile", "device-actions/",
                       "blank-push", "renew-profile"]
        if markers.contains(where: path.contains) { return true }
        let segments = path.split(separator: "/").map(String.init)
        // Jamf Pro DDM sync: …/ddm/{id}/sync
        if let ddm = segments.firstIndex(of: "ddm"), segments.last == "sync", segments.count > ddm + 2 { return true }
        // Jamf School: …/devices/{udid}/refresh|restart|wipe|unenroll|…
        if let devices = segments.firstIndex(of: "devices"), devices + 2 < segments.count,
           jamfSchoolActions.contains(segments[devices + 2]) { return true }
        // Graph: any change to a managed device, its actions (POST
        // …/managedDevices/{id}/<action>) and Delete Record (DELETE …/managedDevices/{id}).
        return path.contains("manageddevices")
    }

    static let jamfSchoolActions: Set<String> = [
        "refresh", "restart", "wipe", "unenroll", "shutdown", "lock", "clearpasscode", "lostmode", "clearactivationlock",
    ]

    /// Device secrets, refused on every tenant whatever the method:
    /// reading them is never part of a check, and Jamf Pro rotates a local
    /// admin password once it has been viewed.
    static func isSecretRead(_ path: String) -> Bool {
        let markers = ["/filevault", "view-recovery-lock-password", "view-device-lock-pin",
                       // Activation Lock bypass codes (Jamf, Graph)
                       "activationlockbypass", "activation-lock-bypass", "activation_lock_bypass",
                       // Graph: a Mac’s FileVault key, BitLocker keys, Windows LAPS
                       "getfilevaultkey", "bitlocker/recoverykeys", "devicelocalcredentials"]
        if markers.contains(where: path.contains) { return true }
        // Jamf Pro LAPS: …/local-admin-password/{id}/account/{user}[/{guid}]/password.
        // Its settings and account list hold no password and stay readable.
        return path.contains("local-admin-password/") && path.hasSuffix("/password")
    }

    /// Graph’s `$select=activationLockBypassCode` on a device read.
    static func selectsSecret(_ url: URL) -> Bool {
        (url.query(percentEncoded: false) ?? "").lowercased().contains("activationlockbypass")
    }

    struct ObjectReference: Equatable {
        var resource: String?
        var id: String?
        /// Classic’s `…/id/0`: a create.
        var isClassicCreate = false
    }

    /// The object a path is about: the first ID-like segment and the type
    /// before it (`/api/v1/categories/12/history` → categories 12;
    /// `/JSSResource/scripts/id/7` → scripts 7; `/blueprints/v1/blueprints`
    /// → blueprints, no ID). Classic’s `…/name/{name}` names an object by its
    /// name: as a create it’s checked like `…/id/0`; otherwise the name stands
    /// in for an ID, which no ledger object has.
    static func objectReference(_ path: String) -> ObjectReference {
        let segments = path.split(separator: "/").map(String.init)
        var previous: String?
        for (index, segment) in segments.enumerated() {
            if segment.lowercased() == "id", index + 1 < segments.count, isID(segments[index + 1]) {
                let id = segments[index + 1]
                return ObjectReference(resource: previous, id: id, isClassicCreate: id == "0")
            }
            if segment.lowercased() == "name", previous != nil, index + 1 < segments.count {
                return ObjectReference(resource: previous, id: "name:\(segments[index + 1])", isClassicCreate: true)
            }
            if isID(segment) {
                return ObjectReference(resource: previous, id: segment)
            }
            if !isVersion(segment) { previous = segment }
        }
        // A collection: its type is the last segment that isn’t a version.
        return ObjectReference(resource: previous, id: nil)
    }

    static func isVersion(_ segment: String) -> Bool {
        segment.count >= 2 && segment.first == "v" && segment.dropFirst().allSatisfy(\.isNumber)
            || segment == "beta" || segment == "v1.0"
    }

    static func isID(_ segment: String) -> Bool {
        if !segment.isEmpty && segment.allSatisfy(\.isNumber) { return true }
        return UUID(uuidString: segment) != nil
    }

    /// The new object’s name: JSON `name` or `displayName` at the top level
    /// (or Jamf’s `general.name`), or the first `<name>` in Classic XML.
    static func objectName(in body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let name = object["name"] as? String { return name }
            if let name = object["displayName"] as? String { return name }
            if let general = object["general"] as? [String: Any], let name = general["name"] as? String { return name }
            return nil
        }
        guard let text = String(data: body, encoding: .utf8),
              let start = text.range(of: "<name>"),
              let end = text.range(of: "</name>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// The ID of a created object in a response: JSON `id`, or Classic’s `<id>`.
    static func createdID(in body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let id = object["id"] as? String { return id }
            if let id = object["id"] as? NSNumber { return id.stringValue }
            return nil
        }
        guard let text = String(data: body, encoding: .utf8),
              let start = text.range(of: "<id>"),
              let end = text.range(of: "</id>", range: start.upperBound..<text.endIndex)
        else { return nil }
        let id = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    static func bearer(_ header: String?) -> String? {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return nil }
        return String(header.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    /// The `tid` claim of a bearer JWT, lowercased.
    static func bearerTenantID(_ header: String?) -> String? {
        guard let token = bearer(header) else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tenant = claims["tid"] as? String
        else { return nil }
        return tenant.lowercased()
    }

    static func formValue(_ name: String, in body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        var components = URLComponents()
        components.percentEncodedQuery = text.replacingOccurrences(of: "+", with: "%20")
        return components.queryItems?.first { $0.name == name }?.value
    }
}
