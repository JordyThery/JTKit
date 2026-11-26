import Foundation

/// Demo Mode’s content caches (1.11.0), on `DemoSoftwareUpdate`’s Macs and
/// served by `DemoSoftwareUpdateServer`: one of each case a sweep can find.
///
/// - **Studio Mac 01**: OK, macOS 27 with all four status items (one key
///   of `content-cache.status` older than the rest, which the reader drops,
///   and a removed peer), a healthy parent, Mac Software on top.
/// - **Studio Mac 03**: in the caching Blueprint’s scope, cache not
///   activated, declaration not received.
/// - **Studio Mac 05**: Warning: pressure 72 % and an alert 12 hours ago
///   (and 94 of its 100 GB in use, which is information only).
/// - **Loaner Mac 01**: Fault: activated but not running, registration
///   with Apple failed, its declaration failed.
/// - **Studio Mac 07**: unplanned: activated, OK, no caching Blueprint.
///
/// The caching Blueprint “Contoso – Content Caches” is scoped to the
/// smart group Content Cache Macs (01, 03, 05 and Loaner Mac 01). Every
/// demo device is in a site: odd numbers in Amsterdam Studio, even ones in
/// Rotterdam Studio, which has devices and no cache. Addresses are from
/// the documentation ranges.
public enum DemoContentCaching {
    public static let blueprintID = DemoSamples.uuid(0xb503)
    public static let groupID = "603"
    public static let platformGroupID = DemoSamples.uuid(0xd703)
    public static let groupName = "Content Cache Macs"
    public static let blueprintName = "Contoso – Content Caches"

    /// The Macs the caching Blueprint is scoped to.
    public static let configured: [Int] = [201, 203, 205, 207]
    /// The Macs whose cache is activated.
    public static let caches: [Int] = [201, 205, 207, 209]
    /// The cache whose counters started again three days ago.
    public static let resetCache = 205
    public static let resetDaysAgo = 3

    static let gigabyte: Int64 = 1_000_000_000

    /// Odd device numbers in Amsterdam Studio, even ones in Rotterdam Studio.
    public static func site(of number: Int) -> (id: String, name: String) {
        number % 2 == 1 ? ("1", "Amsterdam Studio") : ("2", "Rotterdam Studio")
    }

    /// The configuration Jamf names for the Blueprint’s content caching declaration, and its step activation.
    public static var configuration: String { "Blueprint_\(blueprintID)_s1_c1_declaration_custom_0" }
    public static var activation: String { "Blueprint_\(blueprintID)_s1_c1_sys_act1" }

    // MARK: The Blueprint

    static func blueprint(now: Date) -> LosslessJSON.Object {
        let created = DemoWorld.iso(daysAgo: 30, from: now, fractional: true)
        let updated = DemoWorld.iso(daysAgo: 20, from: now, fractional: true)
        let payload = LosslessJSON.Object([
            .init(key: "AutoActivation", value: .bool(true)),
            .init(key: "AllowSharedCaching", value: .bool(true)),
            .init(key: "AllowPersonalCaching", value: .bool(false)),
            .init(key: "CacheLimit", value: .number(.init(Int(100 * gigabyte)))),
            .init(key: "Parents", value: .array([.string("192.0.2.1")])),
            .init(key: "KeepAwake", value: .bool(true)),
            .init(key: "DeclarativeStatusInterval", value: .number(.init(900))),
        ])
        let declaration = LosslessJSON.Object([
            .init(key: "kind", value: .string("CONFIGURATION")),
            .init(key: "type", value: .string(JamfPlatform.ContentCacheSettings.declarationType)),
            .init(key: "payload", value: .object(payload)),
            .init(key: "channelType", value: .string("SYSTEM")),
        ])
        let step = LosslessJSON.Object([
            .init(key: "name", value: .string("Components in this blueprint")),
            .init(key: "components", value: .array([.object(LosslessJSON.Object([
                .init(key: "identifier", value: .string("com.jamf.ddm-strict")),
                .init(key: "configuration", value: .object(LosslessJSON.Object([
                    .init(key: "declarations", value: .array([.object(declaration)])),
                ]))),
            ]))])),
            .init(key: "activationPredicate", value: .null),
        ])
        return LosslessJSON.Object([
            "id": .string(blueprintID),
            "name": .string(blueprintName),
            "description": .string("Content caches for the studios"),
            "created": .string(created),
            "updated": .string(updated),
            "deploymentState": .object(LosslessJSON.Object([
                "state": .string("DEPLOYED"),
                "lastDeployment": .object(LosslessJSON.Object(["started": .string(updated), "state": .string("SUCCEEDED")])),
            ])),
            "scope": .object(LosslessJSON.Object(["deviceGroups": .array([.string(platformGroupID)])])),
            "steps": .array([.object(step)]),
        ])
    }

    // MARK: The inventory section

    /// The `contentCaching` section of a Mac, as Jamf’s inventory gives it;
    /// a Mac without an activated cache has the section with zeros.
    /// - Parameter iso: an ISO 8601 date so many days ago.
    static func section(_ number: Int, iso: (Double) -> String) -> [String: Any] {
        var section: [String: Any] = [
            "computerContentCachingInformationId": String(number), "parents": [], "alerts": [], "activated": false,
            "active": false, "actualCacheBytesUsed": 0, "cacheDetails": [], "cacheBytesFree": 0, "cacheBytesLimit": 0,
            "cacheStatus": "OK", "cacheBytesUsed": 0, "dataMigrationCompleted": false, "dataMigrationProgressPercentage": 0,
            "dataMigrationError": ["code": 0, "domain": NSNull(), "userInfo": []] as [String: Any],
            "maxCachePressureLast1HourPercentage": 0, "personalCacheBytesFree": 0, "personalCacheBytesLimit": 0,
            "personalCacheBytesUsed": 0, "port": 0, "publicAddress": NSNull(), "registrationError": NSNull(),
            "registrationResponseCode": 0, "registrationStarted": NSNull(), "registrationStatus": "CONTENT_CACHING_PENDING",
            "restrictedMedia": false, "serverGuid": NSNull(), "startupStatus": "OK",
            "tetheratorStatus": "CONTENT_CACHING_DISABLED", "totalBytesAreSince": NSNull(), "totalBytesDropped": 0,
            "totalBytesImported": 0, "totalBytesReturnedToChildren": 0, "totalBytesReturnedToClients": 0,
            "totalBytesReturnedToPeers": 0, "totalBytesStoredFromOrigin": 0, "totalBytesStoredFromParents": 0,
            "totalBytesStoredFromPeers": 0,
        ]
        guard caches.contains(number), let figures = counters(number, daysAgo: 0) else { return section }
        let g = gigabyte
        section.merge([
            "activated": true, "active": true, "registrationStatus": "CONTENT_CACHING_SUCCEEDED",
            "serverGuid": guid(number), "port": 49_000 + number, "publicAddress": "203.0.113.\(number - 190)",
            "totalBytesAreSince": iso(figures.sinceDaysAgo), "totalBytesReturnedToClients": figures.served,
            "totalBytesStoredFromOrigin": figures.fromOrigin, "totalBytesStoredFromParents": figures.fromOrigin / 4,
            "cacheBytesFree": 400 * g,
        ]) { $1 }
        switch number {
        case 201:
            section.merge([
                "cacheBytesUsed": 61 * g, "actualCacheBytesUsed": 61 * g, "cacheBytesLimit": 100 * g,
                "maxCachePressureLast1HourPercentage": 8, "personalCacheBytesUsed": 0,
                "cacheDetails": [category("Mac Software", 38 * g, 1), category("iOS Software", 15 * g, 2), category("Apps", 8 * g, 3)],
                "parents": [parent(healthy: true)],
            ]) { $1 }
        case 205:
            section.merge([
                "cacheBytesUsed": 94 * g, "actualCacheBytesUsed": 94 * g, "cacheBytesLimit": 100 * g,
                "maxCachePressureLast1HourPercentage": 72, "personalCacheBytesUsed": 0,
                "cacheDetails": [category("iOS Software", 52 * g, 4), category("Mac Software", 30 * g, 5), category("Other", 12 * g, 6)],
                "parents": [parent(healthy: true)],
                "alerts": [["className": "com.apple.AssetCache.CacheVolumeAlert", "postDate": iso(0.5),
                            "cacheBytesLimit": 100 * g, "reservedVolumeBytes": 25 * g, "pathPreventingAccess": NSNull(),
                            "resource": NSNull()] as [String: Any]],
            ]) { $1 }
        case 207:
            section.merge([
                "active": false, "cacheStatus": "OK", "startupStatus": "FAILED",
                "registrationStatus": "CONTENT_CACHING_FAILED", "registrationError": "NOT_ACTIVATED",
                "registrationResponseCode": 403, "registrationStarted": iso(2),
                "cacheBytesUsed": 4 * g, "actualCacheBytesUsed": 4 * g, "cacheBytesLimit": 100 * g,
                "cacheDetails": [category("Mac Software", 4 * g, 7)],
            ]) { $1 }
        default:
            // Studio Mac 07, unplanned: no limit, some personal content
            section.merge([
                "cacheBytesUsed": 22 * g, "actualCacheBytesUsed": 22 * g, "personalCacheBytesUsed": 3 * g,
                "cacheDetails": [category("Mac Software", 19 * g, 8), category("iCloud", 3 * g, 9)],
            ]) { $1 }
        }
        return section
    }

    private static func category(_ name: String, _ bytes: Int64, _ id: Int) -> [String: Any] {
        ["computerContentCachingCacheDetailsId": String(id), "categoryName": name, "diskSpaceBytesUsed": bytes]
    }

    private static func parent(healthy: Bool) -> [String: Any] {
        ["contentCachingParentId": "1", "address": "192.0.2.1", "port": 49_100, "guid": DemoSamples.uuid(0xca00).uppercased(),
         "healthy": healthy, "version": "265.40.2",
         "alerts": ["contentCachingParentAlertId": "1", "addresses": [], "className": NSNull(), "postDate": NSNull()] as [String: Any],
         "details": ["contentCachingParentDetailsId": "1", "acPower": true, "cacheSizeBytes": 500 * gigabyte, "portable": false,
                     "capabilities": ["contentCachingParentCapabilitiesId": "1", "imports": false, "namespaces": true,
                                      "personalContent": false, "queryParameters": true, "sharedContent": true,
                                      "prioritization": false],
                     "localNetwork": [["contentCachingParentLocalNetworkId": "1", "speed": 10_000, "wired": true]]] as [String: Any]]
    }

    static func guid(_ number: Int) -> String { DemoSamples.uuid(0xca00 + number).uppercased() }

    /// A cache’s counters so many days ago: served and fetched since its
    /// counters started, and when that was (days ago). Studio Mac 05’s
    /// started again `resetDaysAgo` days ago.
    static func counters(_ number: Int, daysAgo: Int) -> (served: Int64, fromOrigin: Int64, sinceDaysAgo: Double)? {
        let g = gigabyte
        let perDay: (served: Int64, origin: Int64)
        switch number {
        case 201: perDay = (4 * g, g)
        case 205: perDay = (9 * g, 3 * g)
        case 207: perDay = (g / 2, g / 4)
        case 209: perDay = (2 * g, g)
        default: return nil
        }
        if number == resetCache, daysAgo < resetDaysAgo {
            let days = Int64(resetDaysAgo - daysAgo)
            return (perDay.served * days, perDay.origin * days, Double(resetDaysAgo))
        }
        let days = Int64(40 - daysAgo)
        return (perDay.served * days, perDay.origin * days, 40)
    }

    // MARK: Status items (macOS 27)

    /// The `content-cache.*` status items of a Mac, flattened as Jamf Pro
    /// keeps them. Studio Mac 01 and 05 send `content-cache.info` (the
    /// Blueprint asks for it); Studio Mac 07 doesn’t (no Blueprint).
    /// - Parameter time: a server time (no zone) so many days ago.
    static func statusItems(_ number: Int, time: (Double) -> String) -> [[String: Any]] {
        guard caches.contains(number) else { return [] }
        let now = 0.02
        var items: [[String: Any]] = []
        func add(_ key: String, _ value: String, _ daysAgo: Double = now) {
            items.append(["key": key, "value": value, "lastUpdateTime": time(daysAgo)])
        }
        let g = gigabyte
        let running = number != 207
        add("content-cache.status.activated", "true")
        add("content-cache.status.active", running ? "true" : "false")
        add("content-cache.status.cache-status", "OK")
        add("content-cache.status.startup-status", running ? "OK" : "FAILED")
        add("content-cache.status.port", String(49_000 + number))
        add("content-cache.status.private-addresses", "192.0.2.\(number - 190)")
        add("content-cache.status.public-address", "203.0.113.\(number - 190)")
        add("content-cache.status.registration-status", running ? "1" : "0")
        add("content-cache.status.server-guid", guid(number))
        add("content-cache.status.tetherator-status", "0")
        add("content-cache.status.version", "265.40.2")
        if number == 201 {
            // left over from before it registered: older than the rest, so it is dropped
            add("content-cache.status.registration-error", "NOT_ACTIVATED", 3)
        }
        if !running {
            add("content-cache.status.registration-error", "NOT_ACTIVATED")
            add("content-cache.status.registration-response-code", "403")
        }
        if number == 201 || number == 205 {
            let used = number == 201 ? 61 * g : 94 * g
            add("content-cache.info.cache-used", String(used))
            add("content-cache.info.cache-free", String(400 * g))
            add("content-cache.info.cache-limit", String(100 * g))
            add("content-cache.info.cache-status", "OK")
            add("content-cache.info.max-cache-pressure-last-hour", number == 201 ? "0.08" : "0.72")
            add("content-cache.info.personal-cache-used", "0")
            add("content-cache.info.personal-cache-free", String(400 * g))
            add("content-cache.info.personal-cache-limit", "0")
            add("content-cache.info.cache-details", number == 201
                ? "Mac Software : \(38 * g),iOS Software : \(15 * g),Apps : \(8 * g)"
                : "iOS Software : \(52 * g),Mac Software : \(30 * g),Other : \(12 * g)")
            add("content-cache.parents", "[{identifier=\(DemoSamples.uuid(0xca00).uppercased()), address=192.0.2.1, port=49100, healthy=true, version=265.40.2}]")
        } else {
            add("content-cache.parents", "", 5)
        }
        if number == 201 {
            add("content-cache.peers", "[{identifier=\(guid(209)), address=192.0.2.19, port=49209, friendly=true, healthy=true, version=265.40.2}, "
                + "{identifier=\(guid(299)), _removed=true}]")
        } else {
            add("content-cache.peers", "", 5)
        }
        return items
    }

    // MARK: Declarations

    /// How the Blueprint’s declaration stands on a configured Mac: nil when it hasn’t received it.
    static func declarationStatus(_ number: Int) -> (status: String, active: Bool, reasons: [[String: Any]])? {
        switch number {
        case 201, 205: ("SUCCESSFUL", true, [])
        case 207: ("UNSUCCESSFUL", false, [["code": "Error.ConfigurationFailed",
                                             "description": "The content cache couldn’t be configured.", "details": []] as [String: Any]])
        default: nil
        }
    }

    /// The declaration reports a Mac has for the caching Blueprint: its
    /// configuration and its step activation.
    static func reports(_ number: Int, deviceID: String, reported: String, changed: String) -> [[String: Any]] {
        guard configured.contains(number), let state = declarationStatus(number) else { return [] }
        func report(_ identifier: String, _ type: String, _ status: String, _ active: Bool, _ reasons: [[String: Any]],
                    payloadType: String?) -> [String: Any] {
            var report: [String: Any] = ["declarationIdentifier": identifier, "deviceId": deviceID, "channel": "SYSTEM", "type": type,
                                         "status": status, "active": active, "validityState": "VALID", "reasons": reasons,
                                         "serverToken": "0000", "dateUpdated": changed, "lastReportTime": reported]
            if let payloadType { report["payloadType"] = payloadType }
            return report
        }
        return [
            report(activation, "ACTIVATION", "SUCCESSFUL", true, [], payloadType: nil),
            report(configuration, "CONFIGURATION", state.status, state.active, state.reasons,
                   payloadType: JamfPlatform.ContentCacheSettings.declarationType),
        ]
    }

    // MARK: Earlier sweeps

    /// Ten days of one sweep a day for the trend, oldest first, with the
    /// counter reset of Studio Mac 05 three days ago. An app seeds its
    /// first demo sweep with them, as it seeds its history.
    public static func pastSweeps(now: Date = Date()) -> [ContentCacheRules.CacheSnapshot] {
        (1...10).reversed().flatMap { daysAgo -> [ContentCacheRules.CacheSnapshot] in
            let date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            return caches.compactMap { number in
                guard let figures = counters(number, daysAgo: daysAgo) else { return nil }
                let health: ContentCacheRules.CacheHealth.Level = number == 207 ? .fault : number == 205 ? .warning : .ok
                return ContentCacheRules.CacheSnapshot(
                    date: date, cacheID: String(number),
                    countersSince: now.addingTimeInterval(-figures.sinceDaysAgo * 86_400), serverGuid: guid(number),
                    served: figures.served, fromOrigin: figures.fromOrigin,
                    used: [201: 61 * gigabyte, 205: 94 * gigabyte, 207: 4 * gigabyte, 209: 22 * gigabyte][number],
                    pressurePercent: number == 205 ? 60 + daysAgo : 8, health: health)
            }
        }
    }
}
