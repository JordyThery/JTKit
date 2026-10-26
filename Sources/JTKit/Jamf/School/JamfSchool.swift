import Foundation

/// The Jamf School API (`https://{school}.jamfcloud.com/api/…`): devices,
/// details, groups, locations, Automated Device Enrollment and asset tags.
///
/// Signs in on every request with HTTP Basic: the Network ID as user, the API
/// key as password. The activity log shows the header as "Basic <redacted>".
public nonisolated enum JamfSchool {
    /// A device, from the device list or the single-device endpoint.
    ///
    /// The two return the same values with different types (`lastCheckin` is
    /// a string in one and an object with the instance's time zone in the
    /// other; flags are booleans or 0/1), so every field is read leniently and
    /// an empty string reads as nil.
    public struct Device: Decodable, Hashable, Sendable {
        public var udid: String
        public var serialNumber: String?
        public var name: String?
        public var assetTag: String?
        public var modelName: String?
        public var modelIdentifier: String?
        /// e.g. "iOS", "macOS".
        public var osPrefix: String?
        public var osVersion: String?
        /// e.g. "iPad", "mac".
        public var deviceClass: String?
        public var ownerName: String?
        public var ownerUsername: String?
        public var ownerEmail: String?
        public var isManaged: Bool?
        public var isSupervised: Bool?
        public var inTrash: Bool?
        public var locationID: String?
        public var groups: [String]
        public var enrollType: String?
        public var depProfile: String?
        /// The last check-in. In the instance's time zone when the answer
        /// names it (the single-device endpoint), otherwise the Mac's.
        public var lastCheckIn: Date?
        /// The instance's time zone, e.g. "Europe/Brussels" (single-device endpoint only).
        public var timeZone: String?
        // single-device endpoint only
        public var hasPasscode: Bool?
        public var passcodeCompliant: Bool?
        public var isBootstrapStored: Bool?

        public init(udid: String, serialNumber: String? = nil, name: String? = nil, assetTag: String? = nil,
                    modelName: String? = nil, modelIdentifier: String? = nil, osPrefix: String? = nil,
                    osVersion: String? = nil, deviceClass: String? = nil, ownerName: String? = nil,
                    ownerUsername: String? = nil, ownerEmail: String? = nil, isManaged: Bool? = nil,
                    isSupervised: Bool? = nil, inTrash: Bool? = nil, locationID: String? = nil, groups: [String] = [],
                    enrollType: String? = nil, depProfile: String? = nil, lastCheckIn: Date? = nil,
                    timeZone: String? = nil, hasPasscode: Bool? = nil, passcodeCompliant: Bool? = nil,
                    isBootstrapStored: Bool? = nil) {
            self.udid = udid
            self.serialNumber = serialNumber
            self.name = name
            self.assetTag = assetTag
            self.modelName = modelName
            self.modelIdentifier = modelIdentifier
            self.osPrefix = osPrefix
            self.osVersion = osVersion
            self.deviceClass = deviceClass
            self.ownerName = ownerName
            self.ownerUsername = ownerUsername
            self.ownerEmail = ownerEmail
            self.isManaged = isManaged
            self.isSupervised = isSupervised
            self.inTrash = inTrash
            self.locationID = locationID
            self.groups = groups
            self.enrollType = enrollType
            self.depProfile = depProfile
            self.lastCheckIn = lastCheckIn
            self.timeZone = timeZone
            self.hasPasscode = hasPasscode
            self.passcodeCompliant = passcodeCompliant
            self.isBootstrapStored = isBootstrapStored
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let udid = c.text("UDID") ?? c.text("udid") else {
                throw DecodingError.keyNotFound(AnyKey("UDID"), .init(codingPath: c.codingPath, debugDescription: "A device without a UDID."))
            }
            self.udid = udid
            serialNumber = c.text("serialNumber")
            name = c.text("name")
            assetTag = c.text("assetTag")
            let model = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "model")
            modelName = model?.text("name")
            modelIdentifier = model?.text("identifier")
            let os = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "os")
            osPrefix = os?.text("prefix")
            osVersion = os?.text("version")
            deviceClass = c.text("class")
            let owner = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "owner")
            ownerName = owner?.text("name")
            ownerUsername = owner?.text("username")
            ownerEmail = owner?.text("email")
            isManaged = c.flag("isManaged")
            isSupervised = c.flag("isSupervised")
            inTrash = c.flag("inTrash")
            locationID = c.text("locationId")
            groups = ((try? c.decodeIfPresent([String].self, forKey: "groups")) ?? nil) ?? []
            enrollType = c.text("enrollType") ?? c.text("deviceEnrollType")
            depProfile = c.text("depProfile") ?? c.text("deviceDepProfile")
            if let checkIn = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "lastCheckin") {
                timeZone = checkIn.text("timezone")
                lastCheckIn = JamfSchool.date(checkIn.text("date"), timeZone: timeZone.flatMap(TimeZone.init(identifier:)))
            } else {
                lastCheckIn = JamfSchool.date(c.text("lastCheckin"), timeZone: nil)
            }
            hasPasscode = c.flag("hasPasscode")
            passcodeCompliant = c.flag("passcodeCompliant")
            isBootstrapStored = c.flag("isBootstrapStored")
        }
    }

    /// A device group. Jamf School doesn't split them by device kind.
    public struct Group: Decodable, Hashable, Sendable {
        public var id: String
        public var name: String?
        public var isSmartGroup: Bool?
        public var members: Int?

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.text("id") ?? ""
            name = c.text("name")
            isSmartGroup = c.flag("isSmartGroup")
            members = c.number("members")
        }
    }

    public struct Location: Decodable, Hashable, Sendable {
        public var id: String
        public var name: String?
        public var isDistrict: Bool?

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.text("id") ?? ""
            name = c.text("name")
            isDistrict = c.flag("isDistrict")
        }
    }

    /// A device waiting in Automated Device Enrollment (a "placeholder").
    public struct EnrollmentPlaceholder: Decodable, Hashable, Sendable {
        public var serialNumber: String?
        /// e.g. "assigned", "removed".
        public var status: String?

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            serialNumber = c.text("serialNumber")
            status = c.text("status")
        }
    }

    /// Reads "yyyy-MM-dd HH:mm:ss", ignoring fractional seconds. Without a
    /// time zone the Mac's own is assumed.
    public static func date(_ text: String?, timeZone: TimeZone?) -> Date? {
        guard let text, text.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = timeZone ?? .current
        return formatter.date(from: String(text.prefix(19)))
    }

    /// The address the API is under: scheme added when missing, trailing
    /// slashes and a trailing `/api` (as Jamf School's documentation writes
    /// it) dropped. Nil when it isn't an HTTPS address with a host.
    public static func baseURL(_ address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api") { text.removeLast(4) }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", !(url.host() ?? "").isEmpty else { return nil }
        return url
    }
}

// MARK: - Errors

/// Why a Jamf School request failed: what Jamf School said, in words a user
/// can act on, then hints. Everything shown goes through `Redaction`.
public nonisolated struct JamfSchoolError: Error, LocalizedError, Sendable {
    public enum Kind: Sendable {
        /// Not sent: not a request the app makes, or an unsafe path.
        case refused(method: String, path: String)
        /// No answer from the server.
        case transport(method: String, path: String, code: URLError.Code, message: String)
        /// A failure, by the HTTP status or by the answer's own `code` or
        /// `message` (Jamf School can fail under HTTP 200).
        case status(Int, message: String?, reason: String?, method: String, path: String)
        /// The answer isn't what Jamf School sends, e.g. a web page from a wrong address.
        case invalidResponse(String)
        /// Not sent: a serial number or UDID with characters it can't hold.
        case invalidIdentifier(String)
        /// Not sent: the connection has no usable address, Network ID or API key.
        case incomplete(String)
    }

    public var kind: Kind
    public var appHints: [String]

    public init(_ kind: Kind, appHints: [String] = []) {
        self.kind = kind
        self.appHints = appHints
    }

    /// The status that describes the failure, whichever part of the answer carried it.
    public var status: Int? {
        if case let .status(status, _, _, _, _) = kind { return status }
        return nil
    }

    /// Jamf School's own word for the failure, e.g. "DeviceNotFound".
    public var serverMessage: String? {
        if case let .status(_, message, _, _, _) = kind { return message }
        return nil
    }

    /// "The device is not in this Jamf School instance", as a lookup reads it.
    public var isDeviceNotFound: Bool { serverMessage == "DeviceNotFound" }

    /// The hints every app shows for this error.
    public var standardHints: [String] {
        switch kind {
        case .status(401, _, _, _, _), .status(403, _, _, _, _):
            ["Check the Network ID and API key, and that the API key is granted this method in Jamf School under Organization › Settings › API."]
        case let .status(404, message, _, _, _) where message != "DeviceNotFound" && message != "LocationNotFound":
            ["Check the Jamf School address, e.g. https://yourschool.jamfcloud.com."]
        case .status(429, _, _, _, _):
            ["Jamf School is limiting how many requests this app sends. Wait a minute, then try again."]
        case let .status(status, _, _, _, _) where (500..<600).contains(status):
            ["Jamf School had a problem answering. Try again in a few minutes."]
        case .invalidResponse:
            ["Check the Jamf School address, e.g. https://yourschool.jamfcloud.com."]
        default:
            []
        }
    }

    public func message(appHints extraHints: [String] = []) -> String {
        var lines: [String]
        switch kind {
        case let .refused(method, path):
            lines = ["Refused before sending: \(method) \(path) is not a request this app makes."]
        case let .transport(_, _, _, message):
            lines = ["Network error: \(message)"]
        case let .status(status, message, reason, _, _):
            let detail = [message, reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
            lines = ["Jamf School: " + Self.explain(status, message: message) + (detail.isEmpty ? "" : " (\(detail))")]
        case let .invalidResponse(message):
            lines = ["Unexpected response from Jamf School: \(message)"]
        case let .invalidIdentifier(value):
            lines = ["“\(value)” is not a serial number or UDID: only letters, digits and hyphens are allowed."]
        case let .incomplete(message):
            lines = [message]
        }
        for hint in appHints + extraHints + standardHints where !lines.contains(hint) {
            lines.append(hint)
        }
        return Redaction.text(lines.joined(separator: "\n"))
    }

    public var errorDescription: String? { message() }

    /// Keyed on the message rather than the code: the message is the signal
    /// that is always there, and "HTTP 200" says nothing about a failure the
    /// body named.
    static func explain(_ status: Int, message: String?) -> String {
        switch message {
        case "DeviceNotFound": "the device is not in this Jamf School instance."
        case "LocationNotFound": "that location no longer exists."
        case "DeviceNotActive": "the device is trashed or inactive, so it cannot be sent commands."
        case "TooManyDevices": "too many devices in one request."
        case "DeviceNotMigratable", "MigrationFailed":
            "the device cannot be moved, because its owner is not in the district and cross-location enrollment is off."
        case "UnlockFailed":
            "Apple would not clear the lock. Its service may be unreachable, or no bypass code is escrowed for this device."
        case "UDIDArrayEmpty": "the request carried no devices."
        case "MissingParameter": "the request was missing a required value."
        default: "HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"
        }
    }

    /// Messages that mean the request didn't do what was asked. A known-bad
    /// list, so a message never seen before still counts as a success.
    static let failureMessages: Set<String> = [
        "UnlockFailed", "DeviceNotFound", "LocationNotFound", "DeviceNotActive",
        "DeviceNotMigratable", "MigrationFailed", "UDIDArrayEmpty", "TooManyDevices",
        "MissingParameter", "LocationSame",
    ]

    /// Fails on anything that isn't a success, whichever way Jamf School says
    /// so: the HTTP status, the body's `code` (also wrapped in `error`), or a
    /// known failure `message` (some endpoints send no `code` at all).
    static func check(status: Int, data: Data, method: String, path: String) throws {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                let code: Code?
                let message: String?
            }
            struct Code: Decodable {
                let value: Int?
                init(from decoder: any Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if let int = try? c.decode(Int.self) { value = int }
                    else { value = Int((try? c.decode(String.self)) ?? "") }
                }
            }
            let code: Code?
            let message: String?
            let reason: String?
            let error: Inner?
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        let bodyCode = envelope?.code?.value ?? envelope?.error?.code?.value
        let message = (envelope?.message ?? envelope?.error?.message).map(Redaction.text)
        let httpOK = (200...299).contains(status)
        let codeOK = bodyCode.map { (200...299).contains($0) } ?? true
        let messageOK = !(message.map(failureMessages.contains) ?? false)
        guard !(httpOK && codeOK && messageOK) else { return }
        let reported = !httpOK ? status : (codeOK ? (message == "DeviceNotFound" ? 404 : status) : (bodyCode ?? status))
        throw JamfSchoolError(.status(reported, message: message, reason: envelope?.reason.map(Redaction.text),
                                      method: method, path: path))
    }
}

// MARK: - Client

extension JamfSchool {
    /// Talks to one Jamf School instance on JTKit's `HTTPClient`: retries a
    /// 429 for every request and server errors and network drops for reads,
    /// and writes every attempt to the activity log.
    public struct Client: Sendable {
        public let baseURL: URL
        let http: HTTPClient
        private let hints: @Sendable (JamfSchoolError) -> [String]
        /// Device lists and details are recorded also when they succeed.
        let recordsDeviceAnswers: Bool
        public var recorder: RequestRecorder { http.recorder }

        /// - Parameters:
        ///   - address: the instance, e.g. `yourschool.jamfcloud.com`; a
        ///     trailing `/api` is accepted.
        ///   - networkID, apiKey: trimmed; both required.
        ///   - hints: the app's own hints for an error, shown before the standard ones.
        ///   - recordsDeviceAnswers: record the device list and a device's
        ///     details also when they succeed (Checkpoint's lookups, ROADMAP
        ///     step 5); personal blocks are hidden, as in every recorded body.
        ///   - sleep, random: injectable for tests.
        /// - Throws: `JamfSchoolError` `.incomplete` when something is missing.
        public init(
            address: String,
            networkID: String,
            apiKey: String,
            recorder: RequestRecorder,
            permits: @escaping @Sendable (HTTPRequest) -> Bool = { _ in true },
            hints: @escaping @Sendable (JamfSchoolError) -> [String] = { _ in [] },
            recordsDeviceAnswers: Bool = false,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
        ) throws {
            guard let baseURL = JamfSchool.baseURL(address) else {
                throw JamfSchoolError(.incomplete("Enter the Jamf School address, e.g. https://yourschool.jamfcloud.com."))
            }
            let id = networkID.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !key.isEmpty else {
                throw JamfSchoolError(.incomplete("Enter the Network ID and API key."))
            }
            self.baseURL = baseURL
            self.hints = hints
            self.recordsDeviceAnswers = recordsDeviceAnswers
            let authorization = "Basic " + Data("\(id):\(key)".utf8).base64EncodedString()
            http = HTTPClient(baseURL: baseURL, tokens: nil, recorder: recorder,
                              headers: ["Authorization": authorization], permits: permits,
                              redirects: .sameHostHTTPSOnly, sleep: sleep, random: random)
        }

        /// A client for a saved Jamf School connection: its address, its
        /// Network ID (`clientID`) and the API key.
        public init(
            connection: Connection,
            apiKey: String,
            recorder: RequestRecorder,
            permits: @escaping @Sendable (HTTPRequest) -> Bool = { _ in true },
            hints: @escaping @Sendable (JamfSchoolError) -> [String] = { _ in [] },
            recordsDeviceAnswers: Bool = false,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
        ) throws {
            guard connection.service == .jamfSchool else {
                throw JamfSchoolError(.incomplete("“\(ConnectionMenuText.name(of: connection))” is not a Jamf School connection."))
            }
            try self.init(address: connection.serverURL, networkID: connection.clientID, apiKey: apiKey,
                          recorder: recorder, permits: permits, hints: hints,
                          recordsDeviceAnswers: recordsDeviceAnswers, sleep: sleep, random: random)
        }

        // MARK: Devices

        /// Every device, by serial number in capitals. Jamf School serves the
        /// whole fleet in one answer, without pages. Devices without a serial
        /// are left out.
        public func fleet() async throws -> [String: Device] {
            let devices = try await deviceList([])
            return Dictionary(devices.compactMap { device in device.serialNumber.map { ($0.uppercased(), device) } }) { first, _ in first }
        }

        /// The devices in these groups.
        public func devices(inGroups groupIDs: [String]) async throws -> [Device] {
            try await deviceList([URLQueryItem(name: "groups", value: groupIDs.joined(separator: ","))])
        }

        /// The device with this serial number, from the device list (no time
        /// zone or passcode details). A device counts only when its serial is
        /// the one asked for (ignoring case).
        public func device(serial: String) async throws -> JamfPro.Match<Device> {
            let safe = try Self.validated(serial)
            let matches = try await deviceList([URLQueryItem(name: "serialnumber", value: safe)])
                .filter { $0.serialNumber?.caseInsensitiveCompare(safe) == .orderedSame }
            switch matches.count {
            case 0: return .none
            case 1: return .one(matches[0])
            default: return .several(matches.count)
            }
        }

        /// One device's details (`devices/{udid}`), with the instance's time
        /// zone and the passcode state. Nil when Jamf School has no such device.
        public func device(udid: String) async throws -> Device? {
            let safe = try Self.validated(udid)
            let data: Data
            do {
                data = try await send(HTTPRequest(path: "api/devices/\(safe)", recordsBodies: recordsDeviceAnswers))
            } catch let error as JamfSchoolError where error.isDeviceNotFound {
                return nil
            }
            struct Body: Decodable { let device: Tolerant<Device>? }
            guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
                throw failure(JamfSchoolError(.invalidResponse("not a Jamf School device record.")))
            }
            return body.device?.value
        }

        /// Sets or clears (empty) a device's asset tag. Safe to repeat. The
        /// API key needs the "Update details" method.
        public func setAssetTag(_ assetTag: String, udid: String) async throws {
            let safe = try Self.validated(udid)
            _ = try await send(HTTPRequest(method: "POST", path: "api/devices/\(safe)/details",
                                           body: Data("assetTag=\(FormEncoding.encode(assetTag))".utf8),
                                           contentType: "application/x-www-form-urlencoded; charset=utf-8",
                                           safeToRepeat: true))
        }

        // MARK: Other lists

        public func groups() async throws -> [Group] {
            let data = try await send(HTTPRequest(path: "api/devices/groups"))
            // The documentation says DeviceGroups; the API answers deviceGroups.
            struct Body: Decodable {
                let deviceGroups: [Tolerant<Group>]?
                let DeviceGroups: [Tolerant<Group>]?
            }
            guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
                throw failure(JamfSchoolError(.invalidResponse("not a Jamf School group list.")))
            }
            return (body.deviceGroups ?? body.DeviceGroups ?? []).compactMap(\.value)
        }

        public func locations() async throws -> [Location] {
            let data = try await send(HTTPRequest(path: "api/locations"))
            struct Body: Decodable { let locations: [Tolerant<Location>]? }
            guard let body = try? JSONDecoder().decode(Body.self, from: data), let locations = body.locations else {
                throw failure(JamfSchoolError(.invalidResponse("not a Jamf School location list.")))
            }
            return locations.compactMap(\.value)
        }

        /// Devices waiting in Automated Device Enrollment, without removed ones
        /// (`dep`, protocol version 3).
        public func enrollmentPlaceholders() async throws -> [EnrollmentPlaceholder] {
            let data = try await send(HTTPRequest(path: "api/dep", headers: ["X-Server-Protocol-Version": "3"]))
            struct Body: Decodable { let placeholders: [Tolerant<EnrollmentPlaceholder>]? }
            guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
                throw failure(JamfSchoolError(.invalidResponse("not a Jamf School enrollment list.")))
            }
            return (body.placeholders ?? []).compactMap(\.value).filter { $0.status != "removed" }
        }

        /// Checks the address, Network ID and API key with a lookup that can't
        /// match anything: the answer must be a Jamf School device list.
        public func testConnection() async throws {
            _ = try await deviceList([URLQueryItem(name: "serialnumber", value: "CONNECTIONCHECK")])
        }

        // MARK: Sending

        /// Sends a request and checks the answer by Jamf School's rules.
        ///
        /// - Throws: `JamfSchoolError`, `CancellationError`.
        public func send(_ request: HTTPRequest) async throws -> Data {
            let response: HTTPResponse
            do {
                response = try await http.send(request)
            } catch let error as HTTPError {
                throw failure(Self.schoolError(error))
            }
            do {
                try JamfSchoolError.check(status: response.status, data: response.data,
                                          method: request.method, path: request.path)
            } catch let error as JamfSchoolError {
                throw failure(error)
            }
            return response.data
        }

        /// An error with the app's hints added, as the client throws it.
        public func failure(_ error: JamfSchoolError) -> JamfSchoolError {
            var annotated = error
            annotated.appHints += hints(error).filter { !annotated.appHints.contains($0) }
            return annotated
        }

        private func deviceList(_ query: [URLQueryItem]) async throws -> [Device] {
            let data = try await send(HTTPRequest(path: "api/devices", query: query, recordsBodies: recordsDeviceAnswers))
            struct Body: Decodable { let devices: [Tolerant<Device>]? }
            // An answer without a device list isn't Jamf School's (e.g. a web
            // page from a wrong address): never read as "no devices".
            guard let body = try? JSONDecoder().decode(Body.self, from: data), let devices = body.devices else {
                throw failure(JamfSchoolError(.invalidResponse("not a Jamf School device list.")))
            }
            return devices.compactMap(\.value)
        }

        private static func validated(_ value: String) throws -> String {
            do {
                return try JamfPro.validatedIdentifier(value)
            } catch {
                throw JamfSchoolError(.invalidIdentifier(String(value.prefix(64))))
            }
        }

        private static func schoolError(_ error: HTTPError) -> JamfSchoolError {
            switch error {
            case let .refused(method, path):
                return JamfSchoolError(.refused(method: method, path: path))
            case let .transport(method, path, code, message):
                return JamfSchoolError(.transport(method: method, path: path, code: code, message: message))
            case let .status(response, method, path, _):
                do {
                    try JamfSchoolError.check(status: response.status, data: response.data, method: method, path: path)
                } catch let error as JamfSchoolError {
                    return error
                } catch {}
                return JamfSchoolError(.status(response.status, message: nil, reason: nil, method: method, path: path))
            case let .invalidURL(message), let .decoding(message):
                return JamfSchoolError(.invalidResponse(message))
            }
        }
    }
}
