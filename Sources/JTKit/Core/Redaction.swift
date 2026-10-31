import Foundation

/// Hides secrets before anything is logged, shown or exported: headers, form
/// fields, JSON at any depth, Classic API XML elements, free text and the
/// query of an address.
///
/// The key lists are a backstop: the real protection is that request bodies are never
/// recorded unless an app marks a request as safe (`HTTPRequest.recordsBodies`),
/// and that sensitive calls are never recorded at all (`SensitiveRequests`).
public nonisolated enum Redaction {
    public static let placeholder = "<redacted>"

    /// Parts of a key that make its value a secret, found anywhere in the
    /// key once it is lowercased without `_`, `-` and `.`: `clientSecret`,
    /// `adminPassword`, `access_token`, `client_assertion`.
    static let secretKeyParts = ["secret", "password", "passwd", "passcode", "token", "assertion"]

    /// Words that make a key’s value a secret only as a whole word of the
    /// key, so `apiKey`, `privateKey`, `lockPIN` and `pin_code` count but
    /// `keyboard` and `shipping` don’t.
    static let secretKeyWords: Set<String> = ["key", "pin"]

    /// Keys whose values are secrets although no part above says so.
    static let secretKeys: Set<String> = Set([
        // Azure Storage upload addresses (SAS) carry their signature here
        "sig",
        // Apple’s signed download addresses (an activity’s CSV): the
        // whole address is a temporary credential, its signature the secret
        "signature", "downloadUrl",
    ].map(normalizedKey))

    /// Keys that look like secrets but name or describe one: kept, so a log
    /// still shows which key was used and when a token expires.
    static let safeKeys: Set<String> = Set([
        "key", "keyID", "publicKey", "tokenType", "token_type", "tokenExpiration", "tokenExpirationEpoch",
        "expirationEpoch", "keyType", "passwordRotationTime", "secretName",
    ].map(normalizedKey))

    /// Lowercased, without `_`, `-`, `.` and spaces.
    static func normalizedKey(_ key: String) -> String {
        String(key.lowercased().filter { !"_-. ".contains($0) })
    }

    /// The key’s words: split at `_`, `-`, `.`, spaces and camel case
    /// (`lockPIN` → lock, pin; `pinCode` → pin, code), lowercased.
    static func keyWords(_ key: String) -> [String] {
        var words = [String]()
        var current = ""
        var previous: Character?
        for character in key {
            if "_-. ".contains(character) {
                if !current.isEmpty { words.append(current) }
                current = ""
                previous = nil
                continue
            }
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                words.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    /// Keys whose whole value is replaced as one block: personal information
    /// about a person or a place (Checkpoint), and Jamf Pro extension
    /// attributes, which hold whatever an administrator’s script reports and
    /// so can hold a secret no key list finds.
    static let personalKeys: Set<String> = Set([
        "owner", "notes", "userAndLocation", "location",
        "actorName", "actorId", "subjectName",
        "extensionAttributes", "extension_attributes",
    ].map { $0.lowercased() })

    /// Headers hidden entirely, except that Authorization and
    /// Proxy-Authorization keep their scheme ("Bearer <redacted>").
    static let secretHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie"]

    /// Over-redacting a log is harmless, so anything that looks like a
    /// secret’s key counts, unless it is one of `safeKeys`.
    static func isSecretKey(_ key: String) -> Bool {
        let normalized = normalizedKey(key)
        guard !normalized.isEmpty, !safeKeys.contains(normalized) else { return false }
        if secretKeys.contains(normalized) { return true }
        if secretKeyParts.contains(where: normalized.contains) { return true }
        return keyWords(key).contains(where: secretKeyWords.contains)
    }
    static func isPersonalKey(_ key: String) -> Bool { personalKeys.contains(key.lowercased()) }

    // MARK: Headers

    /// One header value, redacted when it carries a secret. A cookie’s first
    /// part is the secret itself, so cookies are hidden whole.
    static func headerValue(name: String, value: String) -> String {
        let lowered = name.lowercased()
        guard secretHeaders.contains(lowered) else { return value }
        if lowered == "authorization" || lowered == "proxy-authorization" {
            let parts = value.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { return "\(parts[0]) \(placeholder)" }
        }
        return placeholder
    }

    /// Every header, redacted, sorted by name.
    static func headers(_ headers: [String: String]) -> [HTTPHeader] {
        headers
            .map { HTTPHeader(name: $0.key, value: headerValue(name: $0.key, value: $0.value)) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: Addresses

    /// The address with the values of secret query parameters hidden.
    /// Text, not a URL: the placeholder isn’t valid in an address.
    static func url(_ url: URL) -> String {
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
    static func body(_ data: Data, contentType: String? = nil) -> String? {
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
    /// hidden: `Bearer …` and `Basic …` credentials, GitHub tokens (`ghp_`,
    /// `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`), signed tokens (JWTs,
    /// recognized only by their `eyJ` start, so ordinary text is left alone)
    /// and PEM private keys, also cut short, wherever they appear,
    /// `"key": "value"` pairs, `key=value` pairs and `<key>value</key>`
    /// elements for every secret key.
    public static func text(_ text: String) -> String {
        var result = text
        for pattern in keyedPatterns {
            result = redactingValues(of: pattern, in: result)
        }
        for (regex, template) in textPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// Each match’s value (capture group 2) replaced when its name (group 1)
    /// is a secret’s key.
    private static func redactingValues(of regex: NSRegularExpression, in text: String) -> String {
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1))
            let value = match.range(at: 2)
            guard isSecretKey(name), value.location != NSNotFound else { continue }
            let found = source.substring(with: value).lowercased()
            if found == "true" || found == "false" { continue }
            result += source.substring(with: NSRange(location: last, length: value.location - last)) + placeholder
            last = value.location + value.length
        }
        return result + source.substring(from: last)
    }

    /// Exact values the caller knows are secret (a token it sent), replaced
    /// wherever they appear, also percent-encoded. Longest first, so a value
    /// containing another goes whole.
    static func removing(_ secrets: [String], from text: String) -> String {
        var result = text
        for secret in usableKnownSecrets(secrets) {
            result = result.replacingOccurrences(of: secret, with: placeholder)
            let encoded = FormEncoding.encode(secret)
            if encoded != secret { result = result.replacingOccurrences(of: encoded, with: placeholder) }
        }
        return result
    }

    /// Known secrets worth looking for: 8 characters or more, longest first.
    static func usableKnownSecrets(_ secrets: [String]) -> [String] {
        Array(Set(secrets.filter { $0.count >= 8 })).sorted { $0.count > $1.count }
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
                    // A yes/no can’t hold a secret (`passcodePresent`); a
                    // number can (a PIN), so only true and false stay.
                    result[key] = (inner is NSNull || isBoolean(inner)) ? inner : placeholder
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

    /// Whether a parsed JSON value is true or false (not a number).
    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// A name (group 1) and its value (group 2), redacted when the name is
    /// a secret’s key.
    private static let keyedPatterns: [NSRegularExpression] = [
        // "client_secret": "…"
        #""([A-Za-z0-9_.\-]+)"\s*:\s*"((?:[^"\\]|\\.)*)""#,
        // <password>…</password>, also with attributes
        #"<([A-Za-z0-9_.\-]+)(?:\s[^>]*)?>([^<]*)</\1\s*>"#,
        // client_secret=… in a form or a query
        #"(?<![A-Za-z0-9_.\-])([A-Za-z0-9_.\-]+)=([^&\s"']+)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let textPatterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // Authorization values
            (#"((?:Bearer|Basic)\s+)[A-Za-z0-9\-._~+/]+=*"#, "$1\(placeholder)"),
            // GitHub tokens are recognizable by their prefix alone
            (#"(?<![A-Za-z0-9_])(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]+"#, placeholder),
            // A PEM private key, whole or cut short (Apple Business and Apple
            // School Manager’s key); JSON writes its line breaks as \n
            (#"-----BEGIN ([A-Z ]*)PRIVATE KEY-----(?:[\s\S]*?-----END \1PRIVATE KEY-----|[A-Za-z0-9+/=\s\\]*)"#, placeholder),
            // A signed token (JWT) or what is left of one: its header and
            // payload are base64url JSON, so they start with "eyJ" (matched
            // case-sensitively); the parts after it go too
            (#"(?<![A-Za-z0-9_-])(?-i:eyJ)[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]*){0,2}"#, placeholder),
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
/// (secrets, RSQL filters) can’t change the meaning of a request.
nonisolated enum FormEncoding {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    public static func encode(_ items: [URLQueryItem]) -> String {
        items.map { "\(encode($0.name))=\(encode($0.value ?? ""))" }.joined(separator: "&")
    }
}
