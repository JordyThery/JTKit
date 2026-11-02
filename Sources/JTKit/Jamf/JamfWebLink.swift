import Foundation

/// Links to a record’s page in the Jamf Pro or Jamf School web interface,
/// as Checkpoint, Serial Number Reader and Profile2Blueprint each built them.
/// Jamf Pro pages open read-only (`o=r`), so a click never starts an edit.
/// `base` is the server’s web address, in any form a person pastes; nil when
/// it has no host or is `http://`. A Jamf Pro address keeps its path (an
/// on-premises server under `/jamf`), without a trailing `/api` (1.3.2).
public nonisolated enum JamfWebLink {
    /// `computers.html?id=…&o=r`
    public static func computer(id: String, base: String) -> URL? {
        page(base, "computers.html", id: id)
    }

    /// `mobileDevices.html?id=…&o=r`
    public static func mobileDevice(id: String, base: String) -> URL? {
        page(base, "mobileDevices.html", id: id)
    }

    /// A macOS (`OSXConfigurationProfiles.html`) or mobile
    /// (`iOSConfigurationProfiles.html`) configuration profile, read-only.
    public static func configurationProfile(id: String, mobile: Bool, base: String) -> URL? {
        page(base, mobile ? "iOSConfigurationProfiles.html" : "OSXConfigurationProfiles.html", id: id)
    }

    /// A Blueprint: `view/mfe/blueprints/{id}` on the Jamf Pro web address.
    public static func blueprint(id: String, base: String) -> URL? {
        guard let root = jamfProRoot(base), let segment = pathSegment(id) else { return nil }
        return URL(string: "\(root.absoluteString)/view/mfe/blueprints/\(segment)")
    }

    /// A Jamf School device: `devices/details/{udid}`.
    public static func schoolDevice(udid: String, base: String) -> URL? {
        guard let origin = Connection.serverOrigin(base), let segment = pathSegment(udid) else { return nil }
        return URL(string: "\(origin.absoluteString)/devices/details/\(segment)")
    }

    /// The Jamf Pro web root: the origin plus the address’s path, without a
    /// trailing `/api` or slash.
    static func jamfProRoot(_ base: String) -> URL? {
        guard let origin = Connection.serverOrigin(base) else { return nil }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        var segments = (URLComponents(string: withScheme)?.path ?? "").split(separator: "/").map(String.init)
        if segments.last?.lowercased() == "api" { segments.removeLast() }
        return segments.reduce(origin) { $0.appending(path: $1) }
    }

    private static func page(_ base: String, _ name: String, id: String) -> URL? {
        guard let origin = jamfProRoot(base) else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(url: origin.appending(path: name), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: trimmed), URLQueryItem(name: "o", value: "r")]
        return components?.url
    }

    /// An ID as one path segment; nil for an empty one or one that would
    /// reach another path.
    private static func pathSegment(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return nil }
        return trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
    }
}
