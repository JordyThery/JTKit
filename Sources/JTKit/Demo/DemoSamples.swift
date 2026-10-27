import Foundation

/// Demo mode's sample data: believable, and clearly fake. The organisation is
/// "Contoso" ("Contoso Academy" for schools), hosts end in `.demo.invalid`,
/// e-mail and web addresses in `.contoso.example`, serials start with
/// `ZZDEMO`, people have the surname "Sample", and every ID is a UUID in the
/// reserved fake range (`00000000-0000-4000-8000-…`). A test checks all of it.
public nonisolated enum DemoSamples {
    public static let organization = "Contoso"
    public static let schoolOrganization = "Contoso Academy"

    /// The reserved fake UUID range: no real (random) UUID starts like this.
    public static let uuidPrefix = "00000000-0000-4000-8000-"

    /// A UUID in the reserved fake range, e.g. `uuid(0xde01)`.
    public static func uuid(_ number: Int) -> String {
        uuidPrefix + String(format: "%012llx", UInt64(number))
    }

    /// Whether `id` is in the reserved fake range.
    public static func isDemoID(_ id: String) -> Bool {
        id.lowercased().hasPrefix(uuidPrefix)
    }

    // MARK: Jamf Platform

    /// The demo Jamf Platform environment.
    public static let platformEnvironmentID = uuid(0xde70)
    public static let platformHost = "contoso-platform.\(DemoNetwork.reservedDomain)"

    /// Device groups of the Contoso environment.
    public static let platformGroups: [JamfPlatform.DeviceGroup] = [
        JamfPlatform.DeviceGroup(id: uuid(0xd601), name: "All Managed Macs", description: "Every managed Mac",
                                 deviceType: .computer, groupType: .smart, memberCount: 48),
        JamfPlatform.DeviceGroup(id: uuid(0xd602), name: "Design Macs", description: "",
                                 deviceType: .computer, groupType: .smart, memberCount: 7),
        JamfPlatform.DeviceGroup(id: uuid(0xd603), name: "Engineering Macs", description: "",
                                 deviceType: .computer, groupType: .static, memberCount: 12),
        JamfPlatform.DeviceGroup(id: uuid(0xd604), name: "Field iPhones", description: "",
                                 deviceType: .mobile, groupType: .smart, memberCount: 9),
        JamfPlatform.DeviceGroup(id: uuid(0xd605), name: "Front Desk Shared iPads", description: "",
                                 deviceType: .mobile, groupType: .static, memberCount: 4),
        JamfPlatform.DeviceGroup(id: uuid(0xd606), name: "Sales iPads", description: "",
                                 deviceType: .mobile, groupType: .smart, memberCount: 24),
    ]

    /// Device group IDs of the Jamf School scenario: numeric strings, as Jamf School has them.
    public static let schoolGroupIDs = ["101", "102"]

    /// Blueprints of the Contoso environment, oldest first, as full detail JSON.
    /// They cover what apps meet on a real tenant: deployed and never deployed,
    /// with and without App Settings, created in Jamf without a scope, and
    /// assigned to a division (read-only through the API).
    public static func platformBlueprints(jamfSchool: Bool = false) -> [LosslessJSON.Object] {
        let allMacs = jamfSchool ? schoolGroupIDs[0] : uuid(0xd601)
        let engineering = jamfSchool ? schoolGroupIDs[0] : uuid(0xd603)
        let salesIPads = jamfSchool ? schoolGroupIDs[1] : uuid(0xd606)
        return [
            blueprint(0xb001, "Contoso – Software Updates", description: "Updates within 7 days of release",
                      groups: [allMacs], created: "2026-08-03T09:14:22.381Z", updated: "2026-09-01T07:02:10.114Z",
                      state: "DEPLOYED", lastDeployment: "2026-09-01T07:02:11.020Z",
                      components: [component("com.jamf.ddm.sw-updates", ["enforceAfterDays": .number(.init(7))])]),
            blueprint(0xb002, "Contoso – App Settings for Macs", description: "Approved apps on company Macs",
                      groups: [allMacs], created: "2026-08-19T13:40:05.902Z", updated: "2026-09-22T10:31:44.617Z",
                      state: "DEPLOYED", lastDeployment: "2026-09-22T10:31:45.208Z",
                      components: [strict([macAppSettings])]),
            blueprint(0xb003, "Contoso – iPad App Settings", description: "Sales iPads",
                      groups: [salesIPads], created: "2026-09-02T08:05:51.330Z", updated: "2026-09-02T08:05:51.330Z",
                      state: "DEPLOYED", lastDeployment: "2026-09-02T08:06:03.775Z",
                      components: [
                        component("com.jamf.ddm.passcode-settings", ["minimumLength": .number(.init(6)), "requireAlphanumeric": .bool(false)]),
                        strict([iPadAppSettings]),
                      ]),
            blueprint(0xb004, "Contoso – New Hire Macs", description: "Draft, not deployed yet",
                      groups: [engineering], created: "2026-10-06T15:27:09.441Z", updated: "2026-10-06T15:27:09.441Z",
                      state: "NOT_DEPLOYED", lastDeployment: nil,
                      components: [component("com.jamf.ddm-configuration-profile", [
                        "payloadDisplayName": .string("Contoso Dock"),
                        "payloadContent": .array([.object(LosslessJSON.Object([
                            "payloadType": .string("com.apple.dock"),
                            "payloadIdentifier": .string("com.contoso.example.dock"),
                            "payloadUUID": .string("com.contoso.example.dock"),
                            "orientation": .string("bottom"),
                        ]))]),
                      ])]),
            blueprint(0xb005, "Contoso – Made in Jamf, No Scope", description: nil,
                      groups: nil, created: "2026-10-12T11:48:30.006Z", updated: nil,
                      state: "NOT_DEPLOYED", lastDeployment: nil,
                      components: [component("com.jamf.ddm.sw-updates", ["enforceAfterDays": .number(.init(14))])]),
            blueprint(0xb006, "Contoso – Finance Division Macs", description: "Managed by the Finance division",
                      groups: [allMacs], created: "2026-07-21T09:00:12.500Z", updated: "2026-07-21T09:00:12.500Z",
                      state: "DEPLOYED", lastDeployment: "2026-07-21T09:00:13.115Z",
                      components: [strict([macAppSettings])], division: uuid(0xd1f1)),
        ]
    }

    // MARK: Building blocks

    private static let macAppSettings = LosslessJSON.object(LosslessJSON.Object([
        "kind": .string("CONFIGURATION"),
        "type": .string("com.apple.configuration.app.settings"),
        "payload": .object(LosslessJSON.Object([
            "Allowed": .object(LosslessJSON.Object([
                "AllowedBinaries": .array([
                    .object(LosslessJSON.Object(["TeamID": .string("*APPLE*"), "SigningState": .string("Apple")])),
                    .object(LosslessJSON.Object(["TeamID": .string("ZZDEMOTM01")])),
                    .object(LosslessJSON.Object(["TeamID": .string("ZZDEMOTM02"), "SigningID": .string("com.contoso.example.notes")])),
                ]),
                "AlwaysAllowManagedApps": .bool(true),
            ])),
        ])),
        "channelType": .string("SYSTEM"),
    ]))

    private static let iPadAppSettings = LosslessJSON.object(LosslessJSON.Object([
        "kind": .string("CONFIGURATION"),
        "type": .string("com.apple.configuration.app.settings"),
        "payload": .object(LosslessJSON.Object([
            "Allowed": .object(LosslessJSON.Object([
                "DeniedApps": .array([.string("com.contoso.example.games"), .string("com.contoso.example.social")]),
            ])),
        ])),
        "channelType": .string("SYSTEM"),
    ]))

    private static func strict(_ declarations: [LosslessJSON]) -> LosslessJSON {
        component("com.jamf.ddm-strict", ["declarations": .array(declarations)])
    }

    private static func component(_ identifier: String, _ configuration: KeyValuePairs<String, LosslessJSON>) -> LosslessJSON {
        .object(LosslessJSON.Object(["identifier": .string(identifier), "configuration": .object(LosslessJSON.Object(configuration))]))
    }

    private static func blueprint(
        _ number: Int, _ name: String, description: String?, groups: [String]?, created: String, updated: String?,
        state: String, lastDeployment: String?, components: [LosslessJSON], division: String? = nil
    ) -> LosslessJSON.Object {
        var deployment = LosslessJSON.Object(["state": .string(state)])
        if let lastDeployment {
            deployment["lastDeployment"] = .object(LosslessJSON.Object(["started": .string(lastDeployment), "state": .string("SUCCEEDED")]))
        }
        var object = LosslessJSON.Object([
            "id": .string(uuid(number)),
            "name": .string(name),
            "description": description.map(LosslessJSON.string) ?? .null,
            "scope": groups.map { .object(LosslessJSON.Object(["deviceGroups": .array($0.map(LosslessJSON.string))])) } ?? .null,
            "created": .string(created),
            "updated": updated.map(LosslessJSON.string) ?? .null,
            "deploymentState": .object(deployment),
            "steps": .array([.object(LosslessJSON.Object([
                "name": .string("Step 1"),
                "components": .array(components),
                "activationPredicate": .null,
            ]))]),
        ])
        if let division { object["divisionId"] = .string(division) }
        return object
    }
}
