import Foundation

extension JamfPlatform {
    /// One declaration as a device reported it (Declaration Reporting,
    /// `ddm/report/v1/…`).
    public struct DeclarationReport: Hashable, Sendable {
        public enum Status: Hashable, Sendable {
            case pending, successful, awaitingSync, unsuccessful, unknown
            case other(String)

            public init(_ raw: String?) {
                switch raw?.uppercased() {
                case "PENDING": self = .pending
                case "SUCCESSFUL": self = .successful
                case "AWAITING_SYNC": self = .awaitingSync
                case "UNSUCCESSFUL": self = .unsuccessful
                case "UNKNOWN", nil: self = .unknown
                default: self = .other(raw ?? "")
                }
            }
        }

        public enum Validity: Hashable, Sendable {
            case valid, invalid, unknown
            case other(String)

            public init(_ raw: String?) {
                switch raw?.uppercased() {
                case "VALID": self = .valid
                case "INVALID": self = .invalid
                case "UNKNOWN", nil: self = .unknown
                default: self = .other(raw ?? "")
                }
            }
        }

        public struct Reason: Hashable, Sendable {
            public var code: String?
            public var description: String?
            /// Key and description of each detail.
            public var details: [Detail]

            public struct Detail: Hashable, Sendable {
                public var key: String?
                public var description: String?

                public init(key: String? = nil, description: String? = nil) {
                    self.key = key
                    self.description = description
                }
            }

            public init(code: String? = nil, description: String? = nil, details: [Detail] = []) {
                self.code = code
                self.description = description
                self.details = details
            }
        }

        public var declarationIdentifier: String
        /// The Platform API’s device ID.
        public var deviceID: String?
        public var channel: String?
        /// `ASSET`, `MANAGEMENT`, `CONFIGURATION`, `ACTIVATION` or `UNKNOWN`.
        public var type: String?
        public var status: Status
        public var active: Bool?
        public var validity: Validity
        public var reasons: [Reason]
        public var dateUpdated: Date?
        public var lastReportTime: Date?

        public init(declarationIdentifier: String, deviceID: String? = nil, channel: String? = nil, type: String? = nil,
                    status: Status = .unknown, active: Bool? = nil, validity: Validity = .unknown, reasons: [Reason] = [],
                    dateUpdated: Date? = nil, lastReportTime: Date? = nil) {
            self.declarationIdentifier = declarationIdentifier
            self.deviceID = deviceID
            self.channel = channel
            self.type = type
            self.status = status
            self.active = active
            self.validity = validity
            self.reasons = reasons
            self.dateUpdated = dateUpdated
            self.lastReportTime = lastReportTime
        }

        /// The Blueprint it came from, when Jamf built the identifier from
        /// one (`Blueprint_<uuid>_s1_c1_…`), lowercased.
        public var blueprintID: String? {
            JamfPlatform.Declaration(identifier: declarationIdentifier, active: false, validity: "", reasons: []).blueprintID?.lowercased()
        }

        /// The step of the Blueprint (zero-based) from the identifier’s
        /// `_s<N>_` part, which counts from 1; nil without one.
        public var blueprintStepIndex: Int? {
            guard blueprintID != nil,
                  let range = declarationIdentifier.range(of: "_s([0-9]+)_", options: .regularExpression) else { return nil }
            let digits = declarationIdentifier[range].dropFirst(2).dropLast()
            return Int(digits).map { $0 - 1 }
        }

        init?(json: LosslessJSON) {
            guard let identifier = json["declarationIdentifier"]?.text else { return nil }
            let reasons = (json["reasons"]?.arrayValue ?? []).map { reason in
                Reason(code: reason["code"]?.text, description: reason["description"]?.text,
                       details: (reason["details"]?.arrayValue ?? []).map {
                           Reason.Detail(key: $0["key"]?.text, description: $0["description"]?.text)
                       })
            }
            self.init(declarationIdentifier: identifier, deviceID: json["deviceId"]?.text, channel: json["channel"]?.text,
                      type: json["type"]?.text, status: Status(json["status"]?.text), active: json["active"]?.bool,
                      validity: Validity(json["validityState"]?.text), reasons: reasons,
                      dateUpdated: json["dateUpdated"]?.text.flatMap(JamfPlatform.date(from:)),
                      lastReportTime: json["lastReportTime"]?.text.flatMap(JamfPlatform.date(from:)))
        }
    }
}

extension JamfPlatform.Client {
    /// The declarations a device reported (`ddm/report/v1/devices/{deviceId}/declarations`,
    /// every page; `declarations:read`). Nil when the device has no report
    /// (404); a refusal (403) is thrown.
    ///
    /// - Parameters:
    ///   - deviceID: the Platform API’s device ID (`device(serial:)`).
    ///   - filter: RSQL on `declarationIdentifier`, `active`, `validityState`,
    ///     `declarationType`, `dateUpdated` or `channel`, e.g.
    ///     `declarationIdentifier==Blueprint_<uuid>*`.
    public func declarationReports(deviceID: String, filter: String? = nil) async throws -> [JamfPlatform.DeclarationReport]? {
        do {
            return try await readAllPages("ddm/report/v1/devices/\(JamfPlatform.pathSegment(deviceID))/declarations",
                                          query: filter.map { [URLQueryItem(name: "filter", value: $0)] } ?? [],
                                          pageSize: 100, sizeName: "size", privileges: [],
                                          permissions: [JamfPlatform.Permission.declarationsRead],
                                          item: JamfPlatform.DeclarationReport.init(json:))
        } catch let error as JamfPlatform.APIError where error.status == 404 {
            return nil
        }
    }

    /// The devices that reported one declaration
    /// (`ddm/report/v1/declarations/{declarationIdentifier}/devices`, every
    /// page; `declarations:read`). Nil when nothing reported it (404).
    public func declarationReports(declarationIdentifier: String, filter: String? = nil) async throws -> [JamfPlatform.DeclarationReport]? {
        do {
            return try await readAllPages("ddm/report/v1/declarations/\(JamfPlatform.pathSegment(declarationIdentifier))/devices",
                                          query: filter.map { [URLQueryItem(name: "filter", value: $0)] } ?? [],
                                          pageSize: 100, sizeName: "size", privileges: [],
                                          permissions: [JamfPlatform.Permission.declarationsRead],
                                          item: JamfPlatform.DeclarationReport.init(json:))
        } catch let error as JamfPlatform.APIError where error.status == 404 {
            return nil
        }
    }
}
