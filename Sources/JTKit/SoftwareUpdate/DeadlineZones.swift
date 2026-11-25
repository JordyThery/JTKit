import Foundation

extension SoftwareUpdateRules {
    /// When a deadline falls for the devices in one time zone. A Blueprint’s
    /// deadline is each device’s local time, so devices in different zones
    /// reach it at different moments; devices with different targets have
    /// different deadlines. A device that reports its deadline gives the
    /// moment itself (written in UTC, so its offset says nothing about where
    /// the device is).
    public nonisolated struct DeadlineZone: Sendable, Hashable, Identifiable {
        /// An IANA name; nil for devices that report no time zone.
        public var zone: String?
        /// The deadline in the devices’ local time (computed from the rule).
        public var localDeadline: String
        /// The row’s moment when it is placed by its moment (no time zone, or a
        /// reported deadline): shown in this Mac’s time zone; nil for a zone’s row.
        public var reported: Date?
        /// The devices’ target, which tells rows without a zone apart.
        public var target: String?
        public var deviceCount: Int
        /// The moment the deadline falls: reported, or from the zone; nil
        /// for a computed deadline without a zone.
        public var deadline: Date?
        /// Why the zone stands out; nil when it doesn’t.
        public var unusual: String?

        public var id: String { "\(zone ?? "")|\(reported.map { String($0.timeIntervalSince1970) } ?? localDeadline)|\(target ?? "")" }

        /// “Europe/Brussels” or “No time zone”.
        public var label: String { zone ?? "No time zone" }

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            zone: String? = nil,
            localDeadline: String,
            reported: Date? = nil,
            target: String? = nil,
            deviceCount: Int,
            deadline: Date? = nil,
            unusual: String? = nil
        ) {
            self.zone = zone
            self.localDeadline = localDeadline
            self.reported = reported
            self.target = target
            self.deviceCount = deviceCount
            self.deadline = deadline
            self.unusual = unusual
        }
    }

    public nonisolated enum DeadlineZones {
        /// Why a Mac’s row has no time zone: shown once under the table.
        public static let macNote = "Jamf Pro has no time zone for Macs: the deadline is each Mac’s own local time"

        /// One row per target and deadline moment, most devices first. A device
        /// with a time zone and a computed deadline gets its zone’s row; one
        /// without a zone (a Mac) or with a reported moment is placed by its
        /// moment: a computed deadline in this Mac’s time zone, a reported one
        /// as reported (written in UTC, so its offset says nothing about where
        /// the device is). So a computed 23:59 and a reported 23:59 here are one
        /// row. A row stands out when its zone’s offset differs from the most
        /// common one, when it isn’t a whole hour from UTC, when its moment is
        /// hours off the most common one for its target, or when it has no zone.
        public static func zones(devices: [DeviceStatus], here: TimeZone = .current, now: Date = Date()) -> [DeadlineZone] {
            // a device that counts as past its earlier step's own deadline (passed by the grace,
            // not installing, also when it failed) is listed at that step and its deadline; one
            // still installing the step stays at its current target's deadline
            let shown = devices.map { device -> DeviceStatus in
                // the target pending with the earlier step's deadline: labeled, at the deadline that
                // counts (the Blueprint's), never at the passed step deadline it doesn't count against
                if let step = device.carriedStepVersion, let target = device.targetVersion {
                    var carried = device
                    carried.targetVersion = "\(target), still holds the deadline of earlier step \(step)"
                    return carried
                }
                guard let step = device.earlierStepVersion, device.earlierStepLapsed == true, device.pastDeadline == true,
                      device.earlierStepDeadline != nil || device.earlierStepLocal != nil else { return device }
                var stepped = device
                stepped.targetVersion = "\(step), earlier step"
                stepped.deadlineDate = device.earlierStepDeadline
                stepped.deadlineLocal = device.earlierStepLocal ?? device.earlierStepDeadline.map { TargetRules.localText($0, offset: 0) }
                return stepped
            }
            let withDeadline = shown.filter { $0.deadlineLocal != nil || $0.deadlineDate != nil }
            guard !withDeadline.isEmpty else { return [] }
            func offset(_ zone: String?, at local: String) -> Int? {
                guard let zone, let timeZone = TimeZone(identifier: zone) else { return nil }
                return timeZone.secondsFromGMT(for: JamfPlatform.SoftwareUpdateBlock.deadline(local, in: timeZone) ?? Date())
            }
            // the zone a device’s row belongs to: its own for a computed deadline, none when placed by its moment
            func rowZone(_ device: DeviceStatus) -> String? { device.deadlineDate == nil ? device.timeZone : nil }
            func moment(_ device: DeviceStatus) -> Date? {
                device.deadlineDate ?? TargetRules.deadlineDate(device.deadlineLocal, timeZone: rowZone(device) ?? here.identifier)
            }
            let zoned = withDeadline.filter { rowZone($0) != nil }
            let common = Dictionary(grouping: zoned.compactMap { offset($0.timeZone, at: $0.deadlineLocal ?? "") }) { $0 }
                .max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key
            let groups = Dictionary(grouping: withDeadline) { device -> String in
                let minute = moment(device).map { String(Int($0.timeIntervalSince1970 / 60)) } ?? device.deadlineLocal ?? ""
                return "\(rowZone(device) ?? "")|\(device.targetVersion ?? "")|\(minute)"
            }
            // per target, the moment most devices without a zone share
            let placed = groups.values.filter { rowZone($0[0]) == nil }
            var usual: [String: Date] = [:]
            // most devices first; on a tie, the earliest moment
            for group in placed.sorted(by: { $0.count != $1.count ? $0.count > $1.count
                                             : (moment($0[0]) ?? .distantFuture) < (moment($1[0]) ?? .distantFuture) }) {
                let target = group[0].targetVersion ?? ""
                if usual[target] == nil, let at = moment(group[0]) { usual[target] = at }
            }
            func hoursText(_ seconds: Double) -> String {
                let hours = seconds / 3_600
                return "\(hours > 0 ? "+" : "")\(hours.formatted(.number.precision(.fractionLength(0...1)))) h from most of the devices"
            }
            return groups.values.map { group -> DeadlineZone in
                let first = group[0]
                let zone = rowZone(first)
                let local = group.first { $0.deadlineDate == nil }?.deadlineLocal ?? first.deadlineLocal ?? ""
                let at = moment(first)
                var unusual: String?
                if zone == nil {
                    // placed by its moment: hours off the rest for its target (in some other zone),
                    // else a Mac’s note; days off is another deadline, not another zone
                    if let at, let reference = usual[first.targetVersion ?? ""],
                       (3_600...(26 * 3_600)).contains(abs(at.timeIntervalSince(reference))) {
                        unusual = hoursText(at.timeIntervalSince(reference))
                    } else if group.contains(where: { $0.deadlineDate == nil }) {
                        unusual = first.isComputer ? macNote : "No time zone reported"
                    }
                } else if TimeZone(identifier: zone!) == nil {
                    unusual = "Not a time zone the Mac knows"
                } else if let seconds = offset(zone, at: local), seconds % 3_600 != 0 {
                    unusual = "Not a whole hour from UTC"
                } else if let seconds = offset(zone, at: local), let common, seconds != common {
                    unusual = hoursText(Double(seconds - common))
                }
                return DeadlineZone(zone: zone, localDeadline: local, reported: zone == nil ? at : nil,
                                    target: zone == nil || first.targetVersion?.contains("earlier step") == true ? first.targetVersion : nil,
                                    deviceCount: group.count,
                                    deadline: at, unusual: unusual)
            }
            .sorted { $0.deviceCount != $1.deviceCount ? $0.deviceCount > $1.deviceCount
                      : ($0.label, $0.deadline ?? .distantFuture, $0.localDeadline, $0.target ?? "")
                        < ($1.label, $1.deadline ?? .distantFuture, $1.localDeadline, $1.target ?? "") }
        }

        /// A deadline as it is shown everywhere, with its time basis in
        /// parentheses: a reported moment in this Mac’s time zone, “(this Mac’s
        /// time)”; a local date-time as “(device’s local time)”. Where it comes
        /// from is said apart (`DeadlineSource`).
        public static func text(local: String?, reported: Date?, timeZone: TimeZone = .current) -> String? {
            if let reported {
                var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
                style.timeZone = timeZone
                return "\(reported.formatted(style)) (this Mac’s time)"
            }
            return local.map { "\(TargetRules.readable($0)) (device’s local time)" }
        }
    }

    /// Hardware to replace, by model: devices with no release they can run, and
    /// devices measured against an older major because they can’t run the newest.
    public nonisolated struct Replacement: Sendable, Hashable, Identifiable {
        public var modelIdentifier: String
        public var model: String
        public var deviceCount: Int
        /// The newest version the model can run, from Apple’s release data.
        public var lastSupportedVersion: String?
        /// How these devices are counted, e.g. “Measured against 26.7.2, the newest it can run”.
        public var note: String

        public var id: String { modelIdentifier }

        public static func list(_ devices: [DeviceStatus], lastSupported: (DeviceStatus) -> String?) -> [Replacement] {
            Dictionary(grouping: devices.filter { $0.category == .unsupported || $0.limitedByHardware == true }, by: \.modelIdentifier)
                .map { identifier, group in
                    let unsupported = group.filter { $0.category == .unsupported }.count
                    let targets = Set(group.filter { $0.category != .unsupported }.compactMap(\.targetVersion)).sorted()
                    var notes: [String] = []
                    if unsupported > 0 { notes.append("\(unsupported) unsupported: no release it can run applies") }
                    if !targets.isEmpty {
                        notes.append("measured against \(targets.joined(separator: ", ")), the newest it can run")
                    }
                    return Replacement(modelIdentifier: identifier, model: group.first?.model ?? "", deviceCount: group.count,
                                       lastSupportedVersion: lastSupported(group[0]),
                                       note: notes.joined(separator: "; ").capitalizedFirst)
                }
                .sorted { $0.deviceCount != $1.deviceCount ? $0.deviceCount > $1.deviceCount : $0.modelIdentifier < $1.modelIdentifier }
        }

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            modelIdentifier: String,
            model: String,
            deviceCount: Int,
            lastSupportedVersion: String? = nil,
            note: String
        ) {
            self.modelIdentifier = modelIdentifier
            self.model = model
            self.deviceCount = deviceCount
            self.lastSupportedVersion = lastSupportedVersion
            self.note = note
        }
    }
}

extension String {
    nonisolated var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
