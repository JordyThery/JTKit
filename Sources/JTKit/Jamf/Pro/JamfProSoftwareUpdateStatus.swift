import Foundation

extension JamfPro {
    /// What a device’s DDM status report says about software updates, read
    /// from its status items (Apple’s `softwareupdate.*`, `device.*` and
    /// `passcode.is-present` keys).
    ///
    /// Jamf Pro keeps nested values either as separate flattened keys
    /// (`softwareupdate.pending-version.os-version`) or as one text in Java’s
    /// `{key=value, …}` form; both are read. A value that can’t be read is nil.
    public struct SoftwareUpdateStatus: Hashable, Sendable {
        /// `softwareupdate.install-state`.
        public enum InstallState: Hashable, Sendable {
            case none, waiting, downloading, prepared, installing, failed
            case other(String)

            public init(_ raw: String) {
                switch raw.lowercased() {
                case "none": self = .none
                case "waiting": self = .waiting
                case "downloading": self = .downloading
                case "prepared": self = .prepared
                case "installing": self = .installing
                case "failed": self = .failed
                default: self = .other(raw)
                }
            }

            public var rawValue: String {
                switch self {
                case .none: "none"
                case .waiting: "waiting"
                case .downloading: "downloading"
                case .prepared: "prepared"
                case .installing: "installing"
                case .failed: "failed"
                case .other(let raw): raw
                }
            }

            /// Waiting, downloading, prepared or installing.
            public var isBusy: Bool {
                switch self {
                case .waiting, .downloading, .prepared, .installing: true
                default: false
                }
            }
        }

        /// `softwareupdate.pending-version`: the update the device is working on.
        public struct PendingVersion: Hashable, Sendable {
            public var osVersion: String?
            public var buildVersion: String?
            /// The deadline in the device’s local time, without a zone.
            public var targetLocalDateTime: String?

            public init(osVersion: String? = nil, buildVersion: String? = nil, targetLocalDateTime: String? = nil) {
                self.osVersion = osVersion
                self.buildVersion = buildVersion
                self.targetLocalDateTime = targetLocalDateTime
            }
        }

        /// `softwareupdate.failure-reason`.
        public struct Failure: Hashable, Sendable {
            public var count: Int?
            public var reason: String?
            /// When it failed, as the device wrote it.
            public var timestamp: String?

            public init(count: Int? = nil, reason: String? = nil, timestamp: String? = nil) {
                self.count = count
                self.reason = reason
                self.timestamp = timestamp
            }
        }

        public var installState: InstallState?
        public var pendingVersion: PendingVersion?
        public var failure: Failure?
        /// The `softwareupdate-reason` values of `softwareupdate.install-reason`,
        /// e.g. `declaration`, `mdm`, `system-settings`.
        public var installReasons: [String]
        /// `softwareupdate.beta-enrollment`.
        public var betaEnrollment: String?
        /// `device.operating-system.version` and `.build-version`.
        public var osVersion: String?
        public var osBuild: String?
        /// `device.model.identifier`, e.g. `iPad13,18`.
        public var modelIdentifier: String?
        /// `softwareupdate.device-id`: the board ID Apple’s update catalog
        /// uses (e.g. `J517AP`), also when the inventory has no model.
        public var deviceID: String?
        /// `passcode.is-present`.
        public var passcodePresent: Bool?
        /// The newest `lastUpdateTime` of the software update and OS items:
        /// the Jamf Pro server’s local time, without a zone
        /// (`JamfPro.serverDate(_:timeZone:)` reads it).
        public var newestUpdate: String?
        /// How many status items the report had.
        public var itemCount: Int

        public init(installState: InstallState? = nil, pendingVersion: PendingVersion? = nil, failure: Failure? = nil,
                    installReasons: [String] = [], betaEnrollment: String? = nil, osVersion: String? = nil,
                    osBuild: String? = nil, modelIdentifier: String? = nil, deviceID: String? = nil,
                    passcodePresent: Bool? = nil, newestUpdate: String? = nil, itemCount: Int = 0) {
            self.installState = installState
            self.pendingVersion = pendingVersion
            self.failure = failure
            self.installReasons = installReasons
            self.betaEnrollment = betaEnrollment
            self.osVersion = osVersion
            self.osBuild = osBuild
            self.modelIdentifier = modelIdentifier
            self.deviceID = deviceID
            self.passcodePresent = passcodePresent
            self.newestUpdate = newestUpdate
            self.itemCount = itemCount
        }

        /// Reads the items of one status report. When a key comes twice, the
        /// last one counts.
        public init(items: [StatusItem]) {
            var values: [String: String] = [:]
            var times: [String] = []
            for item in items {
                values[item.key] = item.value
                if item.key.hasPrefix("softwareupdate.") || item.key.hasPrefix("device.operating-system."),
                   let time = item.lastUpdateTime?.trimmingCharacters(in: .whitespaces), !time.isEmpty {
                    times.append(time)
                }
            }
            func value(_ key: String) -> String? {
                guard let text = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      text != "null" else { return nil }
                return text
            }
            func nested(_ key: String, _ sub: String) -> String? {
                value(key + "." + sub) ?? value(key).flatMap { Self.field(sub, in: $0) }
            }

            let pending = PendingVersion(osVersion: nested("softwareupdate.pending-version", "os-version"),
                                         buildVersion: nested("softwareupdate.pending-version", "build-version"),
                                         targetLocalDateTime: nested("softwareupdate.pending-version", "target-local-date-time"))
            let failure = Failure(count: nested("softwareupdate.failure-reason", "count").flatMap { Int($0) },
                                  reason: nested("softwareupdate.failure-reason", "reason"),
                                  timestamp: nested("softwareupdate.failure-reason", "timestamp"))
            let reasonTexts = values.filter { $0.key.hasPrefix("softwareupdate.install-reason") }
                .sorted { $0.key < $1.key }.compactMap(\.value)
            self.init(
                installState: value("softwareupdate.install-state").map(InstallState.init),
                pendingVersion: pending == PendingVersion() ? nil : pending,
                failure: failure == Failure() ? nil : failure,
                installReasons: Self.allFields("softwareupdate-reason", in: reasonTexts.joined(separator: ",")),
                betaEnrollment: value("softwareupdate.beta-enrollment"),
                osVersion: value("device.operating-system.version"),
                osBuild: value("device.operating-system.build-version"),
                modelIdentifier: value("device.model.identifier"),
                deviceID: value("softwareupdate.device-id"),
                passcodePresent: value("passcode.is-present").flatMap(Self.bool),
                // the same fixed-width format, so the largest text is the newest
                newestUpdate: times.max(),
                itemCount: items.count)
        }

        /// `sub=value` in a `{key=value, …}` text, or `"sub": value` in JSON.
        static func field(_ sub: String, in text: String) -> String? {
            allFields(sub, in: text).first
        }

        /// Every value of `sub`: `"sub": "value"` (or a bare value) in JSON,
        /// else `sub=value` in Java’s `{key=value, …}` text, where a value
        /// runs to the next comma or closing brace and keeps its quotes (a
        /// failure reason holds `Code=8406 "…"`).
        static func allFields(_ sub: String, in text: String) -> [String] {
            let name = NSRegularExpression.escapedPattern(for: sub)
            let isJSON = text.range(of: "\"\(name)\"\\s*:", options: .regularExpression) != nil
            let patterns = isJSON
                ? ["\"\(name)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", "\"\(name)\"\\s*:\\s*([^,}\\]\"]+)"]
                : ["(?:^|[{\\[ ,])\(name)=([^,}\\]]*)"]
            let range = NSRange(text.startIndex..., in: text)
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let values = regex.matches(in: text, range: range).compactMap { match in
                    Range(match.range(at: 1), in: text).map { text[$0].trimmingCharacters(in: .whitespaces) }
                }.filter { !$0.isEmpty && $0 != "null" }
                if !values.isEmpty { return values }
            }
            return []
        }

        static func bool(_ text: String) -> Bool? {
            switch text.lowercased() {
            case "true", "1", "yes": true
            case "false", "0", "no": false
            default: nil
            }
        }
    }

    /// A time Jamf Pro writes in its own local time without a zone
    /// (`2026-11-09T14:05:31`, optionally with fractions of a second), as a
    /// date in `timeZone`. A time with a zone or `Z` keeps its own zone.
    public static func serverDate(_ text: String, timeZone: TimeZone) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = JamfPlatform.date(from: trimmed), trimmed.hasSuffix("Z") || trimmed.range(of: "[+-][0-9]{2}:?[0-9]{2}$", options: .regularExpression) != nil {
            return date
        }
        let base = String(trimmed.prefix(19))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: base)
    }
}

extension JamfPlatform.Client {
    /// A device’s software update status, from its DDM status report
    /// (`v1/ddm/{managementId}/status-items`). Nil when Jamf Pro has no
    /// report for the device (404). Unlike `ddmStatusItems`, a refusal (403)
    /// is thrown, naming `devices:read` on the Platform API.
    public func softwareUpdateStatus(managementID: String, kind: MDMCommand.DeviceKind) async throws -> JamfPro.SoftwareUpdateStatus? {
        let request = HTTPRequest(path: "pro/v1/ddm/\(JamfPlatform.pathSegment(managementID))/status-items", recordsBodies: true)
        let response: HTTPResponse
        do {
            response = try await send(request, privileges: [Self.readPrivilege(kind)], permissions: [JamfPlatform.Permission.devicesRead])
        } catch let error as JamfPlatform.APIError where error.status == 404 {
            return nil
        }
        let json: LosslessJSON
        do {
            json = try LosslessJSON(data: response.data)
        } catch {
            throw failure(JamfPlatform.APIError(.invalidResponse("\(request.path) couldn’t be read: \(error.localizedDescription)")))
        }
        let items = (json["statusItems"]?.arrayValue ?? []).compactMap { item -> JamfPro.StatusItem? in
            guard let key = item["key"]?.stringValue else { return nil }
            return JamfPro.StatusItem(key: key, value: item["value"].flatMap(Self.statusText),
                                      lastUpdateTime: item["lastUpdateTime"]?.stringValue)
        }
        return JamfPro.SoftwareUpdateStatus(items: items)
    }

    /// A status item’s value as text: Jamf documents a string, but a number,
    /// a boolean or a nested object is read too.
    static func statusText(_ value: LosslessJSON) -> String? {
        switch value {
        case .null: nil
        case .string(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): number.literal
        case .array, .object: value.serializedString()
        }
    }
}
