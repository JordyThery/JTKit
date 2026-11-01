import Foundation

/// Device commands in a live check (1.1.0, B2 and B2a). Only to the test
/// devices the allow-list lists for a tenant, at most `maxDevicesPerRun`
/// devices a run (all its test processes together):
/// - **commands** (sent at once): Blank Push, check-in (the Platform API’s
///   counterpart, `device-actions:execute`), Update Inventory and the
///   inventory or DDM sync a Blank Push uses;
/// - **interruptive** (restart, shut down, renew, lock, erase, unmanage and
///   every other command, including what needs the Platform API’s
///   `destructive-device-actions:execute`): only after the serial prompt
///   (`InterruptivePrompt`) was answered with the device’s serial.
///
/// Which device a command is for is read from its path and body (record IDs,
/// management IDs, UDIDs, Platform device IDs) and matched to a listed
/// serial through the tenant’s own answers to reads during the run
/// (`DeviceRegistry`). A command for anything else is refused.
public nonisolated enum DeviceCommandLevel: String, Sendable, Codable, Equatable {
    case commands
    case interruptive
}

/// What a command is, as the live check reads it from the request.
public nonisolated struct DeviceCommandRequest: Sendable, Equatable {
    /// e.g. "Blank Push", "Restart".
    public var name: String
    public var level: DeviceCommandLevel
    /// The device identifiers it names, lowercased.
    public var references: [String]
}

/// The serial prompt for an interruptive command, shown by the release
/// check at run time.
public nonisolated struct InterruptivePrompt: Sendable, Equatable {
    public var command: String
    /// The device’s name, from the tenant or the allow-list.
    public var deviceName: String
    /// The role, e.g. "lab-read".
    public var tenant: String
    /// The serial that has to be typed; never shown in the prompt.
    let expectedSerial: String

    /// "Send Restart to “Lab iPad 3” on lab-read? Type its serial number to
    /// send it, or choose Skip this time."
    public var message: String {
        "Send \(command) to “\(deviceName)” on \(tenant)? Type its serial number to send it, or choose Skip this time."
    }

    /// Whether `typed` is the device’s serial (ignoring case and spaces).
    public func confirms(_ typed: String?) -> Bool {
        guard let typed else { return false }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == expectedSerial
    }
}

/// Asks the serial prompt; returns what was typed, or nil for "Skip this time".
public typealias InterruptiveConfirmer = @Sendable (InterruptivePrompt) -> String?

enum DeviceCommands {
    static let maxDevicesPerRun = 3

    /// What a device command is: its name, level and the devices it names.
    static func classify(_ request: LiveRequest) -> DeviceCommandRequest {
        let path = request.url.path(percentEncoded: false)
        let lowered = path.lowercased()
        let segments = path.split(separator: "/").map(String.init)
        let loweredSegments = segments.map { $0.lowercased() }
        var references = Set<String>()
        func after(_ marker: String) {
            for (index, segment) in loweredSegments.enumerated() where segment == marker && index + 1 < segments.count {
                references.insert(segments[index + 1].lowercased())
            }
        }
        for marker in ["devices", "computers-inventory", "computer-inventory", "mobile-devices", "manageddevices", "redeploy", "ddm"] {
            after(marker)
        }
        // Classic: …/command/<Command>/id/<id>
        if loweredSegments.contains(where: { $0.hasSuffix("commands") }) { after("id") }
        for value in bodyReferences(request.body) { references.insert(value.lowercased()) }
        references.subtract(["v1", "v2", "id", "command"])

        let (name, level) = kind(path: lowered, segments: loweredSegments, body: request.body)
        return DeviceCommandRequest(name: name, level: level, references: references.sorted())
    }

    private static func kind(path: String, segments: [String], body: Data) -> (String, DeviceCommandLevel) {
        if path.hasSuffix("/mdm/blank-push") { return ("Blank Push", .commands) }
        if segments.last == "check-in" && path.contains("device-actions/") { return ("Check-in", .commands) }
        if path.contains("/command/updateinventory") { return ("Update Inventory", .commands) }
        if segments.last == "syncdevice" { return ("Update Inventory", .commands) }
        if segments.last == "refresh" && segments.contains("devices") { return ("Update Inventory", .commands) }
        // a Blank Push’s DDM sync
        if let ddm = segments.firstIndex(of: "ddm"), segments.last == "sync", segments.count > ddm + 2 { return ("DDM Sync", .commands) }
        if path.hasSuffix("/mdm/commands"),
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let type = (object["commandData"] as? [String: Any])?["commandType"] as? String {
            if ["DEVICE_INFORMATION", "UPDATE_INVENTORY"].contains(type.uppercased()) { return ("Update Inventory", .commands) }
            return (type.replacingOccurrences(of: "_", with: " ").capitalized, .interruptive)
        }
        let action = segments.last ?? "command"
        return (action.replacingOccurrences(of: "-", with: " ").capitalized, .interruptive)
    }

    /// Device identifiers in a command’s JSON body.
    static func bodyReferences(_ body: Data) -> [String] {
        guard !body.isEmpty, let object = try? JSONSerialization.jsonObject(with: body) else { return [] }
        let keys: Set<String> = ["managementid", "clientmanagementids", "managementids", "udids", "udid", "deviceids", "deviceid"]
        var found: [String] = []
        LiveCheckPolicy.visitObjects(in: object) { dictionary in
            for (key, value) in dictionary where keys.contains(key.lowercased()) {
                for element in (value as? [Any]) ?? [value] {
                    if let text = element as? String { found.append(text) }
                    if let number = element as? NSNumber { found.append(number.stringValue) }
                }
            }
        }
        return found
    }
}

/// The identifiers of each listed test device, learned from a tenant’s
/// answers to reads during the run: any JSON object with a serial number
/// that is on the list gives its IDs, management ID and UDID (also from its
/// `general` and `hardware` sections). Serials that aren’t listed are never kept.
final class DeviceRegistry: @unchecked Sendable {
    struct Device {
        var serial: String
        var name: String?
    }

    private let lock = NSLock()
    /// target → identifier (lowercased) → device
    private var devices: [String: [String: Device]] = [:]

    func learn(from body: Data, target: String, listed: Set<String>) {
        guard !listed.isEmpty, !body.isEmpty, let object = try? JSONSerialization.jsonObject(with: body) else { return }
        var found: [(String, Device)] = []
        LiveCheckPolicy.visitObjects(in: object) { dictionary in
            let general = dictionary["general"] as? [String: Any] ?? [:]
            let hardware = dictionary["hardware"] as? [String: Any] ?? [:]
            let serial = [dictionary["serialNumber"], dictionary["serial_number"], dictionary["SerialNumber"],
                          hardware["serialNumber"], general["serialNumber"]]
                .compactMap { $0 as? String }.first?.uppercased()
            guard let serial, listed.contains(serial) else { return }
            let name = [dictionary["name"], dictionary["displayName"], dictionary["deviceName"], general["name"], general["displayName"]]
                .compactMap { $0 as? String }.first
            var ids = [serial.lowercased()]
            for source in [dictionary, general, hardware] {
                for key in ["id", "udid", "UDID", "managementId", "mobileDeviceId", "deviceId"] {
                    if let text = source[key] as? String { ids.append(text.lowercased()) }
                    if let number = source[key] as? NSNumber { ids.append(number.stringValue) }
                }
            }
            for id in ids where !id.isEmpty { found.append((id, Device(serial: serial, name: name))) }
        }
        guard !found.isEmpty else { return }
        lock.withLock {
            for (id, device) in found {
                let known = devices[target.lowercased()]?[id]
                devices[target.lowercased(), default: [:]][id] = Device(serial: device.serial, name: device.name ?? known?.name)
            }
        }
    }

    func device(target: String, reference: String) -> Device? {
        lock.withLock { devices[target.lowercased()]?[reference.lowercased()] }
    }
}

/// One device command sent in a run, a JSON line in `device-commands.jsonl`:
/// the device limit counts them for every test process of the run.
public nonisolated struct SentDeviceCommand: Codable, Sendable, Equatable {
    public var role: String
    /// The tenant (see `Ledger.Item.target`).
    public var target: String
    /// Masked in the report as the device’s position on the list.
    public var serial: String
    public var command: String
    public var level: DeviceCommandLevel
}
