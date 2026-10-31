import Foundation

// The Platform API’s own device calls: a device by serial, its DDM declarations, and the
// restart and shut down device actions. They exist only on the gateway; on
// a Jamf Pro server reached directly they are refused before sending.

extension JamfPlatform {
    /// A device in the Platform API’s inventory (`devices/v1/devices`).
    public struct Device: Decodable, Hashable, Sendable {
        /// The Platform API’s own UUID, which the device actions and the DDM
        /// report take (not the Jamf Pro record ID).
        public var id: String
        public var serialNumber: String?

        public init(id: String, serialNumber: String? = nil) {
            self.id = id
            self.serialNumber = serialNumber
        }
    }

    /// The inventory answered for a serial with devices that all have another
    /// serial: a filter the server ignored must never become an action
    /// against somebody else’s device.
    public struct DeviceMismatch: Error, LocalizedError, Sendable, Hashable {
        public var serial: String
        public var count: Int

        public var errorDescription: String? {
            "The platform device inventory returned \(count == 1 ? "1 result" : "\(count) results") for \(serial), none with that serial number."
        }
    }

    /// Jamf refused a device action (HTTP 422): the device can’t take it.
    public struct DeviceActionRefused: Error, LocalizedError, Sendable, Hashable {
        /// "restart", "shut down".
        public var verb: String

        public var errorDescription: String? {
            "Jamf Pro won’t \(verb) this device. It may be unmanaged, personally owned, or running an OS version that doesn’t support the command."
        }
    }

    /// One declaration as the device reported it.
    public struct Declaration: Hashable, Sendable {
        public var identifier: String
        public var active: Bool
        /// "valid", "invalid" or "unknown" (lowercased as received).
        public var validity: String
        /// Why it failed, in the device’s words: each reason’s `Error`
        /// detail, else its description, else its code.
        public var reasons: [String]

        public init(identifier: String, active: Bool, validity: String, reasons: [String]) {
            self.identifier = identifier
            self.active = active
            self.validity = validity
            self.reasons = reasons
        }

        /// The Blueprint it came from, when Jamf built the identifier from
        /// one: `Blueprint_<uuid>_s1_c1_sys_cfg1`.
        public var blueprintID: String? {
            let prefix = "Blueprint_"
            guard identifier.hasPrefix(prefix) else { return nil }
            let candidate = String(identifier.dropFirst(prefix.count).prefix(36))
            return UUID(uuidString: candidate) == nil ? nil : candidate
        }
    }
}

extension JamfPlatform.Client {
    /// The Platform API device with exactly this serial number (ignoring
    /// case); nil when the inventory doesn’t know it: no result, or a 404
    /// whose body says `NOT_FOUND` (any other 404 is an error, e.g. a wrong
    /// address). Its answer is recorded (a read-only lookup).
    ///
    /// - Throws: `JamfPlatform.DeviceMismatch` when devices came back but
    ///   none has the serial; `JamfPlatform.APIError`.
    public func device(serial: String) async throws -> JamfPlatform.Device? {
        let safe = try JamfPro.validatedIdentifier(serial)
        struct Page: Decodable { let results: [Tolerant<JamfPlatform.Device>]? }
        let response: HTTPResponse
        do {
            response = try await send(HTTPRequest(path: "devices/v1/devices",
                                                          query: [URLQueryItem(name: "filter", value: "serialNumber==\"\(safe)\"")],
                                                          recordsBodies: true))
        } catch let error as JamfPlatform.APIError where error.status == 404 && error.hasCode(.notFound) {
            return nil
        }
        guard let page = try? JSONDecoder().decode(Page.self, from: response.data) else {
            throw failure(JamfPlatform.APIError(.invalidResponse("devices/v1/devices couldn’t be read.")))
        }
        let results = (page.results ?? []).compactMap(\.value)
        if let match = results.first(where: { $0.serialNumber?.caseInsensitiveCompare(safe) == .orderedSame }) {
            return match
        }
        if results.isEmpty { return nil }
        throw JamfPlatform.DeviceMismatch(serial: safe, count: results.count)
    }

    /// The configuration declarations a device reported
    /// (`ddm/report/v1/devices/{id}/declarations`), at most 200. Nil when the
    /// report can’t be read here (403 or 404). Recorded, as the lookup is.
    public func declarations(deviceID: String) async throws -> [JamfPlatform.Declaration]? {
        struct Page: Decodable {
            let results: [Item]?
            struct Item: Decodable {
                let declarationIdentifier: String?
                let active: Bool?
                let validityState: String?
                let reasons: [Reason]?
            }
            struct Reason: Decodable {
                let code: String?
                let description: String?
                let details: [Detail]?
            }
            struct Detail: Decodable {
                let key: String?
                let description: String?
            }
        }
        let response: HTTPResponse
        do {
            response = try await send(HTTPRequest(
                path: "ddm/report/v1/devices/\(JamfPlatform.pathSegment(deviceID))/declarations",
                // the filter field is declarationType; the answer calls it type
                query: [URLQueryItem(name: "filter", value: "declarationType==CONFIGURATION"),
                        URLQueryItem(name: "size", value: "200")],
                recordsBodies: true))
        } catch let error as JamfPlatform.APIError where error.status == 403 || error.status == 404 {
            return nil
        }
        guard let results = (try? JSONDecoder().decode(Page.self, from: response.data))?.results else { return nil }
        return results.compactMap { item in
            guard let identifier = item.declarationIdentifier, !identifier.isEmpty else { return nil }
            let reasons = (item.reasons ?? []).compactMap { reason in
                reason.details?.first { $0.key == "Error" }?.description ?? reason.description ?? reason.code
            }
            return JamfPlatform.Declaration(identifier: identifier, active: item.active ?? false,
                                            validity: (item.validityState ?? "unknown").lowercased(),
                                            reasons: reasons.filter { !$0.isEmpty })
        }
    }

    /// Restarts a device through the Platform API’s device actions, by its
    /// Platform API ID (`device(serial:)`). Never repeated after a server error.
    ///
    /// - Throws: `JamfPlatform.DeviceActionRefused` for a 422; `JamfPlatform.APIError`.
    public func restart(deviceID: String) async throws {
        try await deviceAction(deviceID, "restart", verb: "restart", privilege: .sendMobileDeviceRestartDeviceCommand)
    }

    /// Shuts a device down, as `restart(deviceID:)`.
    public func shutDown(deviceID: String) async throws {
        try await deviceAction(deviceID, "shutdown", verb: "shut down", privilege: .sendMobileDeviceShutDownCommand)
    }

    private func deviceAction(_ deviceID: String, _ action: String, verb: String, privilege: JamfPro.Privilege) async throws {
        do {
            _ = try await send(HTTPRequest(method: "POST",
                                           path: "device-actions/v1/devices/\(JamfPlatform.pathSegment(deviceID))/\(action)"),
                               privilege: privilege)
        } catch let error as JamfPlatform.APIError where error.status == 422 {
            throw JamfPlatform.DeviceActionRefused(verb: verb)
        }
    }
}
