import Foundation

/// A Blueprint’s scope as Jamf Pro groups and their members, each device
/// once: what the software update reader and the content cache sweep both
/// read (`pro/v2/groups` for the Platform IDs, then Jamf Pro’s groups of
/// the kinds the scope holds, then their members). GET only.
nonisolated struct ScopeReader: Sendable {
    let jamfPro: JamfPlatform.Client

    struct Scope: Sendable {
        /// The scope’s Jamf Pro groups, by name.
        var groups: [JamfPro.DeviceGroup] = []
        /// Scope groups that aren’t a Jamf Pro group of the kinds read.
        var unmatched = 0
        /// Each device once, in the order read.
        var members: [JamfPro.GroupMember] = []
    }

    /// The kinds of Jamf Pro groups the scope holds, mobile device groups first.
    static func groupKinds(platformGroupIDs: [String], platformGroups: [JamfPlatform.PlatformGroup]) -> [MDMCommand.DeviceKind] {
        let wanted = Set(platformGroupIDs.map { $0.lowercased() })
        let types = Set(platformGroups.filter { wanted.contains($0.id.lowercased()) }.map(\.deviceType))
        var kinds: [MDMCommand.DeviceKind] = []
        if types.contains(.mobile) { kinds.append(.mobileDevice) }
        if types.contains(.computer) { kinds.append(.computer) }
        return kinds
    }

    /// The scope as Jamf Pro groups (by kind and number), from its Platform API group IDs.
    static func scope(platformGroupIDs: [String], platformGroups: [JamfPlatform.PlatformGroup]) -> Set<JamfPro.DeviceGroup.ID> {
        let wanted = Set(platformGroupIDs.map { $0.lowercased() })
        return Set(platformGroups.filter { wanted.contains($0.id.lowercased()) }.compactMap(JamfPro.DeviceGroup.ID.init))
    }

    /// A device’s key in a scope: its kind and Jamf Pro ID.
    static func key(_ member: JamfPro.GroupMember) -> String { "\(member.kind.rawValue)/\(member.id)" }

    /// The scope’s groups without their members.
    /// - Parameter kinds: only these kinds (the content cache sweep reads computers only); nil: every kind the scope holds.
    func groups(platformGroupIDs: [String], platformGroups: [JamfPlatform.PlatformGroup],
                kinds only: Set<MDMCommand.DeviceKind>? = nil) async throws -> Scope {
        let kinds = Self.groupKinds(platformGroupIDs: platformGroupIDs, platformGroups: platformGroups)
            .filter { only?.contains($0) ?? true }
        let groups = kinds.isEmpty ? [] : try await jamfPro.jamfProGroups(kinds)
        let keys = Self.scope(platformGroupIDs: platformGroupIDs, platformGroups: platformGroups)
        let scope = keys.compactMap { key in groups.first { $0.id == key } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Scope(groups: scope, unmatched: platformGroupIDs.count - scope.count)
    }

    /// The members of `scope`’s groups, each device once, also when it is in several.
    func members(of scope: Scope, progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws -> Scope {
        var filled = scope
        var seen = Set<String>()
        for (number, group) in scope.groups.enumerated() {
            progress(number, scope.groups.count)
            for member in try await jamfPro.members(of: group) where seen.insert(Self.key(member)).inserted {
                filled.members.append(member)
            }
        }
        return filled
    }
}
