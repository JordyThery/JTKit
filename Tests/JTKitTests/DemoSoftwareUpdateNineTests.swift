import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

/// The demo samples added in 1.9.0 for Software Update Dashboard 0.3.2’s
/// states, as the shared rules read them.
@Suite("1.9.0: demo samples for the newer states")
@MainActor
struct DemoSoftwareUpdateNineTests {
    private func read(_ blueprintID: String, seeds: Bool = true) async throws -> SoftwareUpdateRules.Reader.Reading {
        let defaults = UserDefaults(suiteName: "jtkit-demo-nine-\(UUID().uuidString)")!
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        DemoSoftwareUpdate.install(on: mode.jamfPlatformServer)
        let source = try #require(mode.source(for: .demoJamfPlatform))
        let client = try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                             recorder: RequestRecorder(session: source.session, log: nil), sleep: { _ in })
        let catalog = try await AppleReleases.Client(recorder: RequestRecorder(session: source.session, log: nil), userAgent: "JTKit tests",
                                                     sofaURL: DemoAppleReleaseServer.sofaURL, gdmfURL: DemoAppleReleaseServer.gdmfURL).catalog()
        var reader = SoftwareUpdateRules.Reader(client: client, catalog: catalog, serverTimeZone: .gmt)
        reader.seedsDemoDeadlines = seeds
        return try await reader.read(blueprintID: blueprintID)
    }

    private func device(_ reading: SoftwareUpdateRules.Reader.Reading, _ name: String) throws -> SoftwareUpdateRules.DeviceStatus {
        try #require(reading.devices.first { $0.name == name })
    }

    @Test("Status times that line up with the last contact: a non-UTC server time zone setting looks wrong, UTC doesn’t")
    func serverTimeZone() async throws {
        for blueprint in [DemoSoftwareUpdate.iPadBlueprintID, DemoSoftwareUpdate.macBlueprintID] {
            let reading = try await read(blueprint)
            let samples = reading.inputs.map { ($0.member.lastSeen, $0.status?.newestUpdate) }
            #expect(SoftwareUpdateRules.ServerTimeZoneCheck.looksWrong(samples, zone: TimeZone(identifier: "Europe/Amsterdam")!))
            #expect(!SoftwareUpdateRules.ServerTimeZoneCheck.looksWrong(samples, zone: TimeZone(identifier: "UTC")!))
        }
    }

    @Test("Two Macs missed the deadline and report their next install attempt; the Blueprint’s deadline stays")
    func nextAttempts() async throws {
        let macs = try await read(DemoSoftwareUpdate.macBlueprintID)
        let twelve = try device(macs, "Studio Mac 12"), thirteen = try device(macs, "Studio Mac 13")
        for mac in [twelve, thirteen] {
            #expect(mac.nextInstallAttempt != nil, "\(mac.name)")
            #expect(mac.pastDeadline == true, "\(mac.name)")
            #expect(mac.deadlineLocal?.hasSuffix("T22:59:00") == true, "\(mac.name): the Blueprint’s deadline")
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        #expect(twelve.nextInstallAttempt.map { utc.dateComponents([.hour, .minute, .second], from: $0) }
                == DateComponents(hour: 6, minute: 2, second: 31))
        #expect(thirteen.nextInstallAttempt.map { utc.dateComponents([.hour, .minute], from: $0) } == DateComponents(hour: 23, minute: 29))
        #expect(thirteen.installReason == "install-tonight")
        #expect(thirteen.diagnosis == "Downloaded, not installed after the deadline")
        // the Macs that report Jamf's own deadline have none
        #expect(try device(macs, "Studio Mac 02").nextInstallAttempt == nil)
    }

    @Test("Installing for hours with no contact since; the bootstrap token; update files Apple no longer has")
    func diagnoses() async throws {
        let macs = try await read(DemoSoftwareUpdate.macBlueprintID)
        let installing = try device(macs, "Studio Mac 14")
        #expect(installing.diagnosis.hasPrefix("Installing since") && installing.diagnosis.contains("no contact since"))
        #expect(installing.needsAttention)
        #expect(try device(macs, "Studio Mac 15").diagnosis
                == "Update failed: the Mac couldn’t get its bootstrap token (check that it’s escrowed in Jamf Pro)")
        #expect(try device(macs, "Studio Mac 15").bootstrapToken == "NOT_ESCROWED")
        #expect(try device(macs, "Studio Mac 16").diagnosis
                == "Update files no longer available from Apple; check again after the device’s next check-in")
        // the iPad installing for hours still checks in: the other diagnosis
        let iPads = try await read(DemoSoftwareUpdate.iPadBlueprintID)
        #expect(try device(iPads, "Field iPad 12").diagnosis.hasPrefix("Installing"))
    }

    @Test("macOS 15.7.4, posted publicly again: with the earlier refreshes the deadline counts from its first posting")
    func rePosted() async throws {
        let remembered = try device(try await read(DemoSoftwareUpdate.macBlueprintID), "Studio Mac 11")
        #expect(remembered.targetVersion == "15.7.4")
        #expect(remembered.deadlineSource == "As the Blueprint’s devices reported it earlier")
        #expect(remembered.pastDeadline == true)
        let fresh = try device(try await read(DemoSoftwareUpdate.macBlueprintID, seeds: false), "Studio Mac 11")
        #expect(fresh.deadlineSource == "From Apple’s posting date")
        #expect(fresh.pastDeadline == false, "from the later posting, 3 days ago plus 7")
    }

    @Test("A pilot iPad and Mac were in scope two and three days back only")
    func leftTheScope() async throws {
        let past = DemoSoftwareUpdate.pastRefreshes()
        for refresh in past {
            let expected = (2...3).contains(refresh.daysAgo)
            #expect(refresh.formerMembers.isEmpty == !expected)
            #expect(refresh.formerMembers.allSatisfy { refresh.extraScopeGroup != nil && DemoSoftwareUpdate.formerDevices.contains($0) })
        }
        let today = try await read(DemoSoftwareUpdate.iPadBlueprintID).members.map(\.serialNumber)
            + read(DemoSoftwareUpdate.macBlueprintID).members.map(\.serialNumber)
        for former in DemoSoftwareUpdate.formerDevices {
            #expect(!today.contains(former.serial))
            #expect(!DemoSoftwareUpdate.devices.contains(former))
        }
    }
}
