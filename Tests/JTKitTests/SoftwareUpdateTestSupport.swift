import Foundation
import JTKit
@testable import JTKit

/// Made-up devices and dates for the logic tests.
enum Sample {
    static let utc = TimeZone(identifier: "UTC")!

    /// `2026-11-05T12:00:00` read as UTC.
    static func date(_ text: String) -> Date {
        JamfPro.serverDate(text, timeZone: utc)!
    }

    static let now = date("2026-11-05T13:00:00")
    static let updateStarted = date("2026-11-01T00:00:00")

    static func iPad(_ id: String = "1", os: String = "26.7.1", model: String = "iPad13,18",
                     lastContact: Date? = date("2026-11-05T10:00:00"), timeZone: String? = "Europe/Brussels") -> JamfPro.GroupMember {
        JamfPro.GroupMember(id: id, kind: .mobileDevice, name: "Test iPad \(id)", serialNumber: "ZZTEST\(id)",
                            managementID: "MGMT-\(id)", osVersion: os, model: "iPad Air", modelIdentifier: model,
                            timeZone: timeZone, lastContact: lastContact, managed: true, supervised: true, ddmEnabled: true,
                            batteryLevel: 90, batteryHealth: "NORMAL", availableSpaceMB: 25_000, capacityMB: 64_000)
    }

    static func mac(_ id: String = "7", os: String = "27.0.1", model: String = "Mac14,2") -> JamfPro.GroupMember {
        JamfPro.GroupMember(id: id, kind: .computer, name: "Test Mac \(id)", serialNumber: "ZZTESTM\(id)",
                            managementID: "MGMT-M\(id)", osVersion: os, model: "MacBook Air", modelIdentifier: model,
                            lastContact: date("2026-11-05T10:00:00"), managed: true, supervised: true)
    }

    static func status(_ pairs: [(String, String)], time: String = "2026-11-05T12:00:00") -> JamfPro.SoftwareUpdateStatus {
        JamfPro.SoftwareUpdateStatus(items: pairs.map { JamfPro.StatusItem(key: $0.0, value: $0.1, lastUpdateTime: time) })
    }

    /// Models that run iPadOS and macOS 27, and those that stop earlier.
    static let supported: Set<String> = ["iPad13,18", "iPad14,8", "Mac14,2"]
    static let known: Set<String> = supported.union(["iPad7,5", "J132AP", "MacBookPro15,2"])

    static func context(target: String? = "27.0.1", since: Date? = nil, serverTimeZone: TimeZone = utc,
                        oldestMaintainedMajor: Int? = 18) -> ClassificationContext {
        ClassificationContext(target: target.flatMap(OSVersion.init), since: since, serverTimeZone: serverTimeZone, now: now,
                              staleDays: 30, supports: { model, board, major in
                                  guard let id = model ?? board, known.contains(id) else { return nil }
                                  return major < 27 || supported.contains(id)
                              }, oldestMaintainedMajor: oldestMaintainedMajor)
    }

    /// One device against its own target (`TargetRules`).
    static func classify(_ member: JamfPro.GroupMember, _ status: JamfPro.SoftwareUpdateStatus?, target: DeviceTarget,
                         now: String = "2026-11-09T12:00:00") -> DeviceStatus {
        Classifier.classify(DeviceInput(member: member, status: status), target: target,
                            context: ClassificationContext(target: nil, serverTimeZone: utc, now: date(now)))
    }

    static func classify(_ member: JamfPro.GroupMember, _ status: JamfPro.SoftwareUpdateStatus?,
                         problem: String? = nil, context: ClassificationContext = context()) -> DeviceStatus {
        Classifier.classify(DeviceInput(member: member, status: status, statusProblem: problem), context: context)
    }
}
