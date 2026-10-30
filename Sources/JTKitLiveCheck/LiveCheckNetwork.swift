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

/// How long a delete's read-back keeps looking (0.12.6): Jamf removes some
/// objects (a deployed Blueprint) in the background.
public nonisolated struct ReadBack: Sendable {
    public var attempts: Int
    public var interval: TimeInterval
    /// For a permanent delete from Entra's recycle bin, which Entra can
    /// keep showing for a while (0.12.7).
    public var recycleBinAttempts: Int

    public init(attempts: Int, interval: TimeInterval, recycleBinAttempts: Int? = nil) {
        self.attempts = attempts
        self.interval = interval
        self.recycleBinAttempts = recycleBinAttempts ?? attempts
    }

    /// About a minute; two for the recycle bin.
    public static let standard = ReadBack(attempts: 12, interval: 5, recycleBinAttempts: 24)
}

/// What a delete's read-back found, one JSON line each in the run's
/// `deletes.jsonl` for the report (0.12.6).
public nonisolated struct DeleteOutcome: Sendable, Equatable, Codable {
    public var resource: String
    public var id: String
    public var name: String
    /// The delete's own answer (never counted on its own).
    public var status: Int
    /// The read-back found the object gone.
    public var confirmed: Bool
    /// A Platform device group still listed after its Platform delete was
    /// deleted again through the Jamf Pro API (its Classic twin).
    public var throughJamfPro: Bool
}

/// The live check's network: give its `session` to the app's
/// `RequestRecorder`, where demo mode gives its own. Every request is decided
/// by the `LiveCheckPolicy` before it's sent; allowed ones go out through
/// `upstream`, refused ones fail with `LiveCheckRefused` and nothing leaves
/// the Mac. Successful creates are written to the ledger. A delete is marked
/// removed only once a read-back finds the object gone (0.12.6): its answer,
/// 200 or 404, never counts on its own.
public nonisolated final class LiveCheckNetwork: @unchecked Sendable {
    public let policy: LiveCheckPolicy
    public let session: URLSession
    let upstream: URLSession

    /// Where each refusal is appended the moment it happens (0.12.3), one
    /// JSON line each: every test of a release check runs in its own process,
    /// so a file shared by the run keeps them all for the report.
    let refusalsFile: URL?

    /// Paces every Apple request and caps them per run (0.12.4).
    public let appleBudget: AppleRequestBudget

    let readBack: ReadBack
    let deletesFile: URL?
    private var deleteStorage: [DeleteOutcome] = []

    /// Every delete's read-back so far in this process.
    public var deletes: [DeleteOutcome] { lock.withLock { deleteStorage } }

    private let lock = NSLock()
    private var refusedStorage: [LiveRefusal] = []

    /// - Parameters:
    ///   - upstream: where allowed requests go; a fresh ephemeral session by
    ///     default (tests pass a mock).
    ///   - refusalsFile: the run's `refusals.jsonl` (`LiveCheckRun` passes it).
    ///   - appleRequestsFile: the run's `apple-requests.jsonl`, so the Apple
    ///     budget is shared by the run's test processes (`LiveCheckRun` passes it).
    ///   - appleBudget: replaces the standard budget (9 a minute, 40 a run per
    ///     organisation); JTKit's own tests use a small one.
    ///   - readBack: how long a delete's read-back keeps looking.
    ///   - deletesFile: the run's `deletes.jsonl` (`LiveCheckRun` passes it).
    public init(policy: LiveCheckPolicy, upstream: URLSession = LiveCheckNetwork.makeUpstream(), refusalsFile: URL? = nil,
                appleRequestsFile: URL? = nil, appleBudget: AppleRequestBudget? = nil,
                readBack: ReadBack = .standard, deletesFile: URL? = nil) {
        self.policy = policy
        self.upstream = upstream
        self.refusalsFile = refusalsFile
        self.readBack = readBack
        self.deletesFile = deletesFile
        self.appleBudget = appleBudget ?? AppleRequestBudget(file: appleRequestsFile)
        let id = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveCheckURLProtocol.self]
        configuration.httpAdditionalHeaders = [LiveCheckURLProtocol.networkHeader: id]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
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
        let refusal = LiveRefusal(method: request.method,
                                  location: "\(request.url.host() ?? "")\(request.url.path(percentEncoded: false))",
                                  reason: reason)
        lock.withLock {
            refusedStorage.append(refusal)
            if let refusalsFile { Self.append(refusal, to: refusalsFile) }
        }
        return LiveCheckRefused(refusal: refusal)
    }

    /// Appends one line; `O_APPEND` keeps lines whole when two processes write.
    static func append(_ refusal: LiveRefusal, to file: URL) {
        guard let line = try? JSONEncoder().encode(refusal) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let data = line + Data("\n".utf8)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    /// Every refusal the run's file holds, from every test process so far.
    public static func refusals(in file: URL) -> [LiveRefusal] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(LiveRefusal.self, from: Data($0.utf8)) }
    }

    /// After an allowed request answered: records creates, removals and Apple tokens.
    func didAnswer(_ allowed: LiveDecision.Allowed, request: LiveRequest, status: Int, body: Data) {
        switch allowed.kind {
        case .create(let name) where (200..<300).contains(status):
            guard let resource = allowed.resource, let id = LiveCheckPolicy.createdID(in: body) else { return }
            try? policy.ledger.add(.init(target: allowed.target, resource: resource, id: id, name: name),
                                   testPrefixes: [policy.prefix])
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

// MARK: - Delete read-back (0.12.6)

extension LiveCheckNetwork {
    /// After a delete answered: reads the object back and marks it removed
    /// only when it's gone. Blocks the calling (background) queue; the
    /// client gets the delete's answer afterwards, so a check that looks at
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
        // more through the Jamf Pro API, only for a group in this run's
        // ledger, matched by its Platform ID and exact name.
        if !gone, let item, !item.removed, Self.isPlatformDeviceGroup(request.url) {
            throughJamfPro = deleteThroughJamfPro(request, item: item)
            if throughJamfPro { gone = waitUntilGone(request, resource: resource, id: id, attempts: attempts) }
        }
        if gone, item != nil {
            policy.ledger.markRemoved(target: allowed.target, resource: resource, id: id)
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

    /// true: gone; false: still there; nil: couldn't tell (counts as there).
    private func isGone(_ deleted: URLRequest, id: String) -> Bool? {
        guard let url = deleted.url else { return nil }
        var read = deleted
        read.httpMethod = "GET"
        read.httpBody = nil
        read.httpBodyStream = nil
        read.setValue(nil, forHTTPHeaderField: "Content-Type")
        guard let (status, body) = fetch(read) else { return nil }
        let sameAddressGone = Self.answersGone(status: status, body: body)
        if (200..<300).contains(status) { return false }
        guard sameAddressGone else { return nil }
        // Jamf can answer 404 for a device group it still lists (seen
        // 2026-10-30): it's gone only when the group list agrees.
        if Self.isPlatformDeviceGroup(url) {
            return platformGroup(id: id, like: deleted).map { $0 == nil }
        }
        return true
    }

    /// 404 or 410, or Graph's and Jamf's "not found" in a 400 or 404 body.
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

    /// A Platform device group in Jamf's group list (`pro/v2/groups`):
    /// .some(nil) when not listed, nil when the list can't be read.
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

    /// Deletes a still-listed Platform group's Classic twin through the
    /// gateway's Jamf Pro (Classic) API. True when the delete was sent.
    private func deleteThroughJamfPro(_ deleted: URLRequest, item: Ledger.Item) -> Bool {
        guard policy.writesAllowed, let host = deleted.url?.host(),
              case let group?? = platformGroup(id: item.id, like: deleted),
              group["groupName"] as? String == item.name,
              let jamfProID = (group["groupJamfProId"] as? String) ?? (group["groupJamfProId"] as? NSNumber)?.stringValue,
              !jamfProID.isEmpty, jamfProID.allSatisfy(\.isNumber) else { return false }
        let kind = (group["groupType"] as? String)?.uppercased() == "MOBILE" ? "mobiledevicegroups" : "computergroups"
        guard let url = URL(string: "https://\(host)/proclassic/\(kind)/id/\(jamfProID)") else { return false }
        var delete = URLRequest(url: url)
        delete.allHTTPHeaderFields = deleted.allHTTPHeaderFields
        delete.httpMethod = "DELETE"
        delete.setValue(nil, forHTTPHeaderField: "Content-Type")
        return fetch(delete) != nil
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

    /// Every delete of the run's file, from every test process so far.
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

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.networkHeader),
              let network = Self.lock.withLock({ Self.networks[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var outgoing = request
        outgoing.setValue(nil, forHTTPHeaderField: Self.networkHeader)
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        outgoing.httpBodyStream = nil
        outgoing.httpBody = body.isEmpty ? nil : body
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
            let answer = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            if case .delete = allowed.kind {
                // The client hears back once the read-back has decided (0.12.6).
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
