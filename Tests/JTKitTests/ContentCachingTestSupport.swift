import Foundation
import JTKitTestSupport
@testable import JTKit

/// The content caching fixtures (`Fixtures/content-caching`): answers saved
/// from a macOS 27 test Mac with a content cache Blueprint, anonymized
/// (every name, serial, UDID, GUID, address, management ID, Blueprint and
/// declaration ID and server token replaced by a placeholder; shapes,
/// value formats and times kept).
enum CacheFixture {
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/content-caching/\(name)"))
    }

    static func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }

    /// The test Mac’s inventory record (`GENERAL` and `CONTENT_CACHING`).
    static func computer() throws -> JamfPro.Computer {
        struct Page: Decodable { let results: [JamfPro.Computer] }
        return try JSONDecoder().decode(Page.self, from: try data("inventory-page.json")).results[0]
    }

    /// The test Mac’s status items, as `statusItems(managementID:kind:)` gives them.
    static func statusItems() throws -> [JamfPro.StatusItem] {
        let json = try LosslessJSON(data: try data("status-items.json"))
        return (json["statusItems"]?.arrayValue ?? []).compactMap { item in
            item["key"]?.stringValue.map { JamfPro.StatusItem(key: $0, value: item["value"]?.stringValue, lastUpdateTime: item["lastUpdateTime"]?.stringValue) }
        }
    }

    static func blueprint() throws -> JamfPlatform.BlueprintDetail {
        try JamfPlatform.BlueprintDetail(data: try data("blueprint.json"))
    }

    static let blueprintID = "00000000-0000-4000-8000-0000000000b1"
    static let managementID = "00000000-0000-4000-8000-0000000000a1"
    static let utc = TimeZone(identifier: "UTC")!

    static func date(_ text: String) -> Date { JamfPlatform.date(from: text)! }

    /// A Platform client on a mock server.
    static func client(_ server: MockServer, maxConcurrent: Int? = nil) throws -> JamfPlatform.Client {
        try JamfPlatform.Client(baseURL: URL(string: "https://us.api.jamfcloud.com")!,
                                scope: .environment("6f2b3c1d-0000-4000-8000-000000000001"), tokens: FixedToken("tok"),
                                recorder: RequestRecorder(session: server.session, log: nil), maxConcurrent: maxConcurrent)
    }
}
