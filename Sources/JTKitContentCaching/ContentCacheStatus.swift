import Foundation

/// A Mac’s content cache as its DDM status report gives it (macOS 27):
/// Apple’s `content-cache.info`, `.status`, `.parents` and `.peers`
/// items, read from a device’s status items (`DDMStatusItem`; JTKit reads them
/// with `statusItems(managementID:kind:)`, `devices:read`).
///
/// Jamf Pro keeps them as separate flattened keys
/// (`content-cache.info.cache-used`, seen on a tenant), as one key with a
/// nested JSON value, or as Java’s `{key=value, …}` text; all three are
/// read. **Older keys are ignored:** a Mac sends an item only when it
/// changes and can leave out keys it no longer has, while Jamf keeps the
/// old ones; so within one item every key more than
/// `staleTolerance` older than the item’s newest key is dropped
/// (`droppedKeys`). Items are independent of each other.
public nonisolated struct ContentCacheStatus: Hashable, Sendable {
    /// Keys of one item written within this many seconds of its newest count as current.
    public static let staleTolerance: TimeInterval = 60

    /// `content-cache.info`: sent only at the declaration’s `DeclarativeStatusInterval`.
    public struct Info: Hashable, Sendable {
        public var cacheUsed: Int64?
        public var cacheFree: Int64?
        /// Nil for 0 (no limit).
        public var cacheLimit: Int64?
        public var cacheStatus: String?
        /// 0 to 100. Apple documents a fraction (`0.15`); a whole number is read as a percentage.
        public var pressurePercent: Int?
        public var personalUsed: Int64?
        public var personalFree: Int64?
        public var personalLimit: Int64?
        public var categories: [ContentCaching.Category]
        /// The item’s newest key, as Jamf Pro wrote it (its local time, no zone).
        public var updated: String?

        public init(cacheUsed: Int64? = nil, cacheFree: Int64? = nil, cacheLimit: Int64? = nil, cacheStatus: String? = nil,
                    pressurePercent: Int? = nil, personalUsed: Int64? = nil, personalFree: Int64? = nil,
                    personalLimit: Int64? = nil, categories: [ContentCaching.Category] = [], updated: String? = nil) {
            self.cacheUsed = cacheUsed
            self.cacheFree = cacheFree
            self.cacheLimit = cacheLimit
            self.cacheStatus = cacheStatus
            self.pressurePercent = pressurePercent
            self.personalUsed = personalUsed
            self.personalFree = personalFree
            self.personalLimit = personalLimit
            self.categories = categories
            self.updated = updated
        }
    }

    /// `content-cache.status`.
    public struct Status: Hashable, Sendable {
        public var serverGuid: String?
        public var isActivated: Bool?
        public var isActive: Bool?
        public var cacheStatus: String?
        public var startupStatus: String?
        public var privateAddresses: [String]
        public var publicAddress: String?
        public var port: Int?
        /// Apple’s number, e.g. 1.
        public var registrationStatus: Int?
        public var registrationError: String?
        public var registrationResponseCode: Int?
        public var tetheratorStatus: Int?
        public var sendingReports: Bool?
        public var version: String?
        public var updated: String?

        public init(serverGuid: String? = nil, isActivated: Bool? = nil, isActive: Bool? = nil, cacheStatus: String? = nil,
                    startupStatus: String? = nil, privateAddresses: [String] = [], publicAddress: String? = nil,
                    port: Int? = nil, registrationStatus: Int? = nil, registrationError: String? = nil,
                    registrationResponseCode: Int? = nil, tetheratorStatus: Int? = nil, sendingReports: Bool? = nil,
                    version: String? = nil, updated: String? = nil) {
            self.serverGuid = serverGuid
            self.isActivated = isActivated
            self.isActive = isActive
            self.cacheStatus = cacheStatus
            self.startupStatus = startupStatus
            self.privateAddresses = privateAddresses
            self.publicAddress = publicAddress
            self.port = port
            self.registrationStatus = registrationStatus
            self.registrationError = registrationError
            self.registrationResponseCode = registrationResponseCode
            self.tetheratorStatus = tetheratorStatus
            self.sendingReports = sendingReports
            self.version = version
            self.updated = updated
        }
    }

    /// One parent or peer cache (`content-cache.parents`, `.peers`).
    public struct Neighbor: Hashable, Sendable {
        public var identifier: String?
        public var address: String?
        public var port: Int?
        public var isHealthy: Bool?
        /// Peers only.
        public var isFriendly: Bool?
        public var version: String?

        public init(identifier: String? = nil, address: String? = nil, port: Int? = nil, isHealthy: Bool? = nil,
                    isFriendly: Bool? = nil, version: String? = nil) {
            self.identifier = identifier
            self.address = address
            self.port = port
            self.isHealthy = isHealthy
            self.isFriendly = isFriendly
            self.version = version
        }
    }

    public var info: Info?
    public var status: Status?
    /// Nil when the report has no `content-cache.parents` item; empty when it lists none.
    public var parents: [Neighbor]?
    public var peers: [Neighbor]?
    /// The keys left out because they were older than their item’s newest.
    public var droppedKeys: [String]

    public init(info: Info? = nil, status: Status? = nil, parents: [Neighbor]? = nil, peers: [Neighbor]? = nil,
                droppedKeys: [String] = []) {
        self.info = info
        self.status = status
        self.parents = parents
        self.peers = peers
        self.droppedKeys = droppedKeys
    }

    /// Nil when the report has no `content-cache.*` item (a Mac before
    /// macOS 27, or one whose cache never reported).
    public init?(items: [DDMStatusItem]) {
        let groups = ["content-cache.info", "content-cache.status", "content-cache.parents", "content-cache.peers"]
        var kept: [String: [DDMStatusItem]] = [:]
        var dropped: [String] = []
        for group in groups {
            let members = items.filter { $0.key == group || $0.key.hasPrefix(group + ".") || $0.key.hasPrefix(group + "[") }
            guard !members.isEmpty else { continue }
            let current = Self.current(members)
            kept[group] = current.kept
            dropped += current.dropped
        }
        guard !kept.isEmpty else { return nil }
        self.init(droppedKeys: dropped.sorted())
        if let items = kept["content-cache.info"] { info = Self.info(items) }
        if let items = kept["content-cache.status"] { status = Self.status(items) }
        if let items = kept["content-cache.parents"] { parents = Self.neighbors(items, group: "content-cache.parents") }
        if let items = kept["content-cache.peers"] { peers = Self.neighbors(items, group: "content-cache.peers") }
    }

    /// The keys of one item written within `staleTolerance` of its newest;
    /// a key without a time is kept.
    static func current(_ items: [DDMStatusItem]) -> (kept: [DDMStatusItem], dropped: [String]) {
        func time(_ item: DDMStatusItem) -> Date? {
            item.lastUpdateTime.flatMap { ServerTime.date($0, timeZone: TimeZone(identifier: "UTC") ?? .gmt) }
        }
        guard let newest = items.compactMap(time).max() else { return (items, []) }
        var kept: [DDMStatusItem] = []
        var dropped: [String] = []
        for item in items {
            if let date = time(item), newest.timeIntervalSince(date) > staleTolerance {
                dropped.append(item.key)
            } else {
                kept.append(item)
            }
        }
        return (kept, dropped)
    }

    /// A field of an item: its flattened key (`group.sub`), or `sub` in the
    /// group’s nested value.
    private static func reader(_ items: [DDMStatusItem], group: String) -> (String) -> String? {
        var values: [String: String] = [:]
        for item in items {
            guard let text = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  text != "null", text != "None" else { continue }
            values[item.key] = text
        }
        let whole = values[group]
        return { sub in
            values[group + "." + sub] ?? whole.flatMap { text in
                switch sub {
                case "cache-details": details(in: text)
                case "private-addresses": list(sub, in: text) ?? FlattenedFields.field(sub, in: text)
                default: FlattenedFields.field(sub, in: text)
                }
            }
        }
    }

    /// `cache-details` in a nested value: its JSON string, or in Java text
    /// everything up to the next `key=` or the closing brace (the value
    /// holds commas itself).
    private static func details(in text: String) -> String? {
        if text.contains("\"cache-details\"") { return FlattenedFields.field("cache-details", in: text) }
        guard let match = text.firstMatch(of: /cache-details=(.*?)(?:, ?[a-z-]+=|\}\s*$)/) else { return nil }
        let value = String(match.output.1).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// A list value in a nested value: `"sub": [ … ]` or `sub=[ … ]`, as
    /// the text between the brackets.
    private static func list(_ sub: String, in text: String) -> String? {
        let name = NSRegularExpression.escapedPattern(for: sub)
        guard let range = text.range(of: "\"?\(name)\"?\\s*[:=]\\s*\\[[^\\]]*\\]", options: .regularExpression),
              let open = text[range].firstIndex(of: "[") else { return nil }
        return String(text[text.index(after: open)..<text.index(before: range.upperBound)])
    }

    private static func bytes(_ text: String?) -> Int64? {
        text.flatMap { Int64($0) ?? Double($0).map { Int64($0) } }
    }

    private static func limit(_ text: String?) -> Int64? { bytes(text).flatMap { $0 > 0 ? $0 : nil } }

    private static func newest(_ items: [DDMStatusItem]) -> String? { items.compactMap(\.lastUpdateTime).max() }

    /// Apple’s fraction (`0.15`) as 15; a whole number as it is.
    static func percent(_ text: String?) -> Int? {
        guard let text, let value = Double(text), value.isFinite, value >= 0 else { return nil }
        if text.contains("."), value <= 1 { return Int((value * 100).rounded()) }
        return Int(value.rounded())
    }

    static func info(_ items: [DDMStatusItem]) -> Info {
        let field = reader(items, group: "content-cache.info")
        return Info(cacheUsed: bytes(field("cache-used")), cacheFree: bytes(field("cache-free")),
                    cacheLimit: limit(field("cache-limit")), cacheStatus: field("cache-status"),
                    pressurePercent: percent(field("max-cache-pressure-last-hour")),
                    personalUsed: bytes(field("personal-cache-used")), personalFree: bytes(field("personal-cache-free")),
                    personalLimit: limit(field("personal-cache-limit")),
                    categories: field("cache-details").map(ContentCaching.Category.parse(text:)) ?? [],
                    updated: newest(items))
    }

    static func status(_ items: [DDMStatusItem]) -> Status {
        let field = reader(items, group: "content-cache.status")
        // one address, a comma-separated list, or a JSON list
        let addresses = field("private-addresses").map { text in
            text.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }.filter { !$0.isEmpty }
        } ?? []
        return Status(serverGuid: field("server-guid"), isActivated: field("activated").flatMap(FlattenedFields.bool),
                      isActive: field("active").flatMap(FlattenedFields.bool), cacheStatus: field("cache-status"),
                      startupStatus: field("startup-status"), privateAddresses: addresses,
                      publicAddress: field("public-address"), port: field("port").flatMap { Int($0) },
                      registrationStatus: field("registration-status").flatMap { Int($0) },
                      registrationError: field("registration-error"),
                      registrationResponseCode: field("registration-response-code").flatMap { Int($0) },
                      tetheratorStatus: field("tetherator-status").flatMap { Int($0) },
                      sendingReports: field("sending-reports").flatMap(FlattenedFields.bool),
                      version: field("version"), updated: newest(items))
    }

    /// The entries of a parents or peers item: from flattened keys with an
    /// index (`group.0.address`, `group[0].address`), or the `{…}` objects of
    /// the nested value (JSON or Java text). Removed entries
    /// (`_removed` true) are left out.
    static func neighbors(_ items: [DDMStatusItem], group: String) -> [Neighbor] {
        func neighbor(_ field: (String) -> String?) -> Neighbor? {
            if field("_removed").flatMap(FlattenedFields.bool) == true { return nil }
            let entry = Neighbor(identifier: field("identifier"), address: field("address"),
                                 port: field("port").flatMap { Int($0) },
                                 isHealthy: field("healthy").flatMap(FlattenedFields.bool),
                                 isFriendly: field("friendly").flatMap(FlattenedFields.bool), version: field("version"))
            return entry == Neighbor() ? nil : entry
        }
        // flattened with an index
        var indexed: [Int: [String: String]] = [:]
        for item in items {
            guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            let rest = item.key.dropFirst(group.count)
            guard let match = rest.firstMatch(of: /^(?:\.(\d+)|\[(\d+)\])\.([A-Za-z_-]+)$/),
                  let index = Int(match.output.1 ?? match.output.2 ?? "") else { continue }
            indexed[index, default: [:]][String(match.output.3)] = value
        }
        if !indexed.isEmpty {
            return indexed.keys.sorted().compactMap { index in neighbor { indexed[index]?[$0] } }
        }
        guard let text = items.first(where: { $0.key == group })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != "null", text != "None" else { return [] }
        return text.matches(of: /\{[^{}]*\}/).compactMap { match in
            let object = String(match.output)
            return neighbor { FlattenedFields.field($0, in: object) }
        }
    }
}
