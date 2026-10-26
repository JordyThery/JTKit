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

        // Commands
        @available(*, deprecated, message: "Not a Jamf Pro privilege: v2/mdm/blank-push needs viewMDMCommandInformation.")
        public static let sendBlankPush: Privilege = "Send Blank Push"
        public static let sendComputerRemoteLockCommand: Privilege = "Send Computer Remote Lock Command"
        public static let sendComputerRemoteWipeCommand: Privilege = "Send Computer Remote Wipe Command"
        public static let sendComputerUnmanageCommand: Privilege = "Send Computer Unmanage Command"
        public static let sendDeclarativeManagementCommand: Privilege = "Send Declarative Management Command"
        public static let sendMobileDeviceRemoteLockCommand: Privilege = "Send Mobile Device Remote Lock Command"
        public static let sendMobileDeviceRemoteWipeCommand: Privilege = "Send Mobile Device Remote Wipe Command"
        public static let sendMobileDeviceRemovePasscodeCommand: Privilege = "Send Mobile Device Remove Passcode Command"
        public static let sendMobileDeviceRestartDeviceCommand: Privilege = "Send Mobile Device Restart Device Command"
        public static let sendMobileDeviceShutDownCommand: Privilege = "Send Mobile Device Shut Down Command"
        public static let sendInventoryRequestsToMobileDevices: Privilege = "Send Inventory Requests to Mobile Devices"
        @available(*, deprecated, renamed: "sendInventoryRequestsToMobileDevices", message: "Jamf Pro names it Send Inventory Requests to Mobile Devices.")
        public static let updateInventoryForMobileDevices: Privilege = "Send Inventory Requests to Mobile Devices"
        public static let viewMDMCommandInformation: Privilege = "View MDM command information in Jamf Pro API"
        public static let unmanageMobileDevices: Privilege = "Unmanage Mobile Devices"
        public static let sendRenewMDMProfileCommand: Privilege = "Send Command to Renew MDM Profile"
        public static let sendComputerInstallPackageCommand: Privilege = "Send Computer Remote Command to Install Package"

        // Other objects
        public static let createPolicies: Privilege = "Create Policies"
        public static let readDistributionPoints: Privilege = "Read Distribution Points"
        public static let readSelfService: Privilege = "Read Self Service"
        public static let readPatchInternalSource: Privilege = "Read Patch Internal Source"
        public static let readPatchExternalSource: Privilege = "Read Patch External Source"
        @available(*, deprecated, renamed: "viewLicenseSerialNumbers", message: "Jamf Pro names it View License Serial Numbers.")
        public static let viewLicenseSerial: Privilege = "View License Serial"
        /// Without it, licensed software is read without its serial numbers.
        public static let viewLicenseSerialNumbers: Privilege = "View License Serial Numbers"

        // Organization
        public static let createSites: Privilege = "Create Sites"
        public static let updateSites: Privilege = "Update Sites"
        public static let deleteSites: Privilege = "Delete Sites"
        public static let createCategories: Privilege = "Create Categories"
        public static let updateCategories: Privilege = "Update Categories"
        public static let deleteCategories: Privilege = "Delete Categories"
        public static let createBuildings: Privilege = "Create Buildings"
        public static let updateBuildings: Privilege = "Update Buildings"
        public static let deleteBuildings: Privilege = "Delete Buildings"
        public static let createDepartments: Privilege = "Create Departments"
        public static let updateDepartments: Privilege = "Update Departments"
        public static let deleteDepartments: Privilege = "Delete Departments"
        public static let readNetworkSegments: Privilege = "Read Network Segments"
        public static let createNetworkSegments: Privilege = "Create Network Segments"
        public static let updateNetworkSegments: Privilege = "Update Network Segments"
        public static let deleteNetworkSegments: Privilege = "Delete Network Segments"

        // Extension attributes
        public static let readComputerExtensionAttributes: Privilege = "Read Computer Extension Attributes"
        public static let createComputerExtensionAttributes: Privilege = "Create Computer Extension Attributes"
        public static let updateComputerExtensionAttributes: Privilege = "Update Computer Extension Attributes"
        public static let deleteComputerExtensionAttributes: Privilege = "Delete Computer Extension Attributes"
        public static let readMobileDeviceExtensionAttributes: Privilege = "Read Mobile Device Extension Attributes"
        public static let createMobileDeviceExtensionAttributes: Privilege = "Create Mobile Device Extension Attributes"
        public static let updateMobileDeviceExtensionAttributes: Privilege = "Update Mobile Device Extension Attributes"
        public static let deleteMobileDeviceExtensionAttributes: Privilege = "Delete Mobile Device Extension Attributes"
        public static let readUserExtensionAttributes: Privilege = "Read User Extension Attributes"
        public static let createUserExtensionAttributes: Privilege = "Create User Extension Attributes"
        public static let updateUserExtensionAttributes: Privilege = "Update User Extension Attributes"
        public static let deleteUserExtensionAttributes: Privilege = "Delete User Extension Attributes"

        // Scripts, packages and distribution points
        public static let readScripts: Privilege = "Read Scripts"
        public static let createScripts: Privilege = "Create Scripts"
        public static let updateScripts: Privilege = "Update Scripts"
        public static let deleteScripts: Privilege = "Delete Scripts"
        public static let readPackages: Privilege = "Read Packages"
        public static let createPackages: Privilege = "Create Packages"
        public static let updatePackages: Privilege = "Update Packages"
        public static let deletePackages: Privilege = "Delete Packages"
        public static let createDistributionPoints: Privilege = "Create Distribution Points"
        public static let updateDistributionPoints: Privilege = "Update Distribution Points"
        public static let deleteDistributionPoints: Privilege = "Delete Distribution Points"

        // Accounts, users and directories
        public static let readLDAPServers: Privilege = "Read LDAP Servers"
        public static let createLDAPServers: Privilege = "Create LDAP Servers"
        public static let updateLDAPServers: Privilege = "Update LDAP Servers"
        public static let deleteLDAPServers: Privilege = "Delete LDAP Servers"
        public static let readAccounts: Privilege = "Read Accounts"
        public static let createAccounts: Privilege = "Create Accounts"
        public static let updateAccounts: Privilege = "Update Accounts"
        public static let deleteAccounts: Privilege = "Delete Accounts"
        public static let readUser: Privilege = "Read User"
        public static let createUser: Privilege = "Create User"
        public static let updateUser: Privilege = "Update User"
        public static let deleteUser: Privilege = "Delete User"
        public static let readSmartUserGroups: Privilege = "Read Smart User Groups"
        public static let createSmartUserGroups: Privilege = "Create Smart User Groups"
        public static let updateSmartUserGroups: Privilege = "Update Smart User Groups"
        public static let deleteSmartUserGroups: Privilege = "Delete Smart User Groups"
        public static let readStaticUserGroups: Privilege = "Read Static User Groups"
        public static let createStaticUserGroups: Privilege = "Create Static User Groups"
        public static let updateStaticUserGroups: Privilege = "Update Static User Groups"
        public static let deleteStaticUserGroups: Privilege = "Delete Static User Groups"
        public static let readDirectoryBindings: Privilege = "Read Directory Bindings"
        public static let createDirectoryBindings: Privilege = "Create Directory Bindings"
        public static let updateDirectoryBindings: Privilege = "Update Directory Bindings"
        public static let deleteDirectoryBindings: Privilege = "Delete Directory Bindings"
        public static let readSoftwareUpdateServers: Privilege = "Read Software Update Servers"
        public static let createSoftwareUpdateServers: Privilege = "Create Software Update Servers"
        public static let updateSoftwareUpdateServers: Privilege = "Update Software Update Servers"
        public static let deleteSoftwareUpdateServers: Privilege = "Delete Software Update Servers"

        // Groups and searches
        public static let createSmartComputerGroups: Privilege = "Create Smart Computer Groups"
        public static let updateSmartComputerGroups: Privilege = "Update Smart Computer Groups"
        public static let deleteSmartComputerGroups: Privilege = "Delete Smart Computer Groups"
        public static let createStaticComputerGroups: Privilege = "Create Static Computer Groups"
        public static let updateStaticComputerGroups: Privilege = "Update Static Computer Groups"
        public static let deleteStaticComputerGroups: Privilege = "Delete Static Computer Groups"
        public static let createSmartMobileDeviceGroups: Privilege = "Create Smart Mobile Device Groups"
        public static let updateSmartMobileDeviceGroups: Privilege = "Update Smart Mobile Device Groups"
        public static let deleteSmartMobileDeviceGroups: Privilege = "Delete Smart Mobile Device Groups"
        public static let createStaticMobileDeviceGroups: Privilege = "Create Static Mobile Device Groups"
        public static let updateStaticMobileDeviceGroups: Privilege = "Update Static Mobile Device Groups"
        public static let deleteStaticMobileDeviceGroups: Privilege = "Delete Static Mobile Device Groups"
        public static let readAdvancedComputerSearches: Privilege = "Read Advanced Computer Searches"
        public static let createAdvancedComputerSearches: Privilege = "Create Advanced Computer Searches"
        public static let updateAdvancedComputerSearches: Privilege = "Update Advanced Computer Searches"
        public static let deleteAdvancedComputerSearches: Privilege = "Delete Advanced Computer Searches"
        public static let readAdvancedMobileDeviceSearches: Privilege = "Read Advanced Mobile Device Searches"
        public static let createAdvancedMobileDeviceSearches: Privilege = "Create Advanced Mobile Device Searches"
        public static let updateAdvancedMobileDeviceSearches: Privilege = "Update Advanced Mobile Device Searches"
        public static let deleteAdvancedMobileDeviceSearches: Privilege = "Delete Advanced Mobile Device Searches"
        public static let readAdvancedUserSearches: Privilege = "Read Advanced User Searches"
        public static let createAdvancedUserSearches: Privilege = "Create Advanced User Searches"
        public static let updateAdvancedUserSearches: Privilege = "Update Advanced User Searches"
        public static let deleteAdvancedUserSearches: Privilege = "Delete Advanced User Searches"

        // Profiles, apps and other objects
        public static let readMacOSConfigurationProfiles: Privilege = "Read macOS Configuration Profiles"
        public static let createMacOSConfigurationProfiles: Privilege = "Create macOS Configuration Profiles"
        public static let updateMacOSConfigurationProfiles: Privilege = "Update macOS Configuration Profiles"
        public static let deleteMacOSConfigurationProfiles: Privilege = "Delete macOS Configuration Profiles"
        public static let readIOSConfigurationProfiles: Privilege = "Read iOS Configuration Profiles"
        public static let createIOSConfigurationProfiles: Privilege = "Create iOS Configuration Profiles"
        public static let updateIOSConfigurationProfiles: Privilege = "Update iOS Configuration Profiles"
        public static let deleteIOSConfigurationProfiles: Privilege = "Delete iOS Configuration Profiles"
        public static let readMacApplications: Privilege = "Read Mac Applications"
        public static let createMacApplications: Privilege = "Create Mac Applications"
        public static let updateMacApplications: Privilege = "Update Mac Applications"
        public static let deleteMacApplications: Privilege = "Delete Mac Applications"
        public static let readMobileDeviceApplications: Privilege = "Read Mobile Device Applications"
        public static let createMobileDeviceApplications: Privilege = "Create Mobile Device Applications"
        public static let updateMobileDeviceApplications: Privilege = "Update Mobile Device Applications"
        public static let deleteMobileDeviceApplications: Privilege = "Delete Mobile Device Applications"
        public static let readEBooks: Privilege = "Read eBooks"
        public static let createEBooks: Privilege = "Create eBooks"
        public static let updateEBooks: Privilege = "Update eBooks"
        public static let deleteEBooks: Privilege = "Delete eBooks"
        public static let readClasses: Privilege = "Read Classes"
        public static let createClasses: Privilege = "Create Classes"
        public static let updateClasses: Privilege = "Update Classes"
        public static let deleteClasses: Privilege = "Delete Classes"
        public static let readRestrictedSoftware: Privilege = "Read Restricted Software"
        public static let createRestrictedSoftware: Privilege = "Create Restricted Software"
        public static let updateRestrictedSoftware: Privilege = "Update Restricted Software"
        public static let deleteRestrictedSoftware: Privilege = "Delete Restricted Software"
        public static let readLicensedSoftware: Privilege = "Read Licensed Software"
        public static let createLicensedSoftware: Privilege = "Create Licensed Software"
        public static let updateLicensedSoftware: Privilege = "Update Licensed Software"
        public static let deleteLicensedSoftware: Privilege = "Delete Licensed Software"
        public static let readPrinters: Privilege = "Read Printers"
        public static let createPrinters: Privilege = "Create Printers"
        public static let updatePrinters: Privilege = "Update Printers"
        public static let deletePrinters: Privilege = "Delete Printers"
        public static let readDockItems: Privilege = "Read Dock Items"
        public static let createDockItems: Privilege = "Create Dock Items"
        public static let updateDockItems: Privilege = "Update Dock Items"
        public static let deleteDockItems: Privilege = "Delete Dock Items"
        public static let readPolicies: Privilege = "Read Policies"
        public static let updatePolicies: Privilege = "Update Policies"
        public static let deletePolicies: Privilege = "Delete Policies"
        public static let readPatchPolicies: Privilege = "Read Patch Policies"
        public static let createPatchPolicies: Privilege = "Create Patch Policies"
        public static let updatePatchPolicies: Privilege = "Update Patch Policies"
        public static let deletePatchPolicies: Privilege = "Delete Patch Policies"
        public static let readPatchManagementSoftwareTitles: Privilege = "Read Patch Management Software Titles"
        public static let createPatchManagementSoftwareTitles: Privilege = "Create Patch Management Software Titles"
        public static let updatePatchManagementSoftwareTitles: Privilege = "Update Patch Management Software Titles"
        public static let deletePatchManagementSoftwareTitles: Privilege = "Delete Patch Management Software Titles"
        public static let readWebhooks: Privilege = "Read Webhooks"
        public static let createWebhooks: Privilege = "Create Webhooks"
        public static let updateWebhooks: Privilege = "Update Webhooks"
        public static let deleteWebhooks: Privilege = "Delete Webhooks"

        // Enrollment
        public static let readEnrollmentCustomizations: Privilege = "Read Enrollment Customizations"
        public static let createEnrollmentCustomizations: Privilege = "Create Enrollment Customizations"
        public static let updateEnrollmentCustomizations: Privilege = "Update Enrollment Customizations"
        public static let deleteEnrollmentCustomizations: Privilege = "Delete Enrollment Customizations"
        public static let createComputerPreStageEnrollments: Privilege = "Create Computer PreStage Enrollments"
        public static let deleteComputerPreStageEnrollments: Privilege = "Delete Computer PreStage Enrollments"
        public static let createMobileDevicePreStageEnrollments: Privilege = "Create Mobile Device PreStage Enrollments"
        public static let deleteMobileDevicePreStageEnrollments: Privilege = "Delete Mobile Device PreStage Enrollments"

        // Settings
        public static let updateComputerCheckIn: Privilege = "Update Computer Check-In"
        public static let readComputerInventoryCollectionSettings: Privilege = "Read Computer Inventory Collection Settings"
        public static let updateComputerInventoryCollectionSettings: Privilege = "Update Computer Inventory Collection Settings"
        public static let readSMTPServer: Privilege = "Read SMTP Server"
        public static let updateSMTPServer: Privilege = "Update SMTP Server"
        public static let updateSelfService: Privilege = "Update Self Service"
        public static let readReEnrollment: Privilege = "Read Re-enrollment"
        public static let updateReEnrollment: Privilege = "Update Re-enrollment"
        public static let updateLocalAdminPasswordSettings: Privilege = "Update Local Admin Password Settings"
        public static let readOnboardingConfiguration: Privilege = "Read Onboarding Configuration"
        public static let updateOnboardingConfiguration: Privilege = "Update Onboarding Configuration"
        public static let readSSOSettings: Privilege = "Read SSO Settings"
        public static let updateSSOSettings: Privilege = "Update SSO Settings"
    }
}

extension JamfPlatform.Client {
    /// The Jamf Pro version (`v1/jamf-pro-version`). Needs no privilege.
    public func jamfProVersion() async throws -> JamfPro.Version {
        try await get(JamfPro.Version.self, "pro/v1/jamf-pro-version")
    }
}
