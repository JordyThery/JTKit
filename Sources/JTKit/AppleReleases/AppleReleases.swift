import Foundation

/// Apple’s OS releases from two public sources: SOFA, the Mac Admins Open
/// Source feed (`sofafeed.macadmins.io`, v2), and Apple’s own software lookup
/// service, GDMF (`gdmf.apple.com/v2/pmv`). Read only, without credentials.
///
/// iPhones and iPads are matched by model (`iPad13,18`), Macs by model
/// (`Mac14,2`, through SOFA’s model list) or by board ID (`J413AP`, what
/// Apple’s catalog and a Mac’s `softwareupdate.device-id` status item use).
public enum AppleReleases {
    public enum Platform: String, Sendable, Hashable, Codable, CaseIterable {
        /// iOS and iPadOS.
        case iOS
        case macOS
    }

    public struct Release: Hashable, Sendable {
        public var platform: Platform
        public var version: OSVersion
        public var build: String?
        public var releaseDate: Date?
        /// Until when Apple lets MDM ask for it (GDMF); nil: no end given.
        public var expirationDate: Date?
        /// Models (iPhone, iPad) or board IDs (Mac) Apple offers it to.
        public var supportedDevices: Set<String>
        public var securityInfo: URL?
        /// Each entry GDMF has for this version: Apple can post a version in
        /// several builds, each for its own devices and with its own date.
        public var postings: [Posting]

        /// One GDMF entry of a version.
        public struct Posting: Hashable, Sendable {
            public var build: String?
            /// The models (iPhone, iPad) or board IDs (Mac) it is for.
            public var devices: Set<String>
            /// Its `PostingDate`.
            public var date: Date?
            /// From `PublicAssetSets` (Apple’s public catalog, which Jamf counts
            /// an update’s delay from), else from `AssetSets`.
            public var isPublic: Bool

            public init(build: String? = nil, devices: Set<String> = [], date: Date? = nil, isPublic: Bool) {
                self.build = build
                self.devices = devices
                self.date = date
                self.isPublic = isPublic
            }
        }

        public init(platform: Platform, version: OSVersion, build: String? = nil, releaseDate: Date? = nil,
                    expirationDate: Date? = nil, supportedDevices: Set<String> = [], securityInfo: URL? = nil,
                    postings: [Posting] = []) {
            self.postings = postings
            self.platform = platform
            self.version = version
            self.build = build
            self.releaseDate = releaseDate
            self.expirationDate = expirationDate
            self.supportedDevices = supportedDevices
            self.securityInfo = securityInfo
        }
    }

    /// What both sources say, merged. Built from the feeds’ data, so it can
    /// be tested and kept as it is.
    public struct Catalog: Sendable {
        /// Every release, newest first per platform.
        public private(set) var releases: [Release] = []
        /// What couldn’t be read, e.g. “GDMF: no answer”; the rest is still used.
        public var problems: [String] = []
        private var latestByMajor: [Platform: [Int: Release]] = [:]
        private var supportedByMajor: [Platform: [Int: Set<String>]] = [:]
        /// Mac model → the majors it runs (SOFA’s `Models`).
        private var macMajors: [String: Set<Int>] = [:]
        /// Board ID → Mac model (SOFA’s `Devices`).
        private var macModelByBoard: [String: String] = [:]
        private var names: [String: String] = [:]

        public init() {}

        /// Reads whatever was fetched; each source may be missing.
        ///
        /// - Throws: `AppleReleases.FeedError` when a source that is given
        ///   isn’t one of these feeds.
        public init(sofaIOS: Data? = nil, sofaMacOS: Data? = nil, gdmf: Data? = nil) throws {
            if let sofaIOS { try readSOFA(sofaIOS, platform: .iOS) }
            if let sofaMacOS { try readSOFA(sofaMacOS, platform: .macOS) }
            if let gdmf { try readGDMF(gdmf) }
            finish()
        }

        // MARK: Questions

        /// The majors with a release, newest first.
        public func majors(_ platform: Platform) -> [Int] {
            (latestByMajor[platform] ?? [:]).keys.sorted(by: >)
        }

        /// The newest release of `major`, or of the newest major.
        public func latest(_ platform: Platform, major: Int? = nil) -> Release? {
            guard let major = major ?? majors(platform).first else { return nil }
            return latestByMajor[platform]?[major]
        }

        /// The release of exactly this version.
        public func release(_ version: OSVersion, _ platform: Platform) -> Release? {
            releases.first { $0.platform == platform && $0.version == version }
        }

        public func build(of version: OSVersion, _ platform: Platform) -> String? {
            release(version, platform)?.build
        }

        /// Models and board IDs that can run `major`; empty when unknown.
        public func supportedDevices(_ platform: Platform, major: Int) -> Set<String> {
            var devices = supportedByMajor[platform]?[major] ?? []
            if platform == .macOS {
                devices.formUnion(macMajors.filter { $0.value.contains(major) }.keys)
            }
            return devices
        }

        /// Whether a device can run `major`: true or false when a source
        /// knows the model (or board ID), nil when none does.
        public func supports(model: String?, boardID: String? = nil, major: Int, _ platform: Platform) -> Bool? {
            let model = model.flatMap { $0.isEmpty ? nil : $0 }
            let boardID = boardID.flatMap { $0.isEmpty ? nil : $0 }
            if platform == .macOS {
                let macModel = model ?? boardID.flatMap { macModelByBoard[$0] }
                if let macModel, let majors = macMajors[macModel] { return majors.contains(major) }
                if let boardID, isKnown(boardID, .macOS) { return supportedDevices(.macOS, major: major).contains(boardID) }
                return nil
            }
            guard let id = model ?? boardID, isKnown(id, platform) else { return nil }
            return supportedDevices(platform, major: major).contains(id)
        }

        /// The public posting (GDMF `PublicAssetSets`) of a release meant for
        /// this device: the one listing its device ID, else its model’s boards
        /// (recognized as in `supports(release:model:boardID:)`); for a device
        /// none lists, the posting for the most devices. Nil when Apple’s
        /// public catalog has no posting of the release.
        public func publicPosting(of release: Release, model: String?, boardID: String?) -> Release.Posting? {
            let postings = release.postings.filter { $0.isPublic && $0.date != nil }
            guard !postings.isEmpty else { return nil }
            let ids = recognizedIDs(major: release.version.major, release.platform, model: model, boardID: boardID)
            for id in ids.ordered {
                if let posting = postings.first(where: { $0.devices.contains(id) }) { return posting }
            }
            return postings.max { $0.devices.count != $1.devices.count ? $0.devices.count < $1.devices.count : ($0.build ?? "") > ($1.build ?? "") }
        }

        /// The build of a release meant for this device: its posting’s build
        /// (public or not), else the release’s.
        public func build(of release: Release, model: String?, boardID: String?) -> String? {
            let ids = recognizedIDs(major: release.version.major, release.platform, model: model, boardID: boardID)
            for id in ids.ordered {
                if let posting = release.postings.first(where: { $0.devices.contains(id) && $0.build != nil }) { return posting.build }
            }
            return release.postings.filter { $0.build != nil }.max { $0.devices.count < $1.devices.count }?.build ?? release.build
        }

        /// The IDs Apple lists for `major` that are this device’s: its device
        /// ID first, then its model and the boards of its model.
        private func recognizedIDs(major: Int, _ platform: Platform, model: String?, boardID: String?) -> (ordered: [String], set: Set<String>) {
            let listed = supportedByMajor[platform]?[major] ?? []
            var ordered: [String] = []
            if let boardID = boardID.flatMap({ $0.isEmpty ? nil : $0 }), listed.contains(boardID) { ordered.append(boardID) }
            if let model = model.flatMap({ $0.isEmpty ? nil : $0 }) {
                ordered += ([model] + macModelByBoard.filter { $0.value == model }.keys.sorted()).filter { listed.contains($0) }
            }
            return (ordered, Set(ordered))
        }

        /// Whether Apple offers this release to a device, by the release’s own
        /// device list (a point release can be for some models only).
        ///
        /// The device is recognized by its own device ID first (the status
        /// report’s `softwareupdate.device-id`), then by its model (for a Mac,
        /// the boards of its model), and only when Apple lists that ID for
        /// the release’s major. A device it doesn’t recognize, such as an Intel
        /// Mac reporting `X86LEGACYAP`, is unknown: nil, never false, so only
        /// the major can be checked. Nil too for a release without a list.
        public func supports(release: Release, model: String?, boardID: String?) -> Bool? {
            guard !release.supportedDevices.isEmpty else { return nil }
            let listed = supportedByMajor[release.platform]?[release.version.major] ?? []
            if let boardID = boardID.flatMap({ $0.isEmpty ? nil : $0 }), listed.contains(boardID) {
                return release.supportedDevices.contains(boardID)
            }
            guard let model = model.flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
            // a Mac's releases list board IDs: the boards of its model
            let ids = Set([model]).union(macModelByBoard.filter { $0.value == model }.keys).intersection(listed)
            guard !ids.isEmpty else { return nil }
            return !ids.isDisjoint(with: release.supportedDevices)
        }

        /// The newest version a device can run, from the newest major that
        /// supports it; nil when no source knows the device.
        public func lastSupportedVersion(model: String?, boardID: String? = nil, _ platform: Platform) -> OSVersion? {
            for major in majors(platform) where supports(model: model, boardID: boardID, major: major, platform) == true {
                return latest(platform, major: major)?.version
            }
            return nil
        }

        /// e.g. “iPad mini (5th generation) Wi-Fi”, for a model or board ID.
        public func marketingName(_ identifier: String) -> String? {
            names[identifier] ?? macModelByBoard[identifier].flatMap { names[$0] }
        }

        private func isKnown(_ id: String, _ platform: Platform) -> Bool {
            (supportedByMajor[platform] ?? [:]).values.contains { $0.contains(id) }
        }

        // MARK: Reading

        private mutating func readSOFA(_ data: Data, platform: Platform) throws {
            guard let json = try? LosslessJSON(data: data), let versions = json["OSVersions"]?.arrayValue else {
                throw FeedError(source: "SOFA (\(platform.rawValue))")
            }
            for entry in versions {
                guard let major = entry["OSVersion"]?.text.flatMap(OSVersion.init)?.major else { continue }
                let latest = entry["Latest"].flatMap { Self.sofaRelease($0, platform) }
                if let latest {
                    add(latest)
                    supportedByMajor[platform, default: [:]][major, default: []].formUnion(latest.supportedDevices)
                }
                for security in entry["SecurityReleases"]?.arrayValue ?? [] {
                    if let release = Self.sofaRelease(security, platform), release.version != latest?.version { add(release) }
                }
            }
            for (model, info) in json["Models"]?.objectValue?.members.map({ ($0.key, $0.value) }) ?? [] {
                let majors = (info["OSVersions"]?.arrayValue ?? []).compactMap(\.int)
                if !majors.isEmpty { macMajors[model] = Set(majors) }
                if let name = info["MarketingName"]?.text { names[model] = name }
            }
            for (id, info) in json["Devices"]?.objectValue?.members.map({ ($0.key, $0.value) }) ?? [] {
                if let model = info["DeviceID"]?.text { macModelByBoard[id] = model }
                if let name = info["MarketingName"]?.text, names[id] == nil { names[id] = name }
            }
        }

        private mutating func readGDMF(_ data: Data) throws {
            guard let json = try? LosslessJSON(data: data), json["PublicAssetSets"] != nil || json["AssetSets"] != nil else {
                throw FeedError(source: "GDMF")
            }
            for set in ["PublicAssetSets", "AssetSets"] {
                for (key, platform) in [("iOS", Platform.iOS), ("macOS", .macOS)] {
                    for entry in json[set]?[key]?.arrayValue ?? [] {
                        guard let version = entry["ProductVersion"]?.text.flatMap(OSVersion.init) else { continue }
                        var devices = Set((entry["SupportedDevices"]?.arrayValue ?? []).compactMap(\.text))
                        if platform == .iOS {
                            // Apple’s iOS list also holds Apple Watch and other releases
                            devices = devices.filter { $0.hasPrefix("iPhone") || $0.hasPrefix("iPad") || $0.hasPrefix("iPod") }
                            if devices.isEmpty { continue }
                        }
                        let posted = entry["PostingDate"]?.text.flatMap(Self.date)
                        let release = Release(platform: platform, version: version, build: entry["Build"]?.text,
                                              releaseDate: posted,
                                              expirationDate: entry["ExpirationDate"]?.text.flatMap(Self.date),
                                              supportedDevices: devices,
                                              postings: [Release.Posting(build: entry["Build"]?.text, devices: devices, date: posted,
                                                                         isPublic: set == "PublicAssetSets")])
                        add(release)
                        supportedByMajor[platform, default: [:]][version.major, default: []].formUnion(devices)
                    }
                }
            }
        }

        /// Adds a release, or fills in what an earlier source left out.
        private mutating func add(_ release: Release) {
            if let index = releases.firstIndex(where: { $0.platform == release.platform && $0.version == release.version }) {
                var known = releases[index]
                known.build = known.build ?? release.build
                // the first release date any source gives
                known.releaseDate = [known.releaseDate, release.releaseDate].compactMap { $0 }.min()
                known.postings += release.postings
                known.expirationDate = known.expirationDate ?? release.expirationDate
                known.securityInfo = known.securityInfo ?? release.securityInfo
                known.supportedDevices.formUnion(release.supportedDevices)
                releases[index] = known
            } else {
                releases.append(release)
            }
        }

        private mutating func finish() {
            releases.sort { $0.platform.rawValue == $1.platform.rawValue ? $0.version > $1.version : $0.platform.rawValue < $1.platform.rawValue }
            latestByMajor = [:]
            for release in releases where latestByMajor[release.platform]?[release.version.major] == nil {
                latestByMajor[release.platform, default: [:]][release.version.major] = release
            }
        }

        private static func sofaRelease(_ json: LosslessJSON, _ platform: Platform) -> Release? {
            guard let version = json["ProductVersion"]?.text.flatMap(OSVersion.init) else { return nil }
            return Release(platform: platform, version: version, build: json["Build"]?.text,
                           releaseDate: json["ReleaseDate"]?.text.flatMap(date),
                           expirationDate: json["ExpirationDate"]?.text.flatMap(date),
                           supportedDevices: Set((json["SupportedDevices"]?.arrayValue ?? []).compactMap(\.text)),
                           securityInfo: json["SecurityInfo"]?.text.flatMap(URL.init(string:)))
        }

        /// `2026-10-26T00:00:00Z` or `2026-10-26` (UTC).
        static func date(_ text: String) -> Date? {
            if let date = JamfPlatform.date(from: text) { return date }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: String(text.prefix(10)))
        }
    }

    /// A source answered with something that isn’t its feed.
    public struct FeedError: LocalizedError, Sendable, Hashable {
        public var source: String

        public var errorDescription: String? { "\(source) didn’t answer with release data." }
    }

    /// Reads both sources with GET only, no token and no cookies.
    public struct Client: Sendable {
        public static let sofaURL = URL(string: "https://sofafeed.macadmins.io")!
        public static let gdmfURL = URL(string: "https://gdmf.apple.com")!

        private let sofa: HTTPClient
        private let gdmf: HTTPClient

        /// - Parameters:
        ///   - recorder: its session must not keep cookies (JTKit’s
        ///     ephemeral sessions don’t).
        ///   - userAgent: the app’s own, e.g. “Software Update Dashboard/0.1”,
        ///     as SOFA asks of the tools that read it.
        ///   - sleep: the waits between retries; injectable for tests.
        public init(recorder: RequestRecorder, userAgent: String, sofaURL: URL = Client.sofaURL, gdmfURL: URL = Client.gdmfURL,
                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
            let headers = ["User-Agent": userAgent, "Accept": "application/json"]
            sofa = HTTPClient(baseURL: sofaURL, recorder: recorder, headers: headers, permits: { $0.isRead }, sleep: sleep)
            gdmf = HTTPClient(baseURL: gdmfURL, recorder: recorder, headers: headers, permits: { $0.isRead }, sleep: sleep)
        }

        /// Both sources for the platforms asked for. A source that can’t be
        /// read is named in `problems`; thrown only when nothing could be read.
        public func catalog(_ platforms: Set<Platform> = [.iOS, .macOS]) async throws -> Catalog {
            var problems: [String] = []
            var firstError: Error?
            func fetch(_ client: HTTPClient, _ path: String, _ name: String) async -> Data? {
                do {
                    return try await client.send(HTTPRequest(path: path)).data
                } catch {
                    if error is CancellationError { return nil }
                    problems.append("\(name): \(error.localizedDescription)")
                    firstError = firstError ?? error
                    return nil
                }
            }
            let iOS = platforms.contains(.iOS) ? await fetch(sofa, "v2/ios_data_feed.json", "SOFA (iOS)") : nil
            let macOS = platforms.contains(.macOS) ? await fetch(sofa, "v2/macos_data_feed.json", "SOFA (macOS)") : nil
            let apple = await fetch(gdmf, "v2/pmv", "GDMF")
            try Task.checkCancellation()
            if iOS == nil && macOS == nil && apple == nil, let firstError { throw firstError }
            var catalog = Catalog()
            // each source on its own, so one that can’t be read doesn’t lose the others
            for (data, name) in [(iOS, "SOFA (iOS)"), (macOS, "SOFA (macOS)"), (apple, "GDMF")] {
                guard let data else { continue }
                do {
                    let part = try Catalog(sofaIOS: name == "SOFA (iOS)" ? data : nil,
                                           sofaMacOS: name == "SOFA (macOS)" ? data : nil,
                                           gdmf: name == "GDMF" ? data : nil)
                    catalog.merge(part)
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            catalog.problems = problems
            return catalog
        }
    }
}

extension AppleReleases.Catalog {
    /// Adds another catalog’s releases and device lists.
    public mutating func merge(_ other: AppleReleases.Catalog) {
        for release in other.releases { add(release) }
        for (platform, majors) in other.supportedByMajor {
            for (major, devices) in majors { supportedByMajor[platform, default: [:]][major, default: []].formUnion(devices) }
        }
        macMajors.merge(other.macMajors) { $0.union($1) }
        macModelByBoard.merge(other.macModelByBoard) { first, _ in first }
        names.merge(other.names) { first, _ in first }
        problems += other.problems
        finish()
    }
}
