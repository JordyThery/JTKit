import Foundation

/// A refused request, for the report.
public nonisolated struct LiveRefusal: Sendable, Equatable, Codable {
    public var method: String
    /// Host and path only: no query, no body.
    public var location: String
    public var reason: String
}

/// The error a client sees for a refused request.
public nonisolated struct LiveCheckRefused: LocalizedError, Sendable {
    public var refusal: LiveRefusal
    public var errorDescription: String? {
        "Live check refused \(refusal.method) \(refusal.location): \(refusal.reason)"
    }
}

/// How long a delete’s read-back keeps looking: Jamf removes some
/// objects (a deployed Blueprint) in the background.
public nonisolated struct ReadBack: Sendable {
    public var attempts: Int
    public var interval: TimeInterval
    /// For a permanent delete from Entra’s recycle bin, which Entra can
    /// keep showing for a while.
    public var recycleBinAttempts: Int

    public init(attempts: Int, interval: TimeInterval, recycleBinAttempts: Int? = nil) {
        self.attempts = attempts
        self.interval = interval
        self.recycleBinAttempts = recycleBinAttempts ?? attempts
    }

    /// About a minute; two for the recycle bin.
    public static let standard = ReadBack(attempts: 12, interval: 5, recycleBinAttempts: 24)

    /// The longest a client can wait for a write’s answer: the read-back
    /// before its first change, the delete’s read-back, and a second one
    /// after the Jamf Pro fallback, with room for the reads themselves. The
    /// live session’s timeouts are above it, so a client never takes a
    /// long read-back for a dropped connection and sends the delete again.
    public var longestWait: TimeInterval {
        2 * Double(max(attempts, recycleBinAttempts, 1)) * interval + 180
    }
}

/// What a delete’s read-back found, one JSON line each in the run’s
/// `deletes.jsonl` for the report.
public nonisolated struct DeleteOutcome: Sendable, Equatable, Codable {
    public var resource: String
    public var id: String
    public var name: String
    /// The delete’s own answer (never counted on its own).
    public var status: Int
    /// The read-back found the object gone.
    public var confirmed: Bool
    /// A Platform device group still listed after its Platform delete was
    /// deleted again through the Jamf Pro API (its Classic twin).
    public var throughJamfPro: Bool
}

/// A create the server accepted that isn’t in the ledger (its answer held no
/// readable ID, or the ledger couldn’t be saved): one JSON line each in the
/// run’s `unrecorded-creates.jsonl`. Any fails the run, as the object may
/// still be on the tenant.
public nonisolated struct UnrecordedCreate: Sendable, Equatable, Codable {
    public var resource: String
    public var name: String
    public var status: Int
    public var reason: String
}

/// The live check’s network: give its `session` to the app’s
/// `RequestRecorder`, where demo mode gives its own. Every request is decided
/// by the `LiveCheckPolicy` before it’s sent; allowed ones go out through
/// `upstream`, refused ones fail with `LiveCheckRefused` and nothing leaves
/// the Mac. Successful creates are written to the ledger. An object test code
/// recorded (`recordCreated`, `adoptForSweep`, an earlier run’s ledger) is
/// read back before its first change or delete, and its name on the server
/// must be the ledger’s. A delete is marked removed only once a read-back
/// finds the object gone: its answer, 200 or 404, never counts on its own.
public nonisolated final class LiveCheckNetwork: @unchecked Sendable {
    public let policy: LiveCheckPolicy
    public let session: URLSession
    let upstream: URLSession

    /// Where each refusal is appended the moment it happens, one
    /// JSON line each: every test of a release check runs in its own process,
    /// so a file shared by the run keeps them all for the report.
    let refusalsFile: URL?

    /// Paces every Apple request and caps them per run.
    public let appleBudget: AppleRequestBudget

    let readBack: ReadBack
    let deletesFile: URL?
    let unrecordedFile: URL?
    private var deleteStorage: [DeleteOutcome] = []
    private var unrecordedStorage: [UnrecordedCreate] = []

    /// Creates of this process the ledger doesn’t hold.
    public var unrecordedCreates: [UnrecordedCreate] { lock.withLock { unrecordedStorage } }

    /// Every delete’s read-back so far in this process.
    public var deletes: [DeleteOutcome] { lock.withLock { deleteStorage } }

    private let lock = NSLock()
    private var refusedStorage: [LiveRefusal] = []

    /// - Parameters:
    ///   - upstream: where allowed requests go; a fresh ephemeral session by
    ///     default (tests pass a mock).
    ///   - refusalsFile: the run’s `refusals.jsonl` (`LiveCheckRun` passes it).
    ///   - appleRequestsFile: the run’s `apple-requests.jsonl`, so the Apple
    ///     budget is shared by the run’s test processes (`LiveCheckRun` passes it).
    ///   - appleBudget: replaces the standard budget (9 a minute, 40 a run per
    ///     organization); JTKit’s own tests use a small one.
    ///   - readBack: how long a delete’s read-back keeps looking.
    ///   - deletesFile: the run’s `deletes.jsonl` (`LiveCheckRun` passes it).
    ///   - unrecordedFile: the run’s `unrecorded-creates.jsonl` (`LiveCheckRun` passes it).
    public init(policy: LiveCheckPolicy, upstream: URLSession = LiveCheckNetwork.makeUpstream(), refusalsFile: URL? = nil,
                appleRequestsFile: URL? = nil, appleBudget: AppleRequestBudget? = nil,
                readBack: ReadBack = .standard, deletesFile: URL? = nil, unrecordedFile: URL? = nil) {
        self.policy = policy
        self.upstream = upstream
        self.refusalsFile = refusalsFile
        self.readBack = readBack
        self.deletesFile = deletesFile
        self.unrecordedFile = unrecordedFile
        self.appleBudget = appleBudget ?? AppleRequestBudget(file: appleRequestsFile)
        let id = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveCheckURLProtocol.self]
        configuration.httpAdditionalHeaders = [LiveCheckURLProtocol.networkHeader: id]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        // A write’s answer waits for its read-backs (see `ReadBack.longestWait`).
        configuration.timeoutIntervalForRequest = readBack.longestWait
        configuration.timeoutIntervalForResource = max(configuration.timeoutIntervalForResource, readBack.longestWait)
        session = URLSession(configuration: configuration)
        LiveCheckURLProtocol.register(self, id: id)
    }

    /// An ephemeral session that never follows a redirect: a redirect to
    /// another host would skip the policy, so the 3xx goes back to the client.
    public static func makeUpstream() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Every refused request so far; a run with any fails its check.
    public var refusals: [LiveRefusal] { lock.withLock { refusedStorage } }

    func refuse(_ request: LiveRequest, reason: String) -> LiveCheckRefused {
        let refusal = LiveRefusal(method: request.method, location: Self.maskedLocation(request.url), reason: reason)
        lock.withLock {
            refusedStorage.append(refusal)
            if let refusalsFile, let line = try? JSONEncoder().encode(refusal) { Self.appendLine(line, to: refusalsFile) }
        }
        return LiveCheckRefused(refusal: refusal)
    }

    /// Host and path, with every ID-like path segment (a number, a UUID, a
    /// serial number or token) shown as `{id}`: refusals go into the report.
    static func maskedLocation(_ url: URL) -> String {
        let path = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: false).map { segment in
            isIDLike(String(segment)) ? "{id}" : String(segment)
        }
        return (url.host() ?? "") + path.joined(separator: "/")
    }

    static func isIDLike(_ segment: String) -> Bool {
        if LiveCheckPolicy.isID(segment) { return true }
        return segment.count >= 8 && segment.contains(where: \.isNumber)
            && segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func recordUnrecorded(_ create: UnrecordedCreate) {
        lock.withLock {
            unrecordedStorage.append(create)
            if let unrecordedFile, let line = try? JSONEncoder().encode(create) { Self.appendLine(line, to: unrecordedFile) }
        }
    }

    /// Every create of the run’s file the ledger doesn’t hold, from every test process so far.
    public static func unrecordedCreates(in file: URL) -> [UnrecordedCreate] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(UnrecordedCreate.self, from: Data($0.utf8)) }
    }

    /// Every refusal the run’s file holds, from every test process so far.
    public static func refusals(in file: URL) -> [LiveRefusal] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(LiveRefusal.self, from: Data($0.utf8)) }
    }

    /// After an allowed request answered: records creates, removals and Apple tokens.
    func didAnswer(_ allowed: LiveDecision.Allowed, request: LiveRequest, status: Int, body: Data) {
        switch allowed.kind {
        case .create(let name) where (200..<300).contains(status):
            let resource = allowed.resource ?? ""
            guard let id = LiveCheckPolicy.createdID(in: body) else {
                recordUnrecorded(.init(resource: resource, name: name, status: status, reason: "its answer held no readable ID"))
                return
            }
            do {
                try policy.ledger.add(.init(target: allowed.target, resource: resource, id: id, name: name, confirmed: true),
                                      testPrefixes: [policy.prefix])
            } catch {
                recordUnrecorded(.init(resource: resource, name: name, status: status, reason: "\(error)"))
            }
        case .signIn where request.url.host() == "account.apple.com" && (200..<300).contains(status):
            if let token = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["access_token"] as? String,
               let clientID = LiveCheckPolicy.formValue("client_id", in: request.body) {
                policy.recordAppleToken(token, clientID: clientID)
            }
        default:
            break
        }
    }
}

// MARK: - Read-back before a change or delete

extension LiveCheckNetwork {
    /// Whether the object a write is about is one test code recorded, not
    /// yet seen on the server under its ledger name.
    func needsCheckBeforeWrite(_ allowed: LiveDecision.Allowed) -> Bool {
        switch allowed.kind {
        case .change, .delete:
            guard let resource = allowed.resource, let id = allowed.id else { return false }
            return policy.ledger.item(target: allowed.target, resource: resource, id: id).map { !$0.confirmed } ?? false
        default:
            return false
        }
    }

    /// Reads the object back before its first change or delete: nil when the
    /// write may go ahead (the server has it under the ledger’s name, which
    /// starts with `JTKTEST `, or it’s gone), else why not. Blocks the calling
    /// (background) queue.
    func checkBeforeWrite(_ allowed: LiveDecision.Allowed, request: URLRequest) -> String? {
        guard let resource = allowed.resource, let id = allowed.id,
              let item = policy.ledger.item(target: allowed.target, resource: resource, id: id), !item.confirmed else { return nil }
        let method = request.httpMethod ?? "write"
        guard let url = request.url, let objectURL = Self.objectURL(url) else {
            return "\(resource) \(id) can’t be read back: \(method) refused"
        }
        var read = Self.readBack(of: request)
        read.url = objectURL
        // The read is decided like any other request.
        if case .refuse(let reason) = policy.decide(LiveRequest(read, body: nil)) {
            return "\(resource) \(id) can’t be read back (\(reason)): \(method) refused"
        }
        guard let (status, body) = fetch(read) else {
            return "\(resource) \(id) couldn’t be read back: \(method) refused"
        }
        let serverName: String?
        if (200..<300).contains(status) {
            serverName = Self.serverName(in: body)
        } else if Self.answersGone(status: status, body: body) {
            // Gone: nothing there to change or remove (the delete’s own
            // read-back decides). Jamf can answer 404 for a device group it
            // still lists: then its name in the list counts.
            guard Self.isPlatformDeviceGroup(url) else { return nil }
            switch platformGroup(id: item.id, like: request) {
            case nil: return "\(resource) \(id) couldn’t be read back: \(method) refused"
            case .some(nil): return nil
            case .some(let group?): serverName = group["groupName"] as? String
            }
        } else {
            return "\(resource) \(id) couldn’t be read back (HTTP \(status)): \(method) refused"
        }
        guard let serverName, serverName == item.name, serverName.hasPrefix(LiveCheckRun.testPrefix + " ") else {
            return "\(resource) \(id) is “\(serverName ?? "unnamed")” on the server, not the ledger’s “\(item.name)”: \(method) refused"
        }
        do {
            try policy.ledger.confirm(target: item.target, resource: resource, id: id)
        } catch {
            return "\(error): \(method) refused"
        }
        return nil
    }

    /// The object’s own address: the path up to its ID (`…/categories/12`
    /// for `…/categories/12/history`, `…/scripts/id/7`), no query.
    static func objectURL(_ url: URL) -> URL? {
        let encoded = url.path(percentEncoded: true).split(separator: "/").map(String.init)
        let decoded = encoded.map { $0.removingPercentEncoding ?? $0 }
        var end: Int?
        for (index, segment) in decoded.enumerated() {
            if segment.lowercased() == "id", index + 1 < decoded.count, LiveCheckPolicy.isID(decoded[index + 1]) {
                end = index + 1
                break
            }
            if LiveCheckPolicy.isID(segment) {
                end = index
                break
            }
        }
        guard let end, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedPath = "/" + encoded[...end].joined(separator: "/")
        components.query = nil
        return components.url
    }

    /// An object’s name in a read-back: JSON `name` or `displayName` (also in
    /// `general`, also inside Classic JSON’s one wrapping key), or the first
    /// `<name>` of Classic XML.
    static func serverName(in body: Data) -> String? {
        func named(_ object: [String: Any]) -> String? {
            (object["name"] as? String) ?? (object["displayName"] as? String)
                ?? (object["general"] as? [String: Any])?["name"] as? String
        }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let name = named(object) { return name }
            if object.count == 1, let inner = object.values.first as? [String: Any] { return named(inner) }
            return nil
        }
        return LiveCheckPolicy.objectName(in: body)
    }
}

// MARK: - Delete read-back

extension LiveCheckNetwork {
    /// After a delete answered: reads the object back and marks it removed
    /// only when it’s gone. Blocks the calling (background) queue; the
    /// client gets the delete’s answer afterwards, so a check that looks at
    /// the ledger right after a delete sees the confirmed state.
    func confirmDelete(_ allowed: LiveDecision.Allowed, request: URLRequest, status: Int) {
        guard let resource = allowed.resource, let id = allowed.id else { return }
        // An error answer (422 has dependencies, 5xx…) deleted nothing: the
        // object stays outstanding and the client may try again.
        guard (200..<300).contains(status) || status == 404 || status == 410 else { return }
        let item = policy.ledger.item(target: allowed.target, resource: resource, id: id)
        let attempts = resource == "deleteditems" ? readBack.recycleBinAttempts : readBack.attempts
        var gone = waitUntilGone(request, resource: resource, id: id, attempts: attempts)
        var throughJamfPro = false
        // A Platform device group the Platform delete left in place: once
        // more through the Jamf Pro API, only for a group in this run’s
        // ledger, matched by its Platform ID and exact name.
        if !gone, let item, !item.removed, Self.isPlatformDeviceGroup(request.url) {
            throughJamfPro = deleteThroughJamfPro(request, item: item)
            if throughJamfPro { gone = waitUntilGone(request, resource: resource, id: id, attempts: attempts) }
        }
        if gone, item != nil {
            // A failed write breaks the ledger, which fails the run.
            try? policy.ledger.recordRemoval(target: allowed.target, resource: resource, id: id)
        }
        let outcome = DeleteOutcome(resource: resource, id: id, name: item?.name ?? "", status: status,
                                    confirmed: gone, throughJamfPro: throughJamfPro)
        lock.withLock {
            deleteStorage.append(outcome)
            if let deletesFile, let line = try? JSONEncoder().encode(outcome) {
                Self.appendLine(line, to: deletesFile)
            }
        }
    }

    private func waitUntilGone(_ request: URLRequest, resource: String, id: String, attempts: Int) -> Bool {
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { Thread.sleep(forTimeInterval: readBack.interval) }
            switch isGone(request, id: id) {
            case true?: return true
            case false?, nil: continue
            }
        }
        return false
    }

    /// true: gone; false: still there; nil: couldn’t tell (counts as there).
    private func isGone(_ deleted: URLRequest, id: String) -> Bool? {
        guard let url = deleted.url else { return nil }
        let read = Self.readBack(of: deleted)
        guard let (status, body) = fetch(read) else { return nil }
        let sameAddressGone = Self.answersGone(status: status, body: body)
        if (200..<300).contains(status) { return false }
        guard sameAddressGone else { return nil }
        // Jamf can answer 404 for a device group it still lists (seen
        // 2026-10-30): it’s gone only when the group list agrees.
        if Self.isPlatformDeviceGroup(url) {
            return platformGroup(id: id, like: deleted).map { $0 == nil }
        }
        return true
    }

    /// A GET of the same address with the same sign-in, and nothing of the
    /// write’s body: no body, `Content-Type`, `Content-Length` or
    /// `Transfer-Encoding` (Jamf Pro answers 400 to a GET that announces a body).
    static func readBack(of request: URLRequest) -> URLRequest {
        var read = request
        read.httpMethod = "GET"
        read.httpBody = nil
        read.httpBodyStream = nil
        for header in ["Content-Type", "Content-Length", "Transfer-Encoding"] {
            read.setValue(nil, forHTTPHeaderField: header)
        }
        return read
    }

    /// 404 or 410, or Graph’s and Jamf’s "not found" in a 400 or 404 body.
    static func answersGone(status: Int, body: Data) -> Bool {
        if status == 404 || status == 410 { return true }
        guard status == 400 else { return false }
        let text = String(decoding: body, as: UTF8.self)
        return text.contains("ResourceNotFound") || text.contains("NOT_FOUND")
    }

    static func isPlatformDeviceGroup(_ url: URL?) -> Bool {
        guard let url, let host = url.host()?.lowercased(), LiveCheckPolicy.platformRegion(host: host) != nil else { return false }
        let segments = url.path(percentEncoded: false).split(separator: "/").map { $0.lowercased() }
        return segments.count == 4 && segments[0] == "device-groups" && segments[2] == "device-groups"
    }

    /// A Platform device group in Jamf’s group list (`pro/v2/groups`):
    /// .some(nil) when not listed, nil when the list can’t be read.
    private func platformGroup(id: String, like deleted: URLRequest) -> [String: Any]?? {
        guard let host = deleted.url?.host() else { return nil }
        for page in 0..<50 {
            guard let url = URL(string: "https://\(host)/pro/v2/groups?page=\(page)&page-size=200") else { return nil }
            var read = URLRequest(url: url)
            read.allHTTPHeaderFields = deleted.allHTTPHeaderFields
            read.httpMethod = "GET"
            read.setValue(nil, forHTTPHeaderField: "Content-Type")
            guard let (status, body) = fetch(read), (200..<300).contains(status),
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let results = object["results"] as? [[String: Any]] else { return nil }
            if let group = results.first(where: { ($0["groupPlatformId"] as? String)?.lowercased() == id.lowercased() }) {
                return .some(group)
            }
            if results.count < 200 { return .some(nil) }
        }
        return nil
    }

    /// Deletes a still-listed Platform group’s Classic twin through the
    /// gateway’s Jamf Pro (Classic) API. True when the delete was sent.
    ///
    /// The twin’s type comes from the list’s device type (COMPUTER or
    /// MOBILE; any other is refused), and it’s read back first: its name
    /// must be the ledger’s. The delete is then recorded as the group’s alias
    /// in the ledger and decided by the policy like any other request; every
    /// refusal goes into the report.
    private func deleteThroughJamfPro(_ deleted: URLRequest, item: Ledger.Item) -> Bool {
        guard policy.writesAllowed, let host = deleted.url?.host(),
              case let group?? = platformGroup(id: item.id, like: deleted),
              group["groupName"] as? String == item.name,
              let jamfProID = (group["groupJamfProId"] as? String) ?? (group["groupJamfProId"] as? NSNumber)?.stringValue,
              !jamfProID.isEmpty, jamfProID.allSatisfy(\.isNumber) else { return false }
        func request(_ kind: String) -> URLRequest? {
            guard let url = URL(string: "https://\(host)/proclassic/\(kind)/id/\(jamfProID)") else { return nil }
            var delete = URLRequest(url: url)
            delete.allHTTPHeaderFields = deleted.allHTTPHeaderFields
            delete.httpMethod = "DELETE"
            delete.setValue(nil, forHTTPHeaderField: "Content-Type")
            return delete
        }
        guard let kind = Self.classicGroupKind(group) else {
            if let unknown = request("groups") {
                _ = refuse(LiveRequest(unknown, body: nil), reason: "Platform group “\(item.name)” has no COMPUTER or MOBILE device type in Jamf’s group list: its Jamf Pro twin isn’t deleted")
            }
            return false
        }
        guard let delete = request(kind) else { return false }
        let seen = LiveRequest(delete, body: nil)
        var read = Self.readBack(of: delete)
        read.setValue("application/xml", forHTTPHeaderField: "Accept")
        guard let (status, body) = fetch(read), (200..<300).contains(status), Self.serverName(in: body) == item.name else {
            _ = refuse(seen, reason: "\(kind) \(jamfProID) isn’t “\(item.name)” when read back: the Jamf Pro delete of the Platform group’s twin is refused")
            return false
        }
        do {
            try policy.ledger.addAlias(target: item.target, resource: item.resource, id: item.id, aliasResource: kind, aliasID: jamfProID)
        } catch {
            _ = refuse(seen, reason: "\(error)")
            return false
        }
        switch policy.decide(seen) {
        case .allow(let allowed) where allowed.kind == .delete:
            return fetch(delete) != nil
        case .allow:
            _ = refuse(seen, reason: "The Jamf Pro fallback is only ever a delete")
            return false
        case .refuse(let reason):
            _ = refuse(seen, reason: reason)
            return false
        }
    }

    /// `computergroups` or `mobiledevicegroups` for an entry of Jamf’s group
    /// list, by its device type (`deviceType`, or `groupType` where the list
    /// puts COMPUTER or MOBILE there); nil for anything else.
    static func classicGroupKind(_ group: [String: Any]) -> String? {
        for key in ["deviceType", "groupType"] {
            switch (group[key] as? String)?.uppercased() {
            case "COMPUTER": return "computergroups"
            case "MOBILE", "MOBILE_DEVICE": return "mobiledevicegroups"
            default: continue
            }
        }
        return nil
    }

    /// One request through `upstream`, waited for.
    private func fetch(_ request: URLRequest) -> (Int, Data)? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Int, Data)?
        upstream.dataTask(with: request) { data, response, _ in
            if let response = response as? HTTPURLResponse { result = (response.statusCode, data ?? Data()) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }

    static func appendLine(_ line: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let data = line + Data("\n".utf8)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    /// Every delete of the run’s file, from every test process so far.
    public static func deletes(in file: URL) -> [DeleteOutcome] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(DeleteOutcome.self, from: Data($0.utf8)) }
    }
}

/// Decides every request of a live-check session, then sends it on.
nonisolated final class LiveCheckURLProtocol: URLProtocol, @unchecked Sendable {
    static let networkHeader = "X-JTKit-Live-Check"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var networks: [String: LiveCheckNetwork] = [:]

    static func register(_ network: LiveCheckNetwork, id: String) {
        lock.withLock { networks[id] = network }
    }

    private let stateLock = NSLock()
    private var upstreamTask: URLSessionDataTask?
    private var stopped = false
    private static let appleQueue = DispatchQueue(label: "JTKitLiveCheck.apple-budget", attributes: .concurrent)
    private static let readBackQueue = DispatchQueue(label: "JTKitLiveCheck.read-back", attributes: .concurrent)

    override class func canInit(with request: URLRequest) -> Bool { true }

    private static let originalTimeoutKey = "JTKitLiveCheck.originalTimeout"

    /// A write waits for its read-backs before the client hears back: its
    /// timeout is raised above the longest (the server still gets the original).
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        guard let method = request.httpMethod?.uppercased(), method != "GET", method != "HEAD",
              let id = request.value(forHTTPHeaderField: networkHeader),
              let network = lock.withLock({ networks[id] }),
              request.timeoutInterval < network.readBack.longestWait,
              let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return request }
        URLProtocol.setProperty(request.timeoutInterval, forKey: originalTimeoutKey, in: mutable)
        mutable.timeoutInterval = network.readBack.longestWait
        return mutable as URLRequest
    }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.networkHeader),
              let network = Self.lock.withLock({ Self.networks[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let outgoing = {
            var outgoing = request
            outgoing.setValue(nil, forHTTPHeaderField: Self.networkHeader)
            if let original = URLProtocol.property(forKey: Self.originalTimeoutKey, in: request) as? TimeInterval {
                outgoing.timeoutInterval = original
            }
            outgoing.httpBodyStream = nil
            outgoing.httpBody = body.isEmpty ? nil : body
            return outgoing
        }()
        let seen = LiveRequest(outgoing, body: body)

        switch network.policy.decide(seen) {
        case .refuse(let reason):
            client?.urlProtocol(self, didFailWithError: network.refuse(seen, reason: reason))
        case .allow(let allowed) where allowed.target.hasPrefix("apple:"):
            // Apple: wait for the budget off the loading thread, then send.
            Self.appleQueue.async { [self] in
                while true {
                    if stateLock.withLock({ stopped }) { return }
                    switch network.appleBudget.claim(role: allowed.role) {
                    case .go:
                        send(outgoing, allowed: allowed, seen: seen, network: network)
                        return
                    case .wait(let seconds):
                        Thread.sleep(forTimeInterval: min(seconds, 1))
                    case .refuse(let reason):
                        client?.urlProtocol(self, didFailWithError: network.refuse(seen, reason: reason))
                        return
                    }
                }
            }
        case .allow(let allowed) where network.needsCheckBeforeWrite(allowed):
            // An object test code recorded: read back first, off the loading thread.
            Self.readBackQueue.async { [self] in
                if stateLock.withLock({ stopped }) { return }
                if let reason = network.checkBeforeWrite(allowed, request: outgoing) {
                    client?.urlProtocol(self, didFailWithError: network.refuse(seen, reason: reason))
                } else {
                    send(outgoing, allowed: allowed, seen: seen, network: network)
                }
            }
        case .allow(let allowed):
            send(outgoing, allowed: allowed, seen: seen, network: network)
        }
    }

    private func send(_ outgoing: URLRequest, allowed: LiveDecision.Allowed, seen: LiveRequest, network: LiveCheckNetwork) {
        let task = network.upstream.dataTask(with: outgoing) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let data = data ?? Data()
            guard let response = response as? HTTPURLResponse else {
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            network.didAnswer(allowed, request: seen, status: response.statusCode, body: data)
            let answer: @Sendable () -> Void = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            if case .delete = allowed.kind {
                // The client hears back once the read-back has decided.
                Self.readBackQueue.async {
                    network.confirmDelete(allowed, request: outgoing, status: response.statusCode)
                    answer()
                }
            } else {
                answer()
            }
        }
        let cancelled = stateLock.withLock {
            upstreamTask = task
            return stopped
        }
        if cancelled { task.cancel() } else { task.resume() }
    }

    override func stopLoading() {
        let task = stateLock.withLock {
            stopped = true
            return upstreamTask
        }
        task?.cancel()
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
