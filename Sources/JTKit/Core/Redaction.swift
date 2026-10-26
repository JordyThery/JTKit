import Foundation

/// Hides secrets before anything is logged, shown or exported: headers, form
/// fields, JSON at any depth, Classic API XML elements, free text and the
/// query of an address.
///
/// The key lists are AppSettings2Blueprint's and Checkpoint's together. They
/// are a backstop: the real protection is that request bodies are never
/// recorded unless an app marks a request as safe (`HTTPRequest.recordsBodies`),
/// and that sensitive calls are never recorded at all (`SensitiveRequests`).
public nonisolated enum Redaction {
    public static let placeholder = "<redacted>"

    /// Keys whose values are secrets, matched exactly, ignoring case.
    static let secretKeys: Set<String> = Set([
        "access_token", "refresh_token", "id_token", "token",
        "client_secret", "client_assertion", "assertion",
        "password", "secret", "passcode",
        "personalRecoveryKey", "recoveryLockPassword", "recoveryPassword",
        "pin", "unlockToken", "escrowToken",
    ].map { $0.lowercased() })

    /// Keys whose whole value is replaced as one block: personal information
    /// about a person or a place (Checkpoint), and Jamf Pro extension
    /// attributes, which hold whatever an administrator's script reports and
    /// so can hold a secret no key list finds.
    static let personalKeys: Set<String> = Set([
        "owner", "notes", "userAndLocation", "location",
        "actorName", "actorId", "subjectName",
        "extensionAttributes", "extension_attributes",
    ].map { $0.lowercased() })

    /// Headers hidden entirely, except that Authorization and
    /// Proxy-Authorization keep their scheme ("Bearer <redacted>").
    static let secretHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie"]

    static func isSecretKey(_ key: String) -> Bool { secretKeys.contains(key.lowercased()) }
    static func isPersonalKey(_ key: String) -> Bool { personalKeys.contains(key.lowercased()) }

    // MARK: Headers

    /// One header value, redacted when it carries a secret. A cookie's first
    /// part is the secret itself, so cookies are hidden whole.
    public static func headerValue(name: String, value: String) -> String {
        let lowered = name.lowercased()
        guard secretHeaders.contains(lowered) else { return value }
        if lowered == "authorization" || lowered == "proxy-authorization" {
            let parts = value.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { return "\(parts[0]) \(placeholder)" }
        }
        return placeholder
    }

    /// Every header, redacted, sorted by name.
    public static func headers(_ headers: [String: String]) -> [HTTPHeader] {
        headers
            .map { HTTPHeader(name: $0.key, value: headerValue(name: $0.key, value: $0.value)) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: Addresses

    /// The address with the values of secret query parameters hidden.
    /// Text, not a URL: the placeholder isn't valid in an address.
    public static func url(_ url: URL) -> String {
        let string = url.absoluteString
        guard let questionMark = string.firstIndex(of: "?") else { return string }
        var query = String(string[string.index(after: questionMark)...])
        var fragment = ""
        if let hash = query.firstIndex(of: "#") {
            fragment = String(query[hash...])
            query = String(query[..<hash])
        }
        return String(string[...questionMark]) + formFields(query) + fragment
    }

    // MARK: Bodies

    /// A body as readable text, with secrets hidden: JSON at any depth, form
    /// fields, XML elements, or free text. Nil for an empty body.
    public static func body(_ data: Data, contentType: String? = nil) -> String? {
        guard !data.isEmpty else { return nil }
        let type = contentType?.lowercased() ?? ""
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let cleaned = scrubbed(object)
            if let pretty = try? JSONSerialization.data(
                withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
            ), let text = String(data: pretty, encoding: .utf8) {
                return text
            }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return "(\(data.count) bytes, not text)"
        }
        if type.contains("x-www-form-urlencoded") || looksLikeForm(text) {
            return formFields(text)
        }
        return Self.text(text)
    }

    /// Free text (an error message, an XML document, a log line) with secrets
    /// hidden: `Bearer …` and `Basic …` credentials, `"key": "value"` pairs,
    /// `key=value` pairs and `<key>value</key>` elements for every secret key.
    public static func text(_ text: String) -> String {
        var result = text
        for (regex, template) in textPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// `a=1&client_secret=x` with secret field values hidden. Names are
    /// compared after percent-decoding.
    static func formFields(_ text: String) -> String {
        text.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            guard let equals = pair.firstIndex(of: "=") else { return String(pair) }
            let name = String(pair[..<equals])
            let decoded = (name.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? name)
            return isSecretKey(decoded) ? "\(name)=\(placeholder)" : String(pair)
        }.joined(separator: "&")
    }

    private static func looksLikeForm(_ text: String) -> Bool {
        text.wholeMatch(of: /[A-Za-z0-9_.\-%+]+=[^&\s]*(&[A-Za-z0-9_.\-%+]+=[^&\s]*)*/) != nil
    }

    /// Replaces secret and personal values in parsed JSON, at any depth.
    static func scrubbed(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result = [String: Any]()
            for (key, inner) in dictionary {
                if isSecretKey(key) || isPersonalKey(key) {
                    result[key] = (inner is NSNull) ? inner : placeholder
                } else {
                    result[key] = scrubbed(inner)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map(scrubbed)
        }
        return value
    }

    private static let textPatterns: [(NSRegularExpression, String)] = {
        let keys = secretKeys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let specs: [(String, String)] = [
            // "client_secret": "…"
            (#"("(?:\#(keys))"\s*:\s*")(?:[^"\\]|\\.)*(")"#, "$1\(placeholder)$2"),
            // <password>…</password>, also with attributes
            (#"(<(\#(keys))(?:\s[^>]*)?>)[^<]*(</\2\s*>)"#, "$1\(placeholder)$3"),
            // client_secret=… in a form or a query
            (#"((?<![A-Za-z0-9_])(?:\#(keys))=)[^&\s"']+"#, "$1\(placeholder)"),
            // Authorization values
            (#"((?:Bearer|Basic)\s+)[A-Za-z0-9\-._~+/]+=*"#, "$1\(placeholder)"),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, template) }
        }
    }()
}

/// One HTTP header as recorded in the activity log.
public nonisolated struct HTTPHeader: Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// `application/x-www-form-urlencoded` and strict query encoding: only RFC 3986
/// unreserved characters pass through, so `+`, `&`, `=` and quotes in values
/// (secrets, RSQL filters) can't change the meaning of a request.
public nonisolated enum FormEncoding {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    public static func encode(_ items: [URLQueryItem]) -> String {
        items.map { "\(encode($0.name))=\(encode($0.value ?? ""))" }.joined(separator: "&")
    }
}
