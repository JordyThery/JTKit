import Foundation

extension JamfPlatform {
    /// One software update enforcement in a Blueprint: a
    /// `com.jamf.ddm.sw-updates` component, or Apple’s
    /// `com.apple.configuration.softwareupdate.enforcement.specific`
    /// declaration inside a `com.jamf.ddm.custom-declarations` component,
    /// with the step it is in. Read only.
    public struct SoftwareUpdateBlock: Hashable, Sendable {
        public enum Enforcement: Hashable, Sendable {
            /// A version by a deadline (manual). The deadline is the device’s
            /// local time, without a zone.
            case specific(targetOSVersion: String, targetLocalDateTime: String?, detailsURL: String?)
            /// The newest version, a number of days after its release, at a
            /// local time (`HH:MM`).
            case latest(enforceAfterDays: Int?, deploymentTime: String?)
            /// Minor updates a number of days after their release.
            case semantic(minorEnforceAfterDays: Int?, deploymentTime: String?)
            /// Something this version of JTKit doesn’t read (the enforcement
            /// type as received).
            case unknown(String?)
        }

        public enum Source: String, Hashable, Sendable {
            case component
            case customDeclaration
        }

        public var stepIndex: Int
        public var componentIndex: Int
        /// The step’s name, e.g. “Step 1”.
        public var stepName: String?
        /// The step’s declarative activation predicate, e.g.
        /// `@status(device.operating-system.family) == 'iPadOS'`; nil: always.
        public var activationPredicate: String?
        public var enforcement: Enforcement
        /// Only an Apple declaration can name a build.
        public var targetBuildVersion: String?
        public var source: Source

        public init(stepIndex: Int, componentIndex: Int, stepName: String? = nil, activationPredicate: String? = nil,
                    enforcement: Enforcement, targetBuildVersion: String? = nil, source: Source = .component) {
            self.stepIndex = stepIndex
            self.componentIndex = componentIndex
            self.stepName = stepName
            self.activationPredicate = activationPredicate
            self.enforcement = enforcement
            self.targetBuildVersion = targetBuildVersion
            self.source = source
        }

        /// The version a specific enforcement asks for.
        public var targetOSVersion: String? {
            if case .specific(let version, _, _) = enforcement { return version }
            return nil
        }

        /// The deadline of a specific enforcement, in the device’s local time.
        public var targetLocalDateTime: String? {
            if case .specific(_, let deadline, _) = enforcement { return deadline }
            return nil
        }

        /// The deadline as a date in `timeZone` (the device’s), seconds and
        /// fractions optional.
        public static func deadline(_ localDateTime: String, in timeZone: TimeZone) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            let trimmed = localDateTime.trimmingCharacters(in: .whitespaces)
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
                formatter.dateFormat = format
                let length = format.count - 2   // the two quotes
                if let date = formatter.date(from: String(trimmed.prefix(length))) { return date }
            }
            return nil
        }
    }
}

extension JamfPlatform.BlueprintDetail {
    /// Every software update enforcement, in step and component order.
    public var softwareUpdateBlocks: [JamfPlatform.SoftwareUpdateBlock] {
        let steps = steps?.arrayValue ?? []
        return components.flatMap { component -> [JamfPlatform.SoftwareUpdateBlock] in
            let step = component.stepIndex < steps.count ? steps[component.stepIndex] : .null
            let stepName = step["name"]?.text
            let predicate = step["activationPredicate"]?.text
            let configuration = component.json["configuration"] ?? .null
            switch component.identifier {
            case "com.jamf.ddm.sw-updates":
                return [JamfPlatform.SoftwareUpdateBlock(
                    stepIndex: component.stepIndex, componentIndex: component.index, stepName: stepName,
                    activationPredicate: predicate, enforcement: Self.enforcement(configuration))]
            case "com.jamf.ddm.custom-declarations":
                return (configuration["declarations"]?.arrayValue ?? []).compactMap { declaration in
                    guard declaration["type"]?.text == "com.apple.configuration.softwareupdate.enforcement.specific",
                          let payload = declaration["payload"], let version = payload["TargetOSVersion"]?.text else { return nil }
                    return JamfPlatform.SoftwareUpdateBlock(
                        stepIndex: component.stepIndex, componentIndex: component.index, stepName: stepName,
                        activationPredicate: predicate,
                        enforcement: .specific(targetOSVersion: version,
                                               targetLocalDateTime: payload["TargetLocalDateTime"]?.text,
                                               detailsURL: payload["DetailsURL"]?.text),
                        targetBuildVersion: payload["TargetBuildVersion"]?.text, source: .customDeclaration)
                }
            default:
                return []
            }
        }
    }

    static func enforcement(_ configuration: LosslessJSON) -> JamfPlatform.SoftwareUpdateBlock.Enforcement {
        let type = configuration["enforcementType"]?.text
        switch type?.uppercased() {
        case "MANUAL":
            guard let version = configuration["targetOSVersion"]?.text else { return .unknown(type) }
            let details = configuration["detailsURL"]
            let included = details?["Included"]?.bool ?? (details?["Value"]?.text != nil)
            return .specific(targetOSVersion: version, targetLocalDateTime: configuration["targetLocalDateTime"]?.text,
                             detailsURL: included ? details?["Value"]?.text : nil)
        case "AUTOMATIC":
            switch configuration["strategy"]?.text?.uppercased() {
            case "LATEST":
                return .latest(enforceAfterDays: configuration["enforceAfterDays"]?.int,
                               deploymentTime: configuration["deploymentTime"]?.text)
            case "SEMANTIC":
                let minor = configuration["rules"]?["minor"]
                return .semantic(minorEnforceAfterDays: minor?["enforceAfterDays"]?.int,
                                 deploymentTime: minor?["deploymentTime"]?.text)
            default:
                return .unknown(type)
            }
        default:
            // older Blueprints: only days and a time
            if configuration["enforceAfterDays"] != nil {
                return .latest(enforceAfterDays: configuration["enforceAfterDays"]?.int,
                               deploymentTime: configuration["deploymentTime"]?.text)
            }
            return .unknown(type)
        }
    }
}

extension JamfPlatform.Blueprints {
    /// A Blueprint and its software update enforcements, read with one GET
    /// (`blueprints:read`).
    public func softwareUpdate(blueprintID: String) async throws -> (blueprint: JamfPlatform.BlueprintDetail, blocks: [JamfPlatform.SoftwareUpdateBlock]) {
        let detail = try await detail(id: blueprintID)
        return (detail, detail.softwareUpdateBlocks)
    }
}

extension JamfPlatform {
    /// A Blueprint’s `com.jamf.ddm.software-update-settings` component: how
    /// devices are offered updates (deferrals, cadence, automatic actions,
    /// beta), as opposed to what is enforced. Only settings the Blueprint
    /// includes are set; nil means “not set here”. Read only.
    public struct SoftwareUpdateSettings: Hashable, Sendable {
        /// `Allowed`, `AlwaysOn` or `AlwaysOff`.
        public enum Action: Hashable, Sendable {
            case allowed, alwaysOn, alwaysOff
            case other(String)

            init(_ raw: String) {
                switch raw.lowercased() {
                case "allowed": self = .allowed
                case "alwayson": self = .alwaysOn
                case "alwaysoff": self = .alwaysOff
                default: self = .other(raw)
                }
            }
        }

        public var stepIndex: Int
        public var componentIndex: Int
        public var stepName: String?
        public var activationPredicate: String?
        /// Days an update is held back: all updates, majors, minors, system (Rapid Security Responses).
        public var combinedDeferralDays: Int?
        public var majorDeferralDays: Int?
        public var minorDeferralDays: Int?
        public var systemDeferralDays: Int?
        /// `All`, `Oldest` or `Newest`: which major a device is offered when several apply.
        public var recommendedCadence: String?
        public var automaticDownload: Action?
        public var automaticInstallOSUpdates: Action?
        public var automaticInstallSecurityUpdates: Action?
        public var allowStandardUserOSUpdates: Bool?
        public var notifications: Bool?
        public var rapidSecurityResponses: Bool?
        public var rapidSecurityResponseRollback: Bool?
        /// `Allowed`, `AlwaysOn` or `AlwaysOff`.
        public var betaProgramEnrollment: Action?

        public init(stepIndex: Int, componentIndex: Int, stepName: String? = nil, activationPredicate: String? = nil,
                    combinedDeferralDays: Int? = nil, majorDeferralDays: Int? = nil, minorDeferralDays: Int? = nil,
                    systemDeferralDays: Int? = nil, recommendedCadence: String? = nil, automaticDownload: Action? = nil,
                    automaticInstallOSUpdates: Action? = nil, automaticInstallSecurityUpdates: Action? = nil,
                    allowStandardUserOSUpdates: Bool? = nil, notifications: Bool? = nil, rapidSecurityResponses: Bool? = nil,
                    rapidSecurityResponseRollback: Bool? = nil, betaProgramEnrollment: Action? = nil) {
            self.stepIndex = stepIndex
            self.componentIndex = componentIndex
            self.stepName = stepName
            self.activationPredicate = activationPredicate
            self.combinedDeferralDays = combinedDeferralDays
            self.majorDeferralDays = majorDeferralDays
            self.minorDeferralDays = minorDeferralDays
            self.systemDeferralDays = systemDeferralDays
            self.recommendedCadence = recommendedCadence
            self.automaticDownload = automaticDownload
            self.automaticInstallOSUpdates = automaticInstallOSUpdates
            self.automaticInstallSecurityUpdates = automaticInstallSecurityUpdates
            self.allowStandardUserOSUpdates = allowStandardUserOSUpdates
            self.notifications = notifications
            self.rapidSecurityResponses = rapidSecurityResponses
            self.rapidSecurityResponseRollback = rapidSecurityResponseRollback
            self.betaProgramEnrollment = betaProgramEnrollment
        }

        init(component: JamfPlatform.BlueprintDetail.Component, step: LosslessJSON) {
            let c = component.json["configuration"] ?? .null
            /// A setting counts when the Blueprint includes it (`Included`, true when left out).
            func included(_ value: LosslessJSON?) -> LosslessJSON? {
                guard let value, value != .null else { return nil }
                return value["Included"]?.bool == false ? nil : value
            }
            func days(_ key: String) -> Int? { included(c["Deferrals"]?[key])?["Value"]?.int }
            func flag(_ value: LosslessJSON?, _ key: String = "Enabled") -> Bool? { included(value)?[key]?.bool }
            func action(_ key: String) -> Action? { included(c["AutomaticActions"]?[key])?["Value"]?.text.map(Action.init) }
            self.init(stepIndex: component.stepIndex, componentIndex: component.index, stepName: step["name"]?.text,
                      activationPredicate: step["activationPredicate"]?.text,
                      combinedDeferralDays: days("CombinedPeriodInDays"), majorDeferralDays: days("MajorPeriodInDays"),
                      minorDeferralDays: days("MinorPeriodInDays"), systemDeferralDays: days("SystemPeriodInDays"),
                      recommendedCadence: included(c["RecommendedCadence"])?["Value"]?.text,
                      automaticDownload: action("Download"), automaticInstallOSUpdates: action("InstallOSUpdates"),
                      automaticInstallSecurityUpdates: action("InstallSecurityUpdate"),
                      allowStandardUserOSUpdates: flag(c["AllowStandardUserOSUpdates"]),
                      notifications: flag(c["Notifications"]),
                      rapidSecurityResponses: flag(c["RapidSecurityResponse"]?["Enable"]),
                      rapidSecurityResponseRollback: flag(c["RapidSecurityResponse"]?["EnableRollback"]),
                      betaProgramEnrollment: included(c["Beta"])?["Value"]?["ProgramEnrollment"]?.text.map(Action.init))
        }
    }
}

extension JamfPlatform.BlueprintDetail {
    /// Every software update settings component, in step order.
    public var softwareUpdateSettings: [JamfPlatform.SoftwareUpdateSettings] {
        let steps = steps?.arrayValue ?? []
        return components.filter { $0.identifier == "com.jamf.ddm.software-update-settings" }.map { component in
            JamfPlatform.SoftwareUpdateSettings(component: component,
                                                step: component.stepIndex < steps.count ? steps[component.stepIndex] : .null)
        }
    }
}
