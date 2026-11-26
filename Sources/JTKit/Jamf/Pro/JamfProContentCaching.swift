import Foundation

extension JamfPro {
    /// A Mac’s content cache, from the `CONTENT_CACHING` section of
    /// `v4/computers-inventory` (Platform API: `devices:read`; Jamf Pro:
    /// Read Computers). Jamf refreshes it with the Mac’s inventory (recon),
    /// so its figures are as of the record’s `reportDate`. Every field is
    /// optional: a missing field or one of an unexpected type reads as nil.
    public struct ContentCaching: Decodable, Hashable, Sendable {
        /// `registrationStatus`.
        public enum Registration: Hashable, Sendable {
            case succeeded, pending, failed
            case other(String)

            public init(_ raw: String) {
                switch raw.uppercased() {
                case "CONTENT_CACHING_SUCCEEDED", "SUCCEEDED": self = .succeeded
                case "CONTENT_CACHING_PENDING", "PENDING": self = .pending
                case "CONTENT_CACHING_FAILED", "FAILED": self = .failed
                default: self = .other(raw)
                }
            }
        }

        /// Bytes kept for one kind of content, e.g. `iCloud`, `Mac Software`, `Other`.
        public struct Category: Decodable, Hashable, Sendable {
            public var name: String
            public var bytes: Int64

            public init(name: String, bytes: Int64) {
                self.name = name
                self.bytes = bytes
            }

            /// iCloud content: the users’ own, never counted as savings.
            public var isPersonal: Bool { name.caseInsensitiveCompare("iCloud") == .orderedSame }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                guard let name = c.text("categoryName") ?? c.text("name") else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No category name."))
                }
                self.name = name
                bytes = c.bytes("diskSpaceBytesUsed") ?? c.bytes("bytes") ?? 0
            }

            /// The categories as text, as the status item and some answers
            /// write them: `iCloud : 30435304,Other : 1426903`. Parts that
            /// aren’t a name and a whole number are skipped.
            public static func parse(text: String) -> [Category] {
                text.split(separator: ",").compactMap { part in
                    let pieces = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard pieces.count == 2, !pieces[0].isEmpty, let bytes = Int64(pieces[1]) else { return nil }
                    return Category(name: pieces[0], bytes: bytes)
                }
            }
        }

        /// A parent cache this cache fetches from.
        public struct Parent: Decodable, Hashable, Sendable {
            public var address: String?
            public var port: Int?
            public var guid: String?
            public var isHealthy: Bool?
            public var version: String?
            /// The parent’s alert, by its class name, e.g. `com.apple.AssetCache.LowSpaceAlert`.
            public var alert: String?
            public var alertPosted: Date?
            public var acPower: Bool?
            public var cacheSize: Int64?
            public var isPortable: Bool?

            public init(address: String? = nil, port: Int? = nil, guid: String? = nil, isHealthy: Bool? = nil,
                        version: String? = nil, alert: String? = nil, alertPosted: Date? = nil, acPower: Bool? = nil,
                        cacheSize: Int64? = nil, isPortable: Bool? = nil) {
                self.address = address
                self.port = port
                self.guid = guid
                self.isHealthy = isHealthy
                self.version = version
                self.alert = alert
                self.alertPosted = alertPosted
                self.acPower = acPower
                self.cacheSize = cacheSize
                self.isPortable = isPortable
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                let alerts = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "alerts")
                let details = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "details")
                self.init(address: c.text("address"), port: c.number("port"), guid: c.text("guid"), isHealthy: c.flag("healthy"),
                          version: c.text("version"), alert: alerts?.text("className"), alertPosted: alerts?.date("postDate"),
                          acPower: details?.flag("acPower"), cacheSize: details?.bytes("cacheSizeBytes"),
                          isPortable: details?.flag("portable"))
            }
        }

        /// An exceptional condition the cache posted.
        public struct Alert: Decodable, Hashable, Sendable {
            /// e.g. `com.apple.AssetCache.CacheVolumeAlert`.
            public var className: String?
            public var posted: Date?
            public var cacheLimit: Int64?
            public var reservedVolume: Int64?
            public var pathPreventingAccess: String?
            public var resource: String?

            public init(className: String? = nil, posted: Date? = nil, cacheLimit: Int64? = nil, reservedVolume: Int64? = nil,
                        pathPreventingAccess: String? = nil, resource: String? = nil) {
                self.className = className
                self.posted = posted
                self.cacheLimit = cacheLimit
                self.reservedVolume = reservedVolume
                self.pathPreventingAccess = pathPreventingAccess
                self.resource = resource
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                self.init(className: c.text("className"), posted: c.date("postDate"), cacheLimit: c.bytes("cacheBytesLimit"),
                          reservedVolume: c.bytes("reservedVolumeBytes"), pathPreventingAccess: c.text("pathPreventingAccess"),
                          resource: c.text("resource"))
            }
        }

        /// A cache moving its data to another volume. Jamf reports
        /// `completed` false with 0 % and error code 0 on a cache that
        /// never moved anything, so only `isMoving` and `failed` mean something.
        public struct DataMigration: Hashable, Sendable {
            public var completed: Bool?
            public var percent: Int?
            public var errorCode: Int?
            public var errorDomain: String?

            public init(completed: Bool? = nil, percent: Int? = nil, errorCode: Int? = nil, errorDomain: String? = nil) {
                self.completed = completed
                self.percent = percent
                self.errorCode = errorCode
                self.errorDomain = errorDomain
            }

            /// Between 1 and 99 %.
            public var isMoving: Bool { completed != true && (percent ?? 0) > 0 && (percent ?? 0) < 100 }
            /// An error code other than 0, or an error domain.
            public var failed: Bool { (errorCode ?? 0) != 0 || !(errorDomain ?? "").isEmpty }
        }

        public var isActivated: Bool?
        public var isActive: Bool?
        /// `OK`, or the service’s own status text.
        public var cacheStatus: String?
        /// `OK`, or why it didn’t start.
        public var startupStatus: String?
        public var registration: Registration?
        public var registrationError: String?
        public var registrationResponseCode: Int?
        public var registrationStarted: Date?
        /// Shared cache bytes in use, free, and the limit (nil for 0: no limit).
        public var cacheUsed: Int64?
        public var cacheFree: Int64?
        public var cacheLimit: Int64?
        public var actualCacheUsed: Int64?
        /// iCloud (personal) bytes in use, free, and the limit (nil for 0: the overall one).
        public var personalUsed: Int64?
        public var personalFree: Int64?
        public var personalLimit: Int64?
        /// The highest cache pressure in the last hour, 0 to 100.
        public var pressurePercent: Int?
        public var categories: [Category]
        /// When the counters below started.
        public var countersSince: Date?
        public var returnedToClients: Int64?
        public var returnedToPeers: Int64?
        public var returnedToChildren: Int64?
        public var storedFromOrigin: Int64?
        public var storedFromParents: Int64?
        public var storedFromPeers: Int64?
        public var imported: Int64?
        public var dropped: Int64?
        public var parents: [Parent]
        public var alerts: [Alert]
        public var dataMigration: DataMigration?
        public var port: Int?
        public var publicAddress: String?
        public var serverGuid: String?
        public var isRestrictedMedia: Bool?
        /// `CONTENT_CACHING_ENABLED`, `…_DISABLED` or `…_UNKNOWN`.
        public var tetherator: String?

        public init(isActivated: Bool? = nil, isActive: Bool? = nil, cacheStatus: String? = nil, startupStatus: String? = nil,
                    registration: Registration? = nil, registrationError: String? = nil, registrationResponseCode: Int? = nil,
                    registrationStarted: Date? = nil, cacheUsed: Int64? = nil, cacheFree: Int64? = nil, cacheLimit: Int64? = nil,
                    actualCacheUsed: Int64? = nil, personalUsed: Int64? = nil, personalFree: Int64? = nil,
                    personalLimit: Int64? = nil, pressurePercent: Int? = nil, categories: [Category] = [],
                    countersSince: Date? = nil, returnedToClients: Int64? = nil, returnedToPeers: Int64? = nil,
                    returnedToChildren: Int64? = nil, storedFromOrigin: Int64? = nil, storedFromParents: Int64? = nil,
                    storedFromPeers: Int64? = nil, imported: Int64? = nil, dropped: Int64? = nil, parents: [Parent] = [],
                    alerts: [Alert] = [], dataMigration: DataMigration? = nil, port: Int? = nil, publicAddress: String? = nil,
                    serverGuid: String? = nil, isRestrictedMedia: Bool? = nil, tetherator: String? = nil) {
            self.isActivated = isActivated
            self.isActive = isActive
            self.cacheStatus = cacheStatus
            self.startupStatus = startupStatus
            self.registration = registration
            self.registrationError = registrationError
            self.registrationResponseCode = registrationResponseCode
            self.registrationStarted = registrationStarted
            self.cacheUsed = cacheUsed
            self.cacheFree = cacheFree
            self.cacheLimit = cacheLimit
            self.actualCacheUsed = actualCacheUsed
            self.personalUsed = personalUsed
            self.personalFree = personalFree
            self.personalLimit = personalLimit
            self.pressurePercent = pressurePercent
            self.categories = categories
            self.countersSince = countersSince
            self.returnedToClients = returnedToClients
            self.returnedToPeers = returnedToPeers
            self.returnedToChildren = returnedToChildren
            self.storedFromOrigin = storedFromOrigin
            self.storedFromParents = storedFromParents
            self.storedFromPeers = storedFromPeers
            self.imported = imported
            self.dropped = dropped
            self.parents = parents
            self.alerts = alerts
            self.dataMigration = dataMigration
            self.port = port
            self.publicAddress = publicAddress
            self.serverGuid = serverGuid
            self.isRestrictedMedia = isRestrictedMedia
            self.tetherator = tetherator
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            /// A limit of 0 is “none”.
            func limit(_ key: AnyKey) -> Int64? { c.bytes(key).flatMap { $0 > 0 ? $0 : nil } }
            var categories = (c.object([Tolerant<Category>].self, "cacheDetails") ?? []).compactMap(\.value)
            if categories.isEmpty, let text = c.text("cacheDetails") { categories = Category.parse(text: text) }
            let migration = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "dataMigrationError")
            self.init(
                isActivated: c.flag("activated"), isActive: c.flag("active"), cacheStatus: c.text("cacheStatus"),
                startupStatus: c.text("startupStatus"), registration: c.text("registrationStatus").map(Registration.init),
                registrationError: c.text("registrationError"), registrationResponseCode: c.number("registrationResponseCode"),
                registrationStarted: c.date("registrationStarted"), cacheUsed: c.bytes("cacheBytesUsed"),
                cacheFree: c.bytes("cacheBytesFree"), cacheLimit: limit("cacheBytesLimit"),
                actualCacheUsed: c.bytes("actualCacheBytesUsed"), personalUsed: c.bytes("personalCacheBytesUsed"),
                personalFree: c.bytes("personalCacheBytesFree"), personalLimit: limit("personalCacheBytesLimit"),
                pressurePercent: c.number("maxCachePressureLast1HourPercentage"), categories: categories,
                countersSince: c.date("totalBytesAreSince"), returnedToClients: c.bytes("totalBytesReturnedToClients"),
                returnedToPeers: c.bytes("totalBytesReturnedToPeers"), returnedToChildren: c.bytes("totalBytesReturnedToChildren"),
                storedFromOrigin: c.bytes("totalBytesStoredFromOrigin"), storedFromParents: c.bytes("totalBytesStoredFromParents"),
                storedFromPeers: c.bytes("totalBytesStoredFromPeers"), imported: c.bytes("totalBytesImported"),
                dropped: c.bytes("totalBytesDropped"),
                parents: (c.object([Tolerant<Parent>].self, "parents") ?? []).compactMap(\.value),
                alerts: (c.object([Tolerant<Alert>].self, "alerts") ?? []).compactMap(\.value),
                dataMigration: DataMigration(completed: c.flag("dataMigrationCompleted"),
                                             percent: c.number("dataMigrationProgressPercentage"),
                                             errorCode: migration?.number("code"), errorDomain: migration?.text("domain")),
                port: c.number("port"), publicAddress: c.text("publicAddress"), serverGuid: c.text("serverGuid"),
                isRestrictedMedia: c.flag("restrictedMedia"), tetherator: c.text("tetheratorStatus"))
        }

        /// The largest category that isn’t personal (iCloud); nil without one.
        public var topCategory: Category? {
            categories.filter { !$0.isPersonal && $0.bytes > 0 }.max { $0.bytes < $1.bytes }
        }
    }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// A byte count: a whole number (64-bit), or a string holding one.
    func bytes(_ key: AnyKey) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let double = try? decodeIfPresent(Double.self, forKey: key), double.isFinite { return Int64(double) }
        return (try? decodeIfPresent(String.self, forKey: key)).flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }
}
