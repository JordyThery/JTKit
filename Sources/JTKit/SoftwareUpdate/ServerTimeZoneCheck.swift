import Foundation

extension SoftwareUpdateRules {
    /// Whether a connection’s Jamf Pro server time zone setting looks wrong.
    /// A check-in writes a device’s last contact (a moment) and its status
    /// report (a time without a zone, read in that setting) seconds apart. When
    /// they line up only once the status times are read in UTC, on several
    /// devices and almost never in the setting, the setting is off by its
    /// offset: the Connections tab says so and suggests UTC. The setting itself
    /// is never changed.
    public nonisolated enum ServerTimeZoneCheck {
        /// A check-in writes both within this of each other.
        public static let tolerance: TimeInterval = 120
        /// Devices that line up in UTC before anything is said.
        public static let minimumDevices = 3

        /// `samples`: each device’s last contact and its newest status time as
        /// Jamf Pro wrote it. False for UTC, or when the setting and UTC give
        /// the same moments (a zone at UTC+0 on those dates), and for the
        /// app’s own default setting (`defaultZone`).
        public static func looksWrong(_ samples: [(lastContact: Date?, statusTime: String?)], zone: TimeZone,
                               defaultZone: String = "UTC") -> Bool {
            guard zone.identifier != defaultZone else { return false }
            let utc = TimeZone(identifier: "UTC") ?? .gmt
            var inUTC = 0, inSetting = 0
            for sample in samples {
                guard let contact = sample.lastContact, let text = sample.statusTime,
                      let asUTC = JamfPro.serverDate(text, timeZone: utc),
                      let asSetting = JamfPro.serverDate(text, timeZone: zone),
                      asUTC != asSetting else { continue }
                if abs(contact.timeIntervalSince(asUTC)) <= tolerance { inUTC += 1 }
                if abs(contact.timeIntervalSince(asSetting)) <= tolerance { inSetting += 1 }
            }
            // consistently: at least a few in UTC, and at most one in ten of those in the setting
            return inUTC >= minimumDevices && inSetting * 10 <= inUTC
        }

        /// What the Connections tab says.
        public static func warning(zone: String) -> String {
            "Devices’ status times line up with their last contact in UTC, not in \(zone): this server time zone looks wrong. "
                + "Jamf Cloud servers normally use UTC."
        }
    }
}
