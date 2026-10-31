import Foundation

/// One shared set of sample devices for demo mode, so a device is the same in
/// Apple Business or Apple School Manager, Jamf Pro, Jamf School and Intune (and
/// Checkpoint can compare them). Every demo server reads its records from here.
///
/// Contoso (Apple Business) has 31 devices: Macs, iPads and one
/// iPhone sent to "Contoso Jamf Pro", the other iPhones sent to "Contoso
/// Intune". Contoso Academy (Apple School Manager) has 10, sent to "Contoso
/// Academy Jamf School". One more Mac is in Jamf Pro only. The gaps a real fleet has are there on
/// purpose, each once unless noted: iPhones missing from Intune (three), a
/// Mac whose AppleCare has expired, a new iPad not assigned to any server, a
/// Mac Apple has released that Jamf Pro still manages (release pending), a Mac
/// Jamf Pro hasn’t heard from in months (stale), and that Mac outside Apple.
public nonisolated enum DemoWorld {
    public enum Family: String, Sendable, Hashable, CaseIterable {
        case mac = "Mac"
        case iPhone
        case iPad
    }

    public enum Organization: String, Sendable, Hashable, CaseIterable {
        /// Contoso, in Apple Business.
        case contoso
        /// Contoso Academy, in Apple School Manager.
        case academy

        public var name: String {
            switch self {
            case .contoso: DemoSamples.organization
            case .academy: DemoSamples.schoolOrganization
            }
        }
    }

    public enum MDM: String, Sendable, Hashable, CaseIterable {
        case jamfPro
        case jamfSchool
        case intune
    }

    public struct Device: Sendable, Hashable, Identifiable {
        /// 1…42, unique; also the device’s ID in Jamf Pro.
        public let number: Int
        public let serial: String
        public let family: Family
        public let model: String
        public let modelIdentifier: String
        public let name: String
        /// The person using it: an invented first name and "Sample".
        public let user: String
        public let osVersion: String
        /// The Apple organization it’s in; nil for a device bought elsewhere.
        public let organization: Organization?
        /// The MDM server Apple assigns it to; nil when unassigned.
        public let appleServerID: String?
        /// The MDM that holds its record; nil when none does.
        public let managedBy: MDM?
        /// Days since the MDM last heard from it.
        public let lastContactDaysAgo: Int
        /// Days until AppleCare ends; negative when it has ended.
        public let appleCareDaysLeft: Int
        /// Apple has released it from the organization (days ago).
        public let releasedDaysAgo: Int?
        public let orderNumber: String?
        public let assetTag: String

        public var id: Int { number }
        public var udid: String { DemoSamples.uuid(0x5000 + number).uppercased() }
        public var managementID: String { DemoSamples.uuid(0x7000 + number) }
        public var intuneID: String { DemoSamples.uuid(0x1000 + number) }
        public var username: String { user.lowercased().replacingOccurrences(of: " ", with: ".") }
        public var email: String { "\(username)@contoso.example" }
        public var isComputer: Bool { family == .mac }
    }

    // MARK: Apple’s MDM servers

    public static let jamfProServerID = DemoSamples.uuid(0xa501)
    static let intuneServerID = DemoSamples.uuid(0xa502)
    static let jamfSchoolServerID = DemoSamples.uuid(0xa511)

    /// The MDM servers of an organization: (ID, name).
    public static func mdmServers(in organization: Organization) -> [(id: String, name: String)] {
        switch organization {
        case .contoso: [(jamfProServerID, "Contoso Jamf Pro"), (intuneServerID, "Contoso Intune")]
        case .academy: [(jamfSchoolServerID, "Contoso Academy Jamf School")]
        }
    }

    // MARK: Hosts

    public static let jamfProHost = "contoso-jamf.\(DemoNetwork.reservedDomain)"
    static let jamfSchoolHost = "contoso-academy.\(DemoNetwork.reservedDomain)"
    /// The Entra tenant of "Contoso Intune".
    static let intuneTenantID = DemoSamples.uuid(0xe701)

    // MARK: Devices

    public static let devices: [Device] = makeDevices()

    public static func device(serial: String) -> Device? {
        let serial = serial.uppercased()
        return devices.first { $0.serial == serial }
    }

    public static func devices(in organization: Organization) -> [Device] {
        devices.filter { $0.organization == organization }
    }

    public static func devices(managedBy mdm: MDM) -> [Device] {
        devices.filter { $0.managedBy == mdm }
    }

    // MARK: The gaps

    /// Sent to Intune by Apple, but Intune has no record of them.
    public static var missingFromIntune: [Device] {
        devices.filter { $0.appleServerID == intuneServerID && $0.managedBy != .intune }
    }
    public static var appleCareExpired: [Device] { devices.filter { $0.organization != nil && $0.appleCareDaysLeft < 0 } }
    /// In an Apple organization, not released, assigned to no server.
    public static var unassigned: [Device] {
        devices.filter { $0.organization != nil && $0.releasedDaysAgo == nil && $0.appleServerID == nil }
    }
    /// Released by Apple, still managed by an MDM.
    public static var releasePending: [Device] { devices.filter { $0.releasedDaysAgo != nil && $0.managedBy != nil } }
    /// Not heard from in over 90 days.
    public static var stale: [Device] { devices.filter { $0.managedBy != nil && $0.lastContactDaysAgo > 90 } }
    /// Managed, but in no Apple organization.
    public static var notInApple: [Device] { devices.filter { $0.organization == nil } }

    /// Days since the MDM last heard from a device counted as stale.
    static let staleDays = 131

    // MARK: Building the set

    private static let firstNames = [
        "Ava", "Noah", "Mila", "Liam", "Zoe", "Elias", "Nora", "Lucas", "Iris", "Owen",
        "Ruby", "Felix", "Lena", "Hugo", "Maya", "Jonas", "Clara", "Milo", "Ines", "Theo",
        "Esme", "Arlo", "Lotte", "Finn", "Julia", "Sami", "Wren", "Otis", "Hanna", "Jude",
        "Saar", "Bram", "Fien", "Lars", "Tess", "Emil", "Lina", "Rafa", "Vera", "Kai", "Nina",
    ]

    private struct ModelInfo {
        let name: String
        let identifier: String
        let short: String
    }

    private static let macs = [
        ModelInfo(name: "MacBook Air (13-inch, M3, 2024)", identifier: "Mac15,12", short: "MacBook Air"),
        ModelInfo(name: "MacBook Pro (14-inch, M4, 2024)", identifier: "Mac16,1", short: "MacBook Pro"),
        ModelInfo(name: "iMac (24-inch, 2024)", identifier: "Mac16,3", short: "iMac"),
        ModelInfo(name: "Mac mini (2024)", identifier: "Mac16,10", short: "Mac mini"),
    ]
    private static let iPhones = [
        ModelInfo(name: "iPhone 16", identifier: "iPhone17,3", short: "iPhone"),
        ModelInfo(name: "iPhone 15", identifier: "iPhone15,4", short: "iPhone"),
    ]
    private static let iPads = [
        ModelInfo(name: "iPad (10th generation)", identifier: "iPad13,18", short: "iPad"),
        ModelInfo(name: "iPad Air 11-inch (M2)", identifier: "iPad14,8", short: "iPad Air"),
    ]

    /// Serials: `ZZDEMO`, a family letter, two digits and two letters, e.g. `ZZDEMOM04KQ`.
    static func serial(_ number: Int, _ family: Family) -> String {
        let letters = Array("KQRMXTVWHJ")
        let letter = switch family { case .mac: "M"; case .iPhone: "P"; case .iPad: "D" }
        return "ZZDEMO\(letter)\(String(format: "%02d", number))\(letters[number % 10])\(letters[(number * 7) % 10])"
    }

    private static func makeDevices() -> [Device] {
        var result: [Device] = []
        func add(_ family: Family, organization: Organization?, server: String?, mdm: MDM?,
                 lastContact: Int = 0, appleCare: Int = 400, released: Int? = nil, order: String?) {
            let number = result.count + 1
            let models = switch family { case .mac: macs; case .iPhone: iPhones; case .iPad: iPads }
            let model = models[number % models.count]
            let first = firstNames[(number - 1) % firstNames.count]
            let os = switch family {
            case .mac: number % 3 == 0 ? "26.6" : "27.0.1"
            case .iPhone, .iPad: number % 4 == 0 ? "26.6.1" : "27.0.1"
            }
            result.append(Device(
                number: number, serial: serial(number, family), family: family, model: model.name,
                modelIdentifier: model.identifier, name: "\(first)’s \(model.short)", user: "\(first) Sample",
                osVersion: os, organization: organization, appleServerID: server, managedBy: mdm,
                lastContactDaysAgo: lastContact == 0 ? number % 3 : lastContact,
                appleCareDaysLeft: appleCare + number * 9, releasedDaysAgo: released, orderNumber: order,
                assetTag: String(format: "CT-%04d", 1000 + number)))
        }
        // Contoso: 14 Macs (1–14) on Jamf Pro.
        for index in 1...14 {
            switch index {
            case 4: add(.mac, organization: .contoso, server: jamfProServerID, mdm: .jamfPro,
                        appleCare: -76, order: "DEMO-1001")    // AppleCare expired
            case 12: add(.mac, organization: .contoso, server: jamfProServerID, mdm: .jamfPro,
                         lastContact: staleDays, order: "DEMO-1002")    // stale
            case 13: add(.mac, organization: .contoso, server: nil, mdm: .jamfPro,
                         released: 2, order: "DEMO-1002")    // release pending
            default: add(.mac, organization: .contoso, server: jamfProServerID, mdm: .jamfPro,
                         order: index <= 7 ? "DEMO-1001" : "DEMO-1002")
            }
        }
        // Contoso: 8 iPads (15–22) on Jamf Pro; the last is new and unassigned.
        for index in 1...8 {
            if index == 8 {
                add(.iPad, organization: .contoso, server: nil, mdm: nil, order: "DEMO-1003")
            } else {
                add(.iPad, organization: .contoso, server: jamfProServerID, mdm: .jamfPro, order: "DEMO-1003")
            }
        }
        // Contoso: 8 iPhones (23–30) on Intune; the last three never enrolled.
        for index in 1...8 {
            add(.iPhone, organization: .contoso, server: intuneServerID, mdm: index <= 5 ? .intune : nil, order: "DEMO-1004")
        }
        // Contoso Academy: 8 iPads (31–38) and 2 Macs (39–40) on Jamf School.
        for _ in 1...8 {
            add(.iPad, organization: .academy, server: jamfSchoolServerID, mdm: .jamfSchool, order: "DEMO-2001")
        }
        for _ in 1...2 {
            add(.mac, organization: .academy, server: jamfSchoolServerID, mdm: .jamfSchool, order: "DEMO-2001")
        }
        // A Mac bought outside Apple Business, enrolled in Jamf Pro by hand.
        add(.mac, organization: nil, server: nil, mdm: .jamfPro, order: nil)
        // Contoso: an iPhone on Jamf Pro (42), added later so 1–41 stay as they were.
        add(.iPhone, organization: .contoso, server: jamfProServerID, mdm: .jamfPro, order: "DEMO-1004")
        return result
    }

    // MARK: Dates

    /// `days` before (or, negative, after) `now`, ISO 8601 in UTC.
    static func iso(daysAgo days: Double, from now: Date, fractional: Bool = false) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.string(from: now.addingTimeInterval(-days * 86_400))
    }
}

extension Connection {
    /// Demo mode’s Apple Business organization. Never saved.
    public static let demoAppleBusiness = Connection(
        id: UUID(uuidString: DemoSamples.uuid(0xde11)) ?? UUID(),
        name: "\(DemoSamples.organization) (Demo)", service: .appleBusinessManager,
        clientID: "BUSINESSAPI.\(DemoSamples.uuid(0xc011))", keyID: DemoSamples.uuid(0xc012))

    /// Demo mode’s Apple School Manager organization. Never saved.
    public static let demoAppleSchool = Connection(
        id: UUID(uuidString: DemoSamples.uuid(0xde12)) ?? UUID(),
        name: "\(DemoSamples.schoolOrganization) (Demo)", service: .appleSchoolManager,
        clientID: "SCHOOLAPI.\(DemoSamples.uuid(0xc021))", keyID: DemoSamples.uuid(0xc022))

    /// Demo mode’s Jamf Pro, signed in with an API client. Never saved.
    public static let demoJamfPro = Connection(
        id: UUID(uuidString: DemoSamples.uuid(0xde21)) ?? UUID(),
        name: "\(DemoSamples.organization) Jamf Pro (Demo)", service: .jamfPro, signIn: .apiClient,
        serverURL: "https://\(DemoWorld.jamfProHost)", clientID: DemoSamples.uuid(0xc031))

    /// Demo mode’s Jamf School. Never saved.
    public static let demoJamfSchool = Connection(
        id: UUID(uuidString: DemoSamples.uuid(0xde22)) ?? UUID(),
        name: "\(DemoSamples.schoolOrganization) (Demo)", service: .jamfSchool,
        serverURL: "https://\(DemoWorld.jamfSchoolHost)", clientID: "8000123")

    /// Demo mode’s Intune tenant, signed in with an app registration. Never saved.
    public static let demoIntune = Connection(
        id: UUID(uuidString: DemoSamples.uuid(0xde23)) ?? UUID(),
        name: "\(DemoSamples.organization) Intune (Demo)", service: .intune, signIn: .entraClientSecret,
        clientID: DemoSamples.uuid(0xc041), tenantID: DemoWorld.intuneTenantID)

    /// Demo mode’s Jamf Pro to copy from (JamfMigrator’s Source): Contoso’s
    /// golden master, objects only (`DemoJamfProObjects.contosoSource()`). Never saved.
    public static let demoJamfProSource = Connection(
        id: UUID(uuidString: DemoSamples.uuid(0xde24)) ?? UUID(),
        name: "\(DemoSamples.organization) Source (Demo)", service: .jamfPro, signIn: .apiClient,
        serverURL: "https://\(DemoJamfProObjectSamples.sourceHost)", clientID: DemoSamples.uuid(0xc032))

    /// Demo mode’s Jamf Pro to copy to (JamfMigrator’s Destination): a fresh
    /// Contoso tenant (`DemoJamfProObjects.contosoDestination()`). Never saved.
    public static let demoJamfProDestination = Connection(
        id: UUID(uuidString: DemoSamples.uuid(0xde25)) ?? UUID(),
        name: "\(DemoSamples.organization) Destination (Demo)", service: .jamfPro, signIn: .apiClient,
        serverURL: "https://\(DemoJamfProObjectSamples.destinationHost)", clientID: DemoSamples.uuid(0xc033))

    /// Every demo connection of Apple Business and Apple School Manager and the MDMs.
    static let demoConnections: [Connection] = [
        .demoAppleBusiness, .demoAppleSchool, .demoJamfPro, .demoJamfSchool, .demoIntune, .demoJamfPlatform,
        .demoJamfProSource, .demoJamfProDestination,
    ]
}
