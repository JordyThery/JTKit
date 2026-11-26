import Foundation

extension JamfPlatform {
    /// Apple’s content caching declaration in a Blueprint
    /// (`com.apple.configuration.content-cache.settings`, macOS 27), with
    /// the step and component it is in. Jamf sends it from a declarations
    /// component (`com.jamf.ddm-strict`, or `com.jamf.ddm.custom-declarations`)
    /// as `Blueprint_<id>_s<step>_c<component>_declaration_custom_<n>`. Every
    /// key is optional; nil means “not set here” (Apple’s default applies).
    /// Read only.
    public struct ContentCacheSettings: Hashable, Sendable {
        public static let declarationType = "com.apple.configuration.content-cache.settings"

        public var stepIndex: Int
        public var componentIndex: Int
        /// The declaration’s place in its component (`_declaration_custom_<n>`).
        public var declarationIndex: Int
        public var stepName: String?
        public var activationPredicate: String?
        /// The component’s identifier, e.g. `com.jamf.ddm-strict`.
        public var componentIdentifier: String?

        public var autoActivation: Bool?
        public var denyActivation: Bool?
        public var allowPersonalCaching: Bool?
        public var allowSharedCaching: Bool?
        /// Bytes; 0 (unlimited) reads as nil.
        public var cacheLimit: Int64?
        public var personalCacheLimit: Int64?
        public var parents: [String]?
        public var parentSelectionPolicy: String?
        /// 0 (a random port) reads as nil.
        public var port: Int?
        public var localSubnetsOnly: Bool?
        public var listenRangesOnly: Bool?
        public var peerLocalSubnetsOnly: Bool?
        public var keepAwake: Bool?
        public var allowCacheDelete: Bool?
        public var dataPath: String?
        /// Seconds between `content-cache.info` status reports; nil or 0: none are sent.
        public var declarativeStatusInterval: Int?
        public var displayAlerts: Bool?
        public var logClientIdentity: Bool?

        public init(stepIndex: Int, componentIndex: Int, declarationIndex: Int = 0, stepName: String? = nil,
                    activationPredicate: String? = nil, componentIdentifier: String? = nil, autoActivation: Bool? = nil,
                    denyActivation: Bool? = nil, allowPersonalCaching: Bool? = nil, allowSharedCaching: Bool? = nil,
                    cacheLimit: Int64? = nil, personalCacheLimit: Int64? = nil, parents: [String]? = nil,
                    parentSelectionPolicy: String? = nil, port: Int? = nil, localSubnetsOnly: Bool? = nil,
                    listenRangesOnly: Bool? = nil, peerLocalSubnetsOnly: Bool? = nil, keepAwake: Bool? = nil,
                    allowCacheDelete: Bool? = nil, dataPath: String? = nil, declarativeStatusInterval: Int? = nil,
                    displayAlerts: Bool? = nil, logClientIdentity: Bool? = nil) {
            self.stepIndex = stepIndex
            self.componentIndex = componentIndex
            self.declarationIndex = declarationIndex
            self.stepName = stepName
            self.activationPredicate = activationPredicate
            self.componentIdentifier = componentIdentifier
            self.autoActivation = autoActivation
            self.denyActivation = denyActivation
            self.allowPersonalCaching = allowPersonalCaching
            self.allowSharedCaching = allowSharedCaching
            self.cacheLimit = cacheLimit
            self.personalCacheLimit = personalCacheLimit
            self.parents = parents
            self.parentSelectionPolicy = parentSelectionPolicy
            self.port = port
            self.localSubnetsOnly = localSubnetsOnly
            self.listenRangesOnly = listenRangesOnly
            self.peerLocalSubnetsOnly = peerLocalSubnetsOnly
            self.keepAwake = keepAwake
            self.allowCacheDelete = allowCacheDelete
            self.dataPath = dataPath
            self.declarativeStatusInterval = declarativeStatusInterval
            self.displayAlerts = displayAlerts
            self.logClientIdentity = logClientIdentity
        }

        /// From a declaration’s `payload`. A key wrapped as Jamf wraps
        /// settings (`{"Included": …, "Value": …}`) counts only when included.
        init(payload: LosslessJSON, stepIndex: Int, componentIndex: Int, declarationIndex: Int, step: LosslessJSON,
             componentIdentifier: String?) {
            func value(_ key: String) -> LosslessJSON? {
                guard let raw = payload[key], raw != .null else { return nil }
                if raw["Included"]?.bool == false { return nil }
                if let wrapped = raw["Value"] { return wrapped == .null ? nil : wrapped }
                return raw
            }
            func flag(_ key: String) -> Bool? { value(key)?.bool }
            func whole(_ key: String) -> Int? { value(key)?.int }
            func positive(_ key: String) -> Int64? {
                guard let number = value(key)?.text.flatMap({ Int64($0) }), number > 0 else { return nil }
                return number
            }
            self.init(stepIndex: stepIndex, componentIndex: componentIndex, declarationIndex: declarationIndex,
                      stepName: step["name"]?.text, activationPredicate: step["activationPredicate"]?.text,
                      componentIdentifier: componentIdentifier, autoActivation: flag("AutoActivation"),
                      denyActivation: flag("DenyActivation"), allowPersonalCaching: flag("AllowPersonalCaching"),
                      allowSharedCaching: flag("AllowSharedCaching"), cacheLimit: positive("CacheLimit"),
                      personalCacheLimit: positive("PersonalCacheLimit"),
                      parents: value("Parents")?.arrayValue?.compactMap(\.text),
                      parentSelectionPolicy: value("ParentSelectionPolicy")?.text,
                      port: whole("Port").flatMap { $0 > 0 ? $0 : nil }, localSubnetsOnly: flag("LocalSubnetsOnly"),
                      listenRangesOnly: flag("ListenRangesOnly"), peerLocalSubnetsOnly: flag("PeerLocalSubnetsOnly"),
                      keepAwake: flag("KeepAwake"), allowCacheDelete: flag("AllowCacheDelete"), dataPath: value("DataPath")?.text,
                      declarativeStatusInterval: whole("DeclarativeStatusInterval"), displayAlerts: flag("DisplayAlerts"),
                      logClientIdentity: flag("LogClientIdentity"))
        }

        /// Whether the Mac sends `content-cache.info` on its own, at an interval.
        public var sendsLiveFigures: Bool { (declarativeStatusInterval ?? 0) > 0 }

        /// What every declaration identifier Jamf makes for this step and
        /// component starts with: `Blueprint_<id>_s<step>_c<component>_`
        /// (both counted from 1). The step’s activation shares it
        /// (`…_s1_c1_sys_act1`).
        public static func identifierPrefix(blueprintID: String, stepIndex: Int, componentIndex: Int) -> String {
            "Blueprint_\(blueprintID.lowercased())_s\(stepIndex + 1)_c\(componentIndex + 1)_"
        }

        public func identifierPrefix(blueprintID: String) -> String {
            Self.identifierPrefix(blueprintID: blueprintID, stepIndex: stepIndex, componentIndex: componentIndex)
        }

        /// The configuration’s identifier as Jamf names it
        /// (`…_declaration_custom_<n>`, seen on a tenant on 2026-11-25).
        public func configurationIdentifier(blueprintID: String) -> String {
            identifierPrefix(blueprintID: blueprintID) + "declaration_custom_\(declarationIndex)"
        }

        /// Whether an identifier is an activation (`…_act<N>`).
        public static func isActivation(_ identifier: String) -> Bool {
            identifier.range(of: "_act[0-9]+$", options: .regularExpression) != nil
        }
    }
}

extension JamfPlatform.BlueprintDetail {
    /// Every content caching declaration, in step and component order: any
    /// component that lists declarations (`configuration.declarations`)
    /// holding one of type `com.apple.configuration.content-cache.settings`.
    public var contentCacheSettings: [JamfPlatform.ContentCacheSettings] {
        let steps = steps?.arrayValue ?? []
        return components.flatMap { component -> [JamfPlatform.ContentCacheSettings] in
            let step = component.stepIndex < steps.count ? steps[component.stepIndex] : .null
            let declarations = component.json["configuration"]?["declarations"]?.arrayValue ?? []
            return declarations.enumerated().compactMap { index, declaration in
                guard declaration["type"]?.text == JamfPlatform.ContentCacheSettings.declarationType else { return nil }
                return JamfPlatform.ContentCacheSettings(
                    payload: declaration["payload"] ?? .null, stepIndex: component.stepIndex,
                    componentIndex: component.index, declarationIndex: index, step: step,
                    componentIdentifier: component.identifier)
            }
        }
    }

    /// Whether the Blueprint sends a content caching declaration.
    public var isCachingBlueprint: Bool { !contentCacheSettings.isEmpty }
}

extension JamfPlatform.Blueprints {
    /// What `cachingBlueprints(skipping:)` found.
    public struct CachingBlueprints: Sendable {
        /// The Blueprints with a content caching declaration, and those declarations.
        public var blueprints: [(blueprint: JamfPlatform.BlueprintDetail, settings: [JamfPlatform.ContentCacheSettings])]
        /// The Blueprints without one, each with its `updated` time: pass
        /// it in next time, so an unchanged one isn’t read again.
        public var notCaching: [String: String]
        /// Blueprint details read in this call.
        public var detailsRead: Int
    }

    /// Every Blueprint with a content caching declaration (`blueprints:read`,
    /// GET only). The list gives each Blueprint’s `updated` time; a
    /// Blueprint in `skipping` with the same time is known to have none and
    /// isn’t read again. One without an `updated` time is always read.
    public func cachingBlueprints(skipping: [String: String] = [:]) async throws -> CachingBlueprints {
        let overviews = try await list()
        var found = CachingBlueprints(blueprints: [], notCaching: [:], detailsRead: 0)
        for overview in overviews {
            try Task.checkCancellation()
            if let updated = overview.updated, skipping[overview.id] == updated {
                found.notCaching[overview.id] = updated
                continue
            }
            let blueprint = try await detail(id: overview.id)
            found.detailsRead += 1
            let settings = blueprint.contentCacheSettings
            if settings.isEmpty {
                if let updated = blueprint.overview.updated ?? overview.updated { found.notCaching[overview.id] = updated }
            } else {
                found.blueprints.append((blueprint, settings))
            }
        }
        return found
    }
}
