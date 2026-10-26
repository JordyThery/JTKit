import Foundation

/// Jamf Pro's own API (`/api/…`): device lookups, asset tags, the version and
/// the privileges each call needs.
///
/// The calls run on `JamfPlatform.Client`, which reaches Jamf Pro directly
/// (`server: .jamfPro`) and through the Platform API gateway alike; paths are
/// written in gateway form (`pro/v4/…`) and mapped onto `api/v4/…` for a
/// direct server.
public nonisolated enum JamfPro {
    /// A serial number or UDID, checked before it goes into a filter.
    ///
    /// Serials and UDIDs are letters, digits and hyphens. They can come from
    /// device-controlled data (a USB descriptor) or a pasted list, so anything
    /// else is refused rather than put into an RSQL filter.
    public static func validatedIdentifier(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" })
        else { throw JamfPlatformError(.invalidIdentifier(String(trimmed.prefix(64)))) }
        return trimmed
    }

    /// The Jamf Pro version, e.g. "11.33.1-t1792501724838".
    public struct Version: Decodable, Hashable, Sendable {
        public var version: String

        public init(version: String) {
            self.version = version
        }
    }
}

extension JamfPro {
    /// A Jamf Pro privilege, named as Jamf Pro shows it under Settings › API
    /// Roles and Clients (and in a user account's privileges).
    ///
    /// The one table every app uses: each call carries its privilege, so a
    /// refused request (403) names the one that is missing.
    public struct Privilege: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            rawValue = value
        }

        public var description: String { rawValue }

        // Devices
        public static let readComputers: Privilege = "Read Computers"
        public static let updateComputers: Privilege = "Update Computers"
        public static let deleteComputers: Privilege = "Delete Computers"
        public static let readMobileDevices: Privilege = "Read Mobile Devices"
        public static let updateMobileDevices: Privilege = "Update Mobile Devices"
        public static let deleteMobileDevices: Privilege = "Delete Mobile Devices"
        public static let readComputerCheckIn: Privilege = "Read Computer Check-In"

        // Organization
        public static let readSites: Privilege = "Read Sites"
        public static let readDepartments: Privilege = "Read Departments"
        public static let readBuildings: Privilege = "Read Buildings"
        public static let readCategories: Privilege = "Read Categories"

        // Groups
        public static let readSmartComputerGroups: Privilege = "Read Smart Computer Groups"
        public static let readStaticComputerGroups: Privilege = "Read Static Computer Groups"
        public static let readSmartMobileDeviceGroups: Privilege = "Read Smart Mobile Device Groups"
        public static let readStaticMobileDeviceGroups: Privilege = "Read Static Mobile Device Groups"

        // Enrollment
        public static let readDeviceEnrollmentProgramInstances: Privilege = "Read Device Enrollment Program Instances"
        public static let updateComputerPreStageEnrollments: Privilege = "Update Computer PreStage Enrollments"
        public static let updateMobileDevicePreStageEnrollments: Privilege = "Update Mobile Device PreStage Enrollments"
        public static let readComputerPreStageEnrollments: Privilege = "Read Computer PreStage Enrollments"
        public static let readMobileDevicePreStageEnrollments: Privilege = "Read Mobile Device PreStage Enrollments"
        public static let readUserInitiatedEnrollment: Privilege = "Read User-Initiated Enrollment"

        // Compliance
        public static let readDeviceComplianceInformation: Privilege = "Read Device Compliance Information"
        public static let readConditionalAccess: Privilege = "Read Conditional Access"

        // Secrets
        public static let viewDiskEncryptionRecoveryKey: Privilege = "View Disk Encryption Recovery Key"
        public static let viewRecoveryLock: Privilege = "View Recovery Lock"
        public static let viewComputerDeviceLockPin: Privilege = "View Computer Device Lock Pin"
        public static let viewLocalAdminPassword: Privilege = "View Local Admin Password"
        public static let updateLocalAdminPassword: Privilege = "Update Local Admin Password"

        // Commands
        @available(*, deprecated, message: "Not a Jamf Pro privilege: v2/mdm/blank-push needs viewMDMCommandInformation.")
        public static let sendBlankPush: Privilege = "Send Blank Push"
        public static let sendComputerRemoteCommand: Privilege = "Send Computer Remote Command"
        public static let sendComputerRemoteLockCommand: Privilege = "Send Computer Remote Lock Command"
        public static let sendComputerRemoteWipeCommand: Privilege = "Send Computer Remote Wipe Command"
        public static let sendComputerUnmanageCommand: Privilege = "Send Computer Unmanage Command"
        public static let sendDeclarativeManagementCommand: Privilege = "Send Declarative Management Command"
        public static let sendMobileDeviceRemoteLockCommand: Privilege = "Send Mobile Device Remote Lock Command"
        public static let sendMobileDeviceRemoteWipeCommand: Privilege = "Send Mobile Device Remote Wipe Command"
        public static let sendMobileDeviceRemovePasscodeCommand: Privilege = "Send Mobile Device Remove Passcode Command"
        public static let sendMobileDeviceRestartDeviceCommand: Privilege = "Send Mobile Device Restart Device Command"
        public static let sendMobileDeviceShutDownCommand: Privilege = "Send Mobile Device Shut Down Command"
        public static let updateInventoryForMobileDevices: Privilege = "Update Inventory for Mobile Devices"
        public static let viewMDMCommandInformation: Privilege = "View MDM command information in Jamf Pro API"
        public static let unmanageMobileDevices: Privilege = "Unmanage Mobile Devices"
        public static let sendRenewMDMProfileCommand: Privilege = "Send Command to Renew MDM Profile"
        public static let sendComputerInstallPackageCommand: Privilege = "Send Computer Remote Command to Install Package"

        // Other objects
        public static let createPolicies: Privilege = "Create Policies"
        public static let readDistributionPoints: Privilege = "Read Distribution Points"
        public static let readSelfService: Privilege = "Read Self Service"
        public static let readPatchInternalSource: Privilege = "Read Patch Internal Source"
        public static let viewLicenseSerial: Privilege = "View License Serial"
    }
}

extension JamfPlatform.Client {
    /// The Jamf Pro version (`v1/jamf-pro-version`). Needs no privilege.
    public func jamfProVersion() async throws -> JamfPro.Version {
        try await get(JamfPro.Version.self, "pro/v1/jamf-pro-version")
    }
}
