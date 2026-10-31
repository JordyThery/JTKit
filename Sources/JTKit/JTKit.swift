import Foundation

/// JTKit: shared code for Jordy Thery’s Mac admin apps.
///
/// See ROADMAP.md for the plan.
public enum JTKit {
    /// Version of this package. Keep in sync with the git tag.
    public static let version = "1.0.0"

    /// "AppName/version", sent as the User-Agent of every request JTKit makes
    /// unless the request sets its own. The name is the app’s bundle name
    /// without spaces (a User-Agent product name can’t contain any), e.g.
    /// "JamfMigrator/1.0.5".
    static let userAgent: String = userAgent(info: Bundle.main.infoDictionary ?? [:])

    static func userAgent(info: [String: Any]) -> String {
        let name = info["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        return "\(name.filter { !$0.isWhitespace })/\(version)"
    }
}

extension URLRequest {
    /// The request with JTKit’s User-Agent, unless it already has one.
    nonisolated func withDefaultUserAgent() -> URLRequest {
        guard value(forHTTPHeaderField: "User-Agent") == nil else { return self }
        var request = self
        request.setValue(JTKit.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
