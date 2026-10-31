import Foundation

extension ABM {
    /// Sends requests to Apple Business or School Manager on JTKit’s
    /// `HTTPClient`:
    ///
    /// - Apple’s limit as the client’s rate limit: at most 18 requests in any
    ///   minute, every attempt counted; each wait is written to the log and
    ///   Cancel stops it.
    /// - Apple’s retry waits (`RetryRules.appleBusiness`): 5, 15 and 45 s,
    ///   or Apple’s `Retry-After`; a dropped connection counts as a drop for
    ///   reads, since that is how Apple’s limit shows. A 401 gets a new token
    ///   and one more try. A write is never repeated after a server error or
    ///   a dropped connection, only after a 429.
    /// - Lists follow `links.next` only to the service’s own address; an
    ///   answer without `data` is an error, and so is reaching 1,000 pages.
    /// - Serial numbers are checked (letters and digits) before they go into
    ///   an address or a query.
    /// - Errors are `ABM.APIError`s in the shared format.
    public final class Client: Sendable {
        public let service: Service
        /// The app’s own hints, added to every error.
        public let hints: [String]
        /// Apple’s limit on this client’s requests; nil only for a demo organization.
        public let rateLimit: RateLimit?
        private let http: HTTPClient
        private let poller: JamfPlatform.Poller
        private let now: @Sendable () -> Date

        /// Records every attempt.
        public var recorder: RequestRecorder { http.recorder }

        /// - Parameters:
        ///   - tokens: usually `ABM.TokenProvider`.
        ///   - recorder: usually `ABM.recorder(_:session:log:connection:)`.
        ///   - rateLimit: Apple’s limit per organization; pass
        ///     `ABM.rateLimit(for:)` of the connection, so only a demo
        ///     connection goes without it.
        ///   - sleep, random, now: injectable for tests; the activity watch
        ///     uses them too.
        public init(
            service: Service,
            tokens: any BearerTokenSource,
            recorder: RequestRecorder,
            hints: [String] = [],
            rateLimit: RateLimit? = ABM.rateLimit,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.service = service
            self.hints = hints
            self.now = now
            self.rateLimit = rateLimit
            http = HTTPClient(baseURL: service.baseURL, tokens: tokens, recorder: recorder,
                              redirects: .sameHostHTTPSOnly, rateLimit: rateLimit, rules: .appleBusiness,
                              sleep: sleep, random: random, now: now)
            let start = ContinuousClock.now
            let startDate = now()
            poller = JamfPlatform.Poller(policy: ABM.activityWatch, sleep: sleep,
                                         now: { start + .seconds(now().timeIntervalSince(startDate)) })
        }

        /// An Apple Business or School Manager connection and its private key.
        ///
        /// - Throws: `ABM.APIError.Kind.invalidRequest` for another service.
        public convenience init(connection: Connection, privateKey: @escaping @Sendable () throws -> String,
                                session: URLSession, log: ActivityLog?, hints: [String] = []) throws {
            guard let service = Service(connection.service) else {
                throw ABM.APIError(.invalidRequest("\(connection.service.displayName) isn’t Apple Business Manager or Apple School Manager."))
            }
            let recorder = ABM.recorder(service, session: session, log: log, connection: connection.name)
            let tokens = ABM.TokenProvider(service: service, clientID: connection.clientID, keyID: connection.keyID,
                                           privateKey: privateKey, recorder: recorder)
            self.init(service: service, tokens: tokens, recorder: recorder, hints: hints,
                      rateLimit: ABM.rateLimit(for: connection))
        }

        // MARK: - Devices

        /// One device; nil when it isn’t in the organization (never enrolled,
        /// or already released).
        public func device(serial: String) async throws -> OrgDevice? {
            let serial = try checked(serial)
            guard let data = try await getUnlessNotFound("v1/orgDevices/\(serial)", recordsBodies: true) else { return nil }
            var device = try decode(Single<Attributes<OrgDevice>>.self, from: data).data.attributes
            if device.serialNumber.isEmpty { device.serialNumber = serial }
            return device
        }

        /// A device’s AppleCare coverage; empty when it isn’t in the organization.
        public func appleCareCoverage(serial: String) async throws -> [AppleCareCoverage] {
            let serial = try checked(serial)
            guard let data = try await getUnlessNotFound("v1/orgDevices/\(serial)/appleCareCoverage",
                                                         recordsBodies: true) else { return [] }
            struct Fields: Decodable {
                let description: String?
                let startDateTime: String?
                let endDateTime: String?
                let status: String?
            }
            return try decode(List<Identified<Fields>>.self, from: data).data.map {
                AppleCareCoverage(id: $0.id, description: $0.attributes?.description, status: $0.attributes?.status,
                                  startDateTime: $0.attributes?.startDateTime, endDateTime: $0.attributes?.endDateTime)
            }
        }

        /// A device’s Activation Lock, or nil when the organization won’t
        /// say: not in it (404), or Apple’s documented server error for a
        /// device in an internal state, which isn’t retried or shown.
        public func activationLock(serial: String) async throws -> ActivationLock? {
            let serial = try checked(serial)
            let response = try await sendUnlessNotFound(HTTPRequest(path: "v1/orgDevices/\(serial)/activationLockStatus",
                                                                    recordsBodies: true, serverErrorIsAnAnswer: true))
            guard let response, (200..<300).contains(response.status) else { return nil }
            struct Fields: Decodable {
                let isLocked: Bool?
                let lockType: String?
            }
            let fields = try decode(Single<Attributes<Fields>>.self, from: response.data).data.attributes
            return ActivationLock(isLocked: fields.isLocked ?? false, lockType: fields.lockType)
        }

        /// The ID of the service a device is assigned to; nil when unassigned
        /// or not in the organization.
        public func assignedServerID(serial: String) async throws -> String? {
            let serial = try checked(serial)
            guard let data = try await getUnlessNotFound("v1/orgDevices/\(serial)/relationships/assignedServer",
                                                         recordsBodies: true) else { return nil }
            struct Reference: Decodable { let data: Item?; struct Item: Decodable { let id: String } }
            return try decode(Reference.self, from: data).data?.id
        }

        /// The organization’s device management services, every page.
        public func mdmServers() async throws -> [MDMServer] {
            struct Fields: Decodable {
                let serverName: String?
                let serverType: String?
                let status: String?
            }
            return try await list("v1/mdmServers", query: [URLQueryItem(name: "limit", value: "100")]).map {
                let item = try decode(Identified<Fields>.self, from: $0)
                return MDMServer(id: item.id, name: item.attributes?.serverName ?? item.id,
                                 serverType: item.attributes?.serverType, status: item.attributes?.status)
            }
        }

        /// Test Connection: a cheap check that the account can sign in and
        /// read. Returns the number of MDM servers.
        @discardableResult
        public func testConnection() async throws -> Int {
            try await mdmServers().count
        }

        @available(*, deprecated, renamed: "testConnection()")
        public func verify() async throws -> Int {
            try await testConnection()
        }

        /// The first `limit` devices of the organization, in Apple’s order, in
        /// one request: no further page is read. For a small sample,
        /// where `organizationSnapshot` would read the whole organization.
        public func firstDevices(limit: Int) async throws -> [OrgDevice] {
            let limit = min(max(limit, 1), 1000)
            let data = try await get("v1/orgDevices", query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "fields[orgDevices]", value: OrgDevice.fields.joined(separator: ",")),
            ], recordsBodies: true)
            return try decode(List<Attributes<OrgDevice>>.self, from: data).data
                .map(\.attributes).filter { !$0.serialNumber.isEmpty }
        }

        /// Reads the whole organization: every device, then each service’s
        /// devices. A service whose list can’t be read (an error answer) is
        /// skipped with a warning, and the devices Apple reports as assigned
        /// that no readable list holds get an unknown assignment. No answer at
        /// all fails the read.
        public func organizationSnapshot(progress: (@Sendable (SnapshotProgress) -> Void)? = nil) async throws -> Snapshot {
            var devices = [String: OrgDevice]()
            try await list("v1/orgDevices", query: [
                URLQueryItem(name: "limit", value: "1000"),
                URLQueryItem(name: "fields[orgDevices]", value: OrgDevice.fields.joined(separator: ",")),
            ], eachPage: { items in
                for item in items {
                    let device = try self.decode(Attributes<OrgDevice>.self, from: item).attributes
                    guard !device.serialNumber.isEmpty else { continue }
                    devices[device.serialNumber.uppercased()] = device
                }
                progress?(.devices(devices.count))
            })

            let servers = try await mdmServers()
            var serverIDBySerial = [String: String]()
            var unreadable = [MDMServer]()
            struct Reference: Decodable { let id: String }
            for (index, server) in servers.enumerated() {
                progress?(.assignments(done: index, total: servers.count))
                do {
                    let items = try await list("v1/mdmServers/\(try RequestPathSegment.checked(server.id))/relationships/devices",
                                               query: [URLQueryItem(name: "limit", value: "1000")])
                    for item in items {
                        serverIDBySerial[try decode(Reference.self, from: item).id.uppercased()] = server.id
                    }
                } catch let error as ABM.APIError where error.status != nil {
                    unreadable.append(server)
                    await recorder.note("GET", "v1/mdmServers/\(server.id)/relationships/devices",
                                        note: "Couldn’t read the devices of “\(server.name)” (HTTP \(error.status ?? 0)); devices that may be on it show an unknown assignment.",
                                        isWarning: true)
                }
            }
            let unknown = unreadable.isEmpty ? Set<String>() : Set(devices.filter { serial, device in
                device.status?.uppercased() == "ASSIGNED" && serverIDBySerial[serial] == nil
            }.keys)
            return Snapshot(devices: devices, serverIDBySerial: serverIDBySerial, servers: servers,
                            unreadableServers: unreadable, unknownAssignments: unknown, capturedAt: now())
        }

        // MARK: - Apple’s built-in management

        /// Every device in Apple’s built-in device management, by serial
        /// (uppercased). The list has no filters, so it is read whole.
        public func appleManagedDevices() async throws -> [String: ManagedDevice] {
            struct Fields: Decodable {
                let serialNumber: String?
                let deviceName: String?
                let productFamily: String?
            }
            var devices = [String: ManagedDevice]()
            for item in try await list("v1/mdmDevices", query: [URLQueryItem(name: "limit", value: "100")]) {
                let device = try decode(Identified<Fields>.self, from: item)
                guard let serial = device.attributes?.serialNumber, !serial.isEmpty else { continue }
                devices[serial.uppercased()] = ManagedDevice(id: device.id, serialNumber: serial,
                                                             deviceName: device.attributes?.deviceName,
                                                             productFamily: device.attributes?.productFamily)
            }
            return devices
        }

        /// One enrolled device’s management state; nil when it is gone.
        public func appleManagedDeviceDetails(id: String) async throws -> ManagedDeviceDetail? {
            guard let data = try await getUnlessNotFound("v1/mdmDevices/\(try RequestPathSegment.checked(id))/details",
                                                         recordsBodies: true) else { return nil }
            return try decode(Single<Attributes<ManagedDeviceDetail>>.self, from: data).data.attributes
        }

        // MARK: - History

        /// A device’s audit events, newest first, one page at a time.
        public func auditEvents(serial: String, start: Date, end: Date, cursor: String? = nil,
                                limit: Int = 100) async throws -> AuditPage {
            let serial = try checked(serial)
            let formatter = ISO8601DateFormatter()
            var query = [
                URLQueryItem(name: "filter[startTimestamp]", value: formatter.string(from: start)),
                URLQueryItem(name: "filter[endTimestamp]", value: formatter.string(from: end)),
                URLQueryItem(name: "filter[subjectId]", value: serial),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let data = try await get("v1/auditEvents", query: query)
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = root["data"] as? [[String: Any]] else {
                throw ABM.APIError(.invalidResponse("The history has no list (“data”)."), service: service, appHints: hints)
            }
            let events = items.compactMap { item -> AuditEvent? in
                guard let id = item["id"] as? String, let attributes = item["attributes"] as? [String: Any] else { return nil }
                // each event type carries its details under its own key
                let payload = (attributes["eventDataPropertyKey"] as? String).flatMap { attributes[$0] as? [String: Any] } ?? [:]
                return AuditEvent(
                    id: id, dateTime: attributes["eventDateTime"] as? String, type: attributes["type"] as? String,
                    actorName: attributes["actorName"] as? String, outcome: attributes["outcome"] as? String,
                    targetServerName: payload["targetServerName"] as? String,
                    sourceServerName: (payload["serverName"] ?? payload["sourceServerName"]) as? String,
                    releaseEntityType: payload["releaseEntityType"] as? String,
                    purchaseSourceType: payload["purchaseSourceType"] as? String)
            }
            let next = ((root["meta"] as? [String: Any])?["paging"] as? [String: Any])?["nextCursor"] as? String
            return AuditPage(events: events.sorted { ($0.dateTime ?? "") > ($1.dateTime ?? "") }, nextCursor: next)
        }

        // MARK: - Writes

        /// Sends a write and returns Apple’s activity ID (nil when Apple
        /// returned none). Never repeated after a server error or a dropped
        /// connection, only after a 429.
        ///
        /// - Throws: `ABM.APIError.Kind.invalidRequest` before sending when Apple
        ///   would refuse it (Release in School, no server or deadline, a
        ///   deadline over 90 days).
        public func submit(_ activity: Activity) async throws -> String? {
            let body: Data
            do {
                body = try activity.body(for: service, now: now())
            } catch var error as ABM.APIError {
                error.appHints = hints
                throw error
            }
            let response = try await send(HTTPRequest(method: "POST", path: "v1/orgDeviceActivities", body: body))
            struct Answer: Decodable { let data: Item?; struct Item: Decodable { let id: String } }
            return (try? JSONDecoder().decode(Answer.self, from: response.data))?.data?.id
        }

        /// One look at an activity.
        public func activityStatus(id: String) async throws -> ActivityStatus {
            let data = try await get("v1/orgDeviceActivities/\(try RequestPathSegment.checked(id))")
            struct Fields: Decodable {
                let status: String?
                let subStatus: String?
                let completedDateTime: String?
            }
            let item = try decode(Single<Identified<Fields>>.self, from: data).data
            return ActivityStatus(id: item.id, status: item.attributes?.status, subStatus: item.attributes?.subStatus,
                                  completedDateTime: item.attributes?.completedDateTime)
        }

        /// Watches an activity until Apple has finished with it, for up to 2
        /// minutes (checks from 2 s, growing to 10 s), and says what became
        /// of it. A check that fails ends the watch as a warning; Cancel
        /// stops it at once.
        public func watch(activityID: String?) async throws -> ActivityOutcome {
            guard let activityID else { return .notFollowed }
            do {
                let result = try await poller.poll(check: { try await self.activityStatus(id: activityID) },
                                                   isDone: \.isFinished)
                switch result {
                case .finished(let status): return status.outcome
                case .timedOut: return .stillProcessing
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .watchFailed(error.localizedDescription)
            }
        }

        /// Sends a write and watches it.
        public func perform(_ activity: Activity) async throws -> ActivityOutcome {
            try await watch(activityID: try await submit(activity))
        }

        // MARK: - Lists

        /// Every item of a list as its own JSON, following `links.next` on
        /// the service’s own address only.
        func list(_ path: String, query: [URLQueryItem]) async throws -> [Data] {
            var items = [Data]()
            try await list(path, query: query) { items += $0 }
            return items
        }

        private func list(_ path: String, query: [URLQueryItem], eachPage: ([Data]) throws -> Void) async throws {
            var request = HTTPRequest(path: path, query: query)
            var pages = 0
            while true {
                try Task.checkCancellation()
                guard pages < ABM.maxPages else {
                    throw ABM.APIError(.pageLimitReached(path: path, pages: pages), service: service, appHints: hints)
                }
                let data = try await send(request).data
                guard let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let elements = page["data"] as? [Any] else {
                    throw ABM.APIError(.invalidResponse("The answer to \(path) has no list (“data”)."), service: service, appHints: hints)
                }
                pages += 1
                try eachPage(try elements.map { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) })
                guard let next = (page["links"] as? [String: Any])?["next"] as? String, !next.isEmpty else { return }
                request = try nextPage(next)
            }
        }

        /// A next-page link as a request; only to the service’s own address.
        private func nextPage(_ link: String) throws -> HTTPRequest {
            guard let url = URL(string: link), url.scheme?.lowercased() == "https", url.host()?.lowercased() == service.host,
                  url.port == nil, url.user() == nil else {
                throw ABM.APIError(.nextPageElsewhere(URL(string: link)?.host() ?? "another address"), service: service, appHints: hints)
            }
            var path = url.path(percentEncoded: true)
            while path.hasPrefix("/") { path.removeFirst() }
            return HTTPRequest(path: path, encodedQuery: url.query(percentEncoded: true))
        }

        // MARK: - Private

        private func checked(_ serial: String) throws -> String {
            do {
                return try ABM.checkedSerial(serial)
            } catch var error as ABM.APIError {
                error.service = service
                error.appHints = hints
                throw error
            }
        }

        private func get(_ path: String, query: [URLQueryItem] = [], recordsBodies: Bool = false) async throws -> Data {
            try await send(HTTPRequest(path: path, query: query, recordsBodies: recordsBodies)).data
        }

        /// Nil for a 404.
        private func getUnlessNotFound(_ path: String, recordsBodies: Bool) async throws -> Data? {
            try await sendUnlessNotFound(HTTPRequest(path: path, recordsBodies: recordsBodies))?.data
        }

        /// Nil for a 404 answer (not for a refused sign-in).
        private func sendUnlessNotFound(_ request: HTTPRequest) async throws -> HTTPResponse? {
            do {
                return try await send(request)
            } catch let error as ABM.APIError {
                if case .status(404, _, _, _) = error.kind { return nil }
                throw error
            }
        }

        private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            do {
                return try await http.send(request)
            } catch let error as HTTPError {
                throw ABM.APIError(error, service: service, appHints: hints)
            } catch var error as ABM.APIError {
                // from the sign-in
                error.appHints = hints + error.appHints
                throw error
            }
        }

        private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw ABM.APIError(.invalidResponse("\(T.self): \(error.localizedDescription)"), service: service, appHints: hints)
            }
        }

        private struct Single<T: Decodable>: Decodable { let data: T }
        private struct List<T: Decodable>: Decodable { let data: [T] }
        private struct Attributes<T: Decodable>: Decodable { let attributes: T }
        private struct Identified<T: Decodable>: Decodable {
            let id: String
            let attributes: T?
        }
    }
}

/// One path segment from an answer (an ID), checked before it goes into an
/// address: no slashes, dots or encoding tricks.
nonisolated enum RequestPathSegment {
    static func checked(_ segment: String) throws -> String {
        guard !segment.isEmpty, RequestPath.isSafe(segment), !segment.contains("/"), !segment.contains("%") else {
            throw ABM.APIError(.invalidResponse("“\(segment)” can’t be part of an address."))
        }
        return segment
    }
}
