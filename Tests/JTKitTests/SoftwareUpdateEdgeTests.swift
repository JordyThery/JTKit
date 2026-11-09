import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

// 1.5.0: the edges of the software update readers: version strings only,
// releases for some devices only, daylight saving, a membership that
// repeats its pages, a status report that isn’t JSON. Made-up data only.

private func platform(_ server: MockServer) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!,
                            scope: .environment("0c6c4f86-1111-4a3c-9d7e-2f1b3c4d5e6f"), tokens: FixedToken("tok"),
                            recorder: RequestRecorder(session: server.session, log: nil), sleep: { _ in }, random: { 0 })
}

@Suite("1.5.0: version strings only")
struct OSVersionStrictTests {
    @Test("Builds, model identifiers, four parts and trailing words aren’t versions",
          arguments: ["23A344", "iPad13,18", "Mac14,2", "1.2.3.4", "27.1 beta", "27.", ".27", "v27", "27.1-rc"])
    func notVersions(_ text: String) {
        #expect(OSVersion(text) == nil)
    }

    @Test("Names before a version and a Rapid Security Response’s letter after it are read")
    func versions() {
        #expect(OSVersion(" 27.0.1 ") == OSVersion(major: 27, minor: 0, patch: 1))
        #expect(OSVersion("macOS Golden Gate 27.2") == OSVersion(major: 27, minor: 2))
        #expect(OSVersion("Sequoia 15")?.major == 15)
        #expect(OSVersion("26.3.1 (a)")?.extra == "(a)")
        #expect(OSVersion("26.3.1(a)")?.extra == "(a)")
    }

    @Test("Two-digit parts compare by number")
    func numeric() throws {
        #expect(try #require(OSVersion("26.7.10")) > #require(OSVersion("26.7.2")))
        #expect(try #require(OSVersion("27.10")) > #require(OSVersion("27.9")))
    }
}

@Suite("1.5.0: releases for some devices only")
struct DeviceSpecificReleaseTests {
    static let sofaIOS = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.0.2","Build":"24A300","ReleaseDate":"2026-10-20T00:00:00Z","SupportedDevices":["iPhone18,1"]},
      "SecurityReleases":[{"ProductVersion":"27.0.2","Build":"24A300","ReleaseDate":"2026-10-20T00:00:00Z"},
                          {"ProductVersion":"27.0.1","Build":"24A200","ReleaseDate":"2026-10-01T00:00:00Z"}]}]}
    """#
    static let gdmf = #"""
    {"PublicAssetSets":{"iOS":[
      {"ProductVersion":"27.0.2","Build":"24A300","PostingDate":"2026-10-20","SupportedDevices":["iPhone18,1"]},
      {"ProductVersion":"27.0.1","Build":"24A200","PostingDate":"2026-10-01","SupportedDevices":["iPhone17,1","iPhone18,1"]}],
     "macOS":[{"ProductVersion":"27.1","Build":"26B100","PostingDate":"2026-10-20","SupportedDevices":["J413AP"]}]}}
    """#
    static let sofaMacOS = #"{"OSVersions":[],"Models":{"Mac14,2":{"OSVersions":[27]}},"Devices":{"J413AP":{"DeviceID":"Mac14,2"}}}"#

    @Test("A release’s own device list decides, when the device is known")
    func perRelease() throws {
        let catalog = try AppleReleases.Catalog(sofaIOS: Data(Self.sofaIOS.utf8), sofaMacOS: Data(Self.sofaMacOS.utf8),
                                                gdmf: Data(Self.gdmf.utf8))
        let newest = try #require(catalog.release(OSVersion("27.0.2")!, .iOS))
        let previous = try #require(catalog.release(OSVersion("27.0.1")!, .iOS))
        #expect(catalog.supports(release: newest, model: "iPhone18,1", boardID: nil) == true)
        #expect(catalog.supports(release: newest, model: "iPhone17,1", boardID: nil) == false)
        #expect(catalog.supports(release: previous, model: "iPhone17,1", boardID: nil) == true)
        // a model no list knows: only the major can be checked
        #expect(catalog.supports(release: newest, model: "iPhone99,9", boardID: nil) == nil)
        // a Mac by its model, through its board ID
        let mac = try #require(catalog.release(OSVersion("27.1")!, .macOS))
        #expect(catalog.supports(release: mac, model: "Mac14,2", boardID: nil) == true)
        // the major still says both models run 27
        #expect(catalog.supports(model: "iPhone17,1", major: 27, .iOS) == true)
    }

    @Test("A release without a device list can’t be checked per device")
    func noList() {
        let release = AppleReleases.Release(platform: .iOS, version: OSVersion("27.0.1")!)
        #expect(AppleReleases.Catalog().supports(release: release, model: "iPhone17,1", boardID: nil) == nil)
    }
}

@Suite("1.5.0: daylight saving")
struct DaylightSavingTests {
    let brussels = TimeZone(identifier: "Europe/Brussels")!

    @Test("A deadline on the day the clocks go back is that day’s local time")
    func deadlineOnChangeDay() throws {
        // 25 October 2026: Brussels goes from UTC+2 to UTC+1 at 03:00
        let deadline = try #require(JamfPlatform.SoftwareUpdateBlock.deadline("2026-10-25T17:00:00", in: brussels))
        #expect(deadline == JamfPro.serverDate("2026-10-25T16:00:00", timeZone: .gmt))
        let before = try #require(JamfPlatform.SoftwareUpdateBlock.deadline("2026-10-24T17:00:00", in: brussels))
        #expect(deadline.timeIntervalSince(before) == 25 * 3_600)
    }

    @Test("A time that occurs twice is read as one of them; a time that doesn’t exist is near it or nil")
    func ambiguous() throws {
        let twice = try #require(JamfPro.serverDate("2026-10-25T02:30:00", timeZone: brussels))
        let first = try #require(JamfPro.serverDate("2026-10-25T00:30:00", timeZone: .gmt))
        #expect(twice == first || twice == first.addingTimeInterval(3_600))
        // 29 March 2026: 02:30 doesn't exist in Brussels
        if let skipped = JamfPro.serverDate("2026-03-29T02:30:00", timeZone: brussels) {
            let near = try #require(JamfPro.serverDate("2026-03-29T01:00:00", timeZone: .gmt))
            #expect(abs(skipped.timeIntervalSince(near)) <= 3_600)
        }
    }
}

@Suite("1.5.0: odd answers")
struct OddAnswerTests {
    @Test("A membership that repeats the same full page stops after the first, without duplicates")
    func repeatedPages() async throws {
        let server = MockServer { request in
            if request.path.contains("group-membership") {
                // 100 members, neither totalCount nor hasNext, whatever page is asked for
                let records = (1...100).map { #"{"mobileDeviceId":"\#($0)","managementId":"M-\#($0)"}"# }
                return .json(200, #"{"results":[\#(records.joined(separator: ","))]}"#)
            }
            return .json(404, "{}")
        }
        let members = try await platform(server).members(of: .init(groupID: "7", name: "G", isSmart: true, kind: .mobileDevice))
        #expect(members.count == 100)
        #expect(Set(members.map(\.id)).count == 100)
        #expect(server.requests.filter { $0.path.contains("group-membership") }.count == 2)
    }

    @Test("A status report that isn’t JSON is an error for that device only")
    func malformedStatus() async throws {
        let server = MockServer { request in
            request.path.contains("/M-1/") ? .json(200, "not json") : .json(200, #"{"statusItems":[]}"#)
        }
        let client = try platform(server)
        await #expect(throws: JamfPlatform.APIError.self) {
            try await client.softwareUpdateStatus(managementID: "M-1", kind: .mobileDevice)
        }
        #expect(try await client.softwareUpdateStatus(managementID: "M-2", kind: .mobileDevice)?.itemCount == 0)
    }
}
