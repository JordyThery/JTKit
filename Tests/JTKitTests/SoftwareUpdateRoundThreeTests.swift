import Foundation
import Testing
@testable import JTKit

// 1.5.0: recognizing a device in Apple’s release lists, the pending version
// as the device reports it and a Mac’s bootstrap token. Made-up data only.

@Suite("1.5.0: devices in Apple’s release lists")
struct DeviceRecognitionTests {
    // X86LEGACYAP is listed for an older major only, as in Apple’s own data;
    // J152FAP (an Intel Mac with a T2 chip) for both majors
    static let gdmf = #"""
    {"AssetSets":{"macOS":[
      {"ProductVersion":"26.7.2","Build":"25G332","PostingDate":"2026-10-26","SupportedDevices":["J152FAP","J314sAP"]},
      {"ProductVersion":"26.7.1","Build":"25G241","PostingDate":"2026-09-28","SupportedDevices":["J152FAP","J314sAP"]},
      {"ProductVersion":"26.6.9","Build":"25F900","PostingDate":"2026-09-01","SupportedDevices":["J314sAP"]},
      {"ProductVersion":"12.7.9","Build":"21H900","PostingDate":"2025-01-01","SupportedDevices":["X86LEGACYAP","J152FAP"]}]}}
    """#
    static let sofaMacOS = #"""
    {"OSVersions":[{"OSVersion":"Tahoe 26","Latest":{"ProductVersion":"26.7.2","Build":"25G332","ReleaseDate":"2026-10-26T00:00:00Z"},
      "SecurityReleases":[{"ProductVersion":"26.6","Build":"25F100","ReleaseDate":"2026-07-27T00:00:00Z"}]}],
     "Models":{"MacBookPro16,1":{"OSVersions":[26,15,12]},"MacBookPro18,3":{"OSVersions":[26]}},
     "Devices":{"J314sAP":{"DeviceID":"MacBookPro18,3"}}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofaMacOS.utf8), gdmf: Data(gdmf.utf8))

    func release(_ text: String) -> AppleReleases.Release { Self.catalog.release(OSVersion(text)!, .macOS)! }

    @Test("An Intel Mac reporting X86LEGACYAP is unknown to a release list, never unsupported")
    func legacyIntel() {
        for version in ["26.7.2", "26.7.1", "26.6.9", "26.6"] {
            #expect(Self.catalog.supports(release: release(version), model: "MacBookPro16,1", boardID: "X86LEGACYAP") == nil)
        }
        // by its major it runs 26
        #expect(Self.catalog.supports(model: "MacBookPro16,1", boardID: "X86LEGACYAP", major: 26, .macOS) == true)
    }

    @Test("An Intel Mac reporting its T2 board ID is recognized by it")
    func t2BoardID() {
        #expect(Self.catalog.supports(release: release("26.7.2"), model: "MacBookPro16,1", boardID: "J152FAP") == true)
        #expect(Self.catalog.supports(release: release("26.6.9"), model: "MacBookPro16,1", boardID: "J152FAP") == false)
        // a release without a list says nothing
        #expect(Self.catalog.supports(release: release("26.6"), model: "MacBookPro16,1", boardID: "J152FAP") == nil)
    }

    @Test("The device ID comes first, then the model’s boards")
    func order() {
        #expect(Self.catalog.supports(release: release("26.6.9"), model: "MacBookPro18,3", boardID: nil) == true)
        #expect(Self.catalog.supports(release: release("26.6.9"), model: "MacBookPro16,1", boardID: "J314sAP") == true)
        #expect(Self.catalog.supports(release: release("26.6.9"), model: "MacBookPro18,3", boardID: "X86LEGACYAP") == true)
    }
}

@Suite("1.5.0: the pending version as reported")
struct PendingVersionTests {
    private func status(_ pairs: [(String, String)], time: String = "2026-11-05T12:00:00") -> JamfPro.SoftwareUpdateStatus {
        JamfPro.SoftwareUpdateStatus(items: pairs.map { JamfPro.StatusItem(key: $0.0, value: $0.1, lastUpdateTime: time) })
    }

    @Test("Flattened install reasons are read, comma-separated")
    func reasons() {
        #expect(status([("softwareupdate.install-reason.reason", "declaration,system-settings")]).installReasons
                == ["declaration", "system-settings"])
        #expect(status([("softwareupdate.install-reason", #"{softwareupdate-reason=declaration}"#)]).installReasons == ["declaration"])
    }

    @Test("The deadline with an offset is a moment; without one it isn’t")
    func offset() throws {
        let reported = status([("softwareupdate.pending-version.os-version", "26.7.2"),
                               ("softwareupdate.pending-version.target-local-date-time", "2026-11-09 22:59:12 +0000")],
                              time: "2026-11-02T08:00:00")
        let pending = try #require(reported.pendingVersion)
        #expect(pending.updated == "2026-11-02T08:00:00")
        #expect(pending.targetOffset == 0)
        #expect(pending.targetDate == JamfPro.serverDate("2026-11-09T22:59:12", timeZone: .gmt))
        let local = JamfPro.SoftwareUpdateStatus.PendingVersion(osVersion: "27.1", targetLocalDateTime: "2026-11-20T17:00:00+01:00")
        #expect(local.targetOffset == 3_600)
        #expect(local.targetDate == JamfPro.serverDate("2026-11-20T16:00:00", timeZone: .gmt))
        #expect(JamfPro.SoftwareUpdateStatus.PendingVersion(targetLocalDateTime: "2026-11-20T17:00:00").targetDate == nil)
    }
}

@Suite("1.5.0: a Mac’s bootstrap token")
struct BootstrapTokenTests {
    @Test("Read from the SECURITY section into the group member")
    func security() throws {
        let json = #"{"id":"7","general":{"name":"Test Mac"},"security":{"bootstrapTokenEscrowedStatus":"NOT_ESCROWED","bootstrapTokenAllowed":true}}"#
        let computer = try JSONDecoder().decode(JamfPro.Computer.self, from: Data(json.utf8))
        let member = try #require(JamfPro.GroupMember(computer: computer))
        #expect(member.bootstrapTokenEscrowedStatus == "NOT_ESCROWED")
        #expect(member.bootstrapTokenAllowed == true)
        // without the section nothing changes
        let plain = try JSONDecoder().decode(JamfPro.Computer.self, from: Data(#"{"id":"8"}"#.utf8))
        #expect(plain.security == nil)
    }
}

@Suite("1.5.0: Apple’s postings of a release")
struct PostingTests {
    // as Apple posted macOS 27.2: one general build, posted to the public
    // catalog later than its first date, and two builds for a few Macs
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-11-05","SupportedDevices":["J314sAP","J413AP","J613AP"]},
       {"ProductVersion":"27.2","Build":"26B8125","PostingDate":"2026-11-05","SupportedDevices":["J773sAP"]}],
     "iOS":[{"ProductVersion":"27.1","Build":"24B100","PostingDate":"2026-11-02","SupportedDevices":["iPad14,8"]}]},
     "AssetSets":{"macOS":[
       {"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-10-26","SupportedDevices":["J314sAP","J413AP","J613AP"]},
       {"ProductVersion":"27.0.1","Build":"26A434","PostingDate":"2026-09-28","SupportedDevices":["J314sAP","J413AP","J613AP"]}]}}
    """#
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2","Build":"26B8125","ReleaseDate":"2026-10-26T00:00:00Z"}}],
     "Models":{"MacBookPro18,3":{"OSVersions":[27]}},"Devices":{"J314sAP":{"DeviceID":"MacBookPro18,3"}}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofa.utf8), gdmf: Data(gdmf.utf8))

    @Test("Every GDMF entry is kept; the release date is the first any source gives")
    func kept() throws {
        let release = try #require(Self.catalog.release(OSVersion("27.2")!, .macOS))
        #expect(release.postings.count == 3)
        #expect(release.postings.filter(\.isPublic).count == 2)
        #expect(release.releaseDate == JamfPro.serverDate("2026-10-26T00:00:00", timeZone: .gmt))
    }

    @Test("The public posting meant for the device: by its device ID, its model, else the general one")
    func perDevice() throws {
        let release = try #require(Self.catalog.release(OSVersion("27.2")!, .macOS))
        let fifth = JamfPro.serverDate("2026-11-05T00:00:00", timeZone: .gmt)
        #expect(Self.catalog.publicPosting(of: release, model: nil, boardID: "J773sAP")?.build == "26B8125")
        #expect(Self.catalog.publicPosting(of: release, model: "MacBookPro18,3", boardID: nil)?.build == "26B123")
        // an Intel Mac reporting X86LEGACYAP: the posting for most devices
        let unknown = Self.catalog.publicPosting(of: release, model: "MacBookPro16,1", boardID: "X86LEGACYAP")
        #expect(unknown?.build == "26B123" && unknown?.date == fifth)
        // the build meant for the device, not the one SOFA names
        #expect(Self.catalog.build(of: release, model: "MacBookPro18,3", boardID: "J314sAP") == "26B123")
    }

    @Test("No public posting: nil, so the caller falls back to the release date")
    func noPublicPosting() throws {
        let release = try #require(Self.catalog.release(OSVersion("27.0.1")!, .macOS))
        #expect(Self.catalog.publicPosting(of: release, model: "MacBookPro18,3", boardID: "J314sAP") == nil)
        #expect(release.releaseDate == JamfPro.serverDate("2026-09-28T00:00:00", timeZone: .gmt))
    }
}
