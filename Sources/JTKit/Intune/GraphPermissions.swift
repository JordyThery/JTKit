import Foundation

extension Graph {
    /// How a client signs in to Microsoft Graph, which decides who grants a
    /// missing permission.
    public enum Access: Sendable, Hashable {
        /// A person signs in (Microsoft's sign-in window): delegated
        /// permissions, accepted at sign-in or granted by an admin.
        case delegated
        /// The app signs in with its own secret: application permissions,
        /// added to the app registration and granted by an admin.
        case application
    }

    /// A Microsoft Graph permission. Most have the same name as a delegated
    /// and as an application permission.
    public struct Permission: Hashable, Sendable, CustomStringConvertible {
        public let name: String
        /// The application permission's name when it differs.
        public let applicationName: String

        public init(_ name: String, application: String? = nil) {
            self.name = name
            applicationName = application ?? name
        }

        public func name(for access: Access) -> String {
            access == .application ? applicationName : name
        }

        public var description: String { name }

        public static let userRead = Permission("User.Read", application: "User.Read.All")
        /// The tenant's name and ID; delegated sign-ins read it with User.Read.
        public static let organizationRead = Permission("User.Read", application: "Organization.Read.All")
        public static let configurationRead = Permission("DeviceManagementConfiguration.Read.All")
        public static let configurationReadWrite = Permission("DeviceManagementConfiguration.ReadWrite.All")
        public static let scriptsRead = Permission("DeviceManagementScripts.Read.All")
        public static let scriptsReadWrite = Permission("DeviceManagementScripts.ReadWrite.All")
        public static let appsRead = Permission("DeviceManagementApps.Read.All")
        public static let appsReadWrite = Permission("DeviceManagementApps.ReadWrite.All")
        /// The Apple push certificate, ADE tokens and the MDM authority.
        public static let serviceConfigRead = Permission("DeviceManagementServiceConfig.Read.All")
        public static let groupRead = Permission("Group.Read.All")
        public static let groupReadWrite = Permission("Group.ReadWrite.All")
        public static let managedDevicesRead = Permission("DeviceManagementManagedDevices.Read.All")
        /// Deleting a device record.
        public static let managedDevicesReadWrite = Permission("DeviceManagementManagedDevices.ReadWrite.All")
        /// Device commands: sync, restart, shut down, lock, clear passcode,
        /// retire, wipe.
        public static let managedDevicesPrivileged = Permission("DeviceManagementManagedDevices.PrivilegedOperations.All")

        /// Every permission in the table.
        public static let all: [Permission] = [
            .userRead, .organizationRead, .configurationRead, .configurationReadWrite, .scriptsRead, .scriptsReadWrite,
            .appsRead, .appsReadWrite, .serviceConfigRead, .groupRead, .groupReadWrite,
            .managedDevicesRead, .managedDevicesReadWrite, .managedDevicesPrivileged,
        ]

        /// The permission a request needs, from the table of the calls the
        /// apps make; nil for a call that isn't in it.
        /// - Parameter path: after the version, without the query, e.g.
        ///   `deviceManagement/configurationPolicies/{id}/assign`.
        public static func required(method: String, path: String) -> Permission? {
            let isRead = ["GET", "HEAD"].contains(method.uppercased())
            let segments = path.split(separator: "?", maxSplits: 1).first.map {
                $0.split(separator: "/").map { $0.lowercased() }
            } ?? []
            guard let first = segments.first else { return nil }
            let second = segments.count > 1 ? segments[1] : nil

            switch (first, second) {
            case ("me", _):
                return .userRead
            case ("organization", nil):
                return .organizationRead
            case ("organization", _?):
                // the MDM authority, from the Intune organization resource
                return .serviceConfigRead
            case ("groups", _):
                return isRead ? .groupRead : .groupReadWrite
            case ("deviceappmanagement", "mobileapps"?):
                return isRead ? .appsRead : .appsReadWrite
            case ("devicemanagement", let collection?):
                switch collection {
                case "configurationpolicies", "deviceconfigurations", "devicecompliancepolicies", "assignmentfilters",
                     "reusablepolicysettings":
                    return isRead ? .configurationRead : .configurationReadWrite
                case "configurationsettings":
                    return .configurationRead
                case "deviceshellscripts", "devicecustomattributeshellscripts":
                    return isRead ? .scriptsRead : .scriptsReadWrite
                case "applepushnotificationcertificate", "deponboardingsettings":
                    return .serviceConfigRead
                case "manageddevices":
                    if isRead { return .managedDevicesRead }
                    return method.uppercased() == "DELETE" && segments.count == 3
                        ? .managedDevicesReadWrite : .managedDevicesPrivileged
                default:
                    return nil
                }
            default:
                return nil
            }
        }
    }
}
