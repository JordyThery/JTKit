import Foundation

/// The Jamf Platform API (`{region}.api.jamfcloud.com`): its client, error
/// reading, waiting for jobs, permission checks, paging, Blueprints, device
/// groups and environments.
///
/// Everything lives under this name so it never collides with the apps' own
/// copies (`PlatformClient`, `PlatformGroup`, `Poll`, …) before they adopt it.
public nonisolated enum JamfPlatform {
    /// Where a client's requests go.
    public enum Server: Sendable, Hashable {
        /// The Jamf Platform API gateway; paths are sent as they are.
        case platformAPI
        /// A Jamf Pro server reached directly, for tenants without Platform
        /// API access: `pro/…` goes to `api/…`, `proclassic/…` to
        /// `JSSResource/…`, and Platform-only paths are refused.
        case jamfPro
    }

    /// Reads the API's ISO 8601 timestamps, with or without fractional seconds.
    public static func date(from string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }

    /// Percent-encodes an ID for one segment of a request path: a `/` in it is
    /// encoded too, so it can't reach another resource.
    public static func pathSegment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}
