import Foundation

extension SoftwareUpdateRules {
    /// Devices the Blueprint’s software update can’t reach as they are: each
    /// count on the dashboard opens those devices in the list. A device counts
    /// once, under its most basic reason: the cases in their order, so an iPad
    /// on iPadOS 15 without declarative management and without a report counts
    /// under OS too old only.
    public nonisolated enum ReadinessCheck: String, CaseIterable, Identifiable, Hashable, Sendable {
        /// iOS or iPadOS 16 or earlier, macOS 13 or earlier: Apple’s software
        /// update enforcement declaration starts at iOS 17 and macOS 14.
        case osTooOld
        /// Declarative device management is off: the Blueprint can’t reach it.
        case noDeclarativeManagement
        /// An iPhone or iPad enrolled with User Enrollment: Apple’s enforced
        /// software update allows supervised and device enrollments only.
        case userEnrollment
        /// A Mac that isn’t supervised: on macOS Apple allows the enforced
        /// software update on supervised Macs only.
        case macNotSupervised
        /// Jamf Pro has no status report of the device at all.
        case neverReported

        public var id: String { rawValue }

        /// Under the counts: why a device may be missing from a count that also fits it.
        public static let countedOnce = "Each device counts once, under the first reason that applies."

        public var title: String {
            switch self {
            case .userEnrollment: "User Enrollment"
            case .macNotSupervised: "Macs not supervised"
            case .noDeclarativeManagement: "No declarative device management"
            case .neverReported: "Never reported"
            case .osTooOld: "OS too old for update declarations"
            }
        }

        /// What it means, under the count.
        public var note: String {
            switch self {
            case .userEnrollment: "iPhones and iPads enrolled this way don’t get an enforced update"
            case .macNotSupervised: "A Mac gets an enforced update only when it’s supervised"
            case .noDeclarativeManagement: "The Blueprint can’t reach these devices"
            case .neverReported: "No status report in Jamf Pro yet"
            case .osTooOld: "Apple’s update declaration starts at iOS and iPadOS 17 and macOS 14"
            }
        }

        public var systemImage: String {
            switch self {
            case .userEnrollment: "person.crop.circle"
            case .macNotSupervised: "lock.open"
            case .noDeclarativeManagement: "point.3.connected.trianglepath.dotted"
            case .neverReported: "questionmark.circle"
            case .osTooOld: "clock.badge.exclamationmark"
            }
        }

        /// Whether the device counts under this check: its most basic reason (`reason(for:)`).
        public func applies(to device: DeviceStatus) -> Bool {
            Self.reason(for: device) == self
        }

        /// The most basic reason the update can’t reach the device; nil when none fits.
        static func reason(for device: DeviceStatus) -> ReadinessCheck? {
            allCases.first { $0.fits(device) }
        }

        /// Whether this reason fits the device, whatever other reasons fit too.
        func fits(_ device: DeviceStatus) -> Bool {
            switch self {
            // Apple’s enforced update (com.apple.configuration.softwareupdate.enforcement.specific)
            // allows supervised and device enrollments on iOS and iPadOS, supervised Macs only on macOS
            case .userEnrollment: !device.isComputer && device.userEnrollment == true
            case .macNotSupervised: device.isComputer && device.supervised == false
            case .noDeclarativeManagement: device.ddmEnabled == false
            case .neverReported: device.neverReported == true
            case .osTooOld: OSVersion(device.currentOS).map { Self.isTooOldForDeclarations($0, isComputer: device.isComputer) } ?? false
            }
        }

        /// Below the first version Apple’s software update enforcement declaration supports.
        static func isTooOldForDeclarations(_ version: OSVersion, isComputer: Bool) -> Bool {
            version.major < (isComputer ? 14 : 17)
        }

        public static func count(_ check: ReadinessCheck, in devices: [DeviceStatus]) -> Int {
            devices.filter(check.applies).count
        }
    }
}
