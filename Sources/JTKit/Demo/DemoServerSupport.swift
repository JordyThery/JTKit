import Foundation

/// Small helpers shared by the demo servers.
nonisolated enum DemoJSON {
    /// `value` (dictionaries, arrays, strings, numbers, booleans, `NSNull`) as a JSON answer.
    static func response(_ status: Int, _ value: Any) -> DemoResponse {
        let body = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return DemoResponse(status: status, body: body)
    }

    /// An answer without a body, e.g. 204.
    static func empty(_ status: Int) -> DemoResponse {
        DemoResponse(status: status, headers: [:], body: Data())
    }

    static func object(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// A form-encoded body, decoded.
    static func form(_ body: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }

    /// The bearer token of a request, if any.
    static func bearer(_ request: DemoRequest) -> String? {
        let header = request.headers.first { $0.key.lowercased() == "authorization" }?.value ?? ""
        return header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : nil
    }

    /// A header, whatever its case.
    static func header(_ name: String, in request: DemoRequest) -> String? {
        request.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}
