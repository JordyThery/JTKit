import Foundation

/// What a Microsoft access token says about itself. Only its claims are
/// read; the signature isn’t checked (Microsoft checks it), so use this to
/// refuse a token for the wrong tenant, never to trust one.
public nonisolated enum EntraToken {
    /// The tenant the token was issued for (its `tid` claim), lowercased;
    /// nil when the token isn’t a JWT or has none. For a guest account this
    /// is the tenant signed in to, not the account’s home tenant.
    public static func tenantID(ofAccessToken token: String) -> String? {
        guard let tenant = claims(ofAccessToken: token)?["tid"] as? String else { return nil }
        let trimmed = tenant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func claims(ofAccessToken token: String) -> [String: Any]? {
        var raw = Substring(token.trimmingCharacters(in: .whitespacesAndNewlines))
        if raw.lowercased().hasPrefix("bearer ") { raw = raw.dropFirst("bearer ".count) }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Comparing Microsoft tenants. A tenant can be typed as its ID or as one
/// of its domains (“contoso.onmicrosoft.com”), so two connections typed
/// differently can be the same tenant: once signed in, the token’s tenant ID
/// decides.
public nonisolated enum EntraTenant {
    /// What to compare: the signed-in tenant ID when known, otherwise the
    /// typed tenant, trimmed and lowercased. Empty when neither is known.
    public static func key(typed: String, signedInTenantID: String? = nil) -> String {
        if let signedIn = signedInTenantID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !signedIn.isEmpty {
            return signedIn
        }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether two connections are for the same tenant: by their signed-in
    /// tenant IDs when both are known, otherwise as typed (ignoring case and
    /// spaces). False when either is empty. A domain and an ID that aren’t
    /// both signed in compare as typed, so they count as different tenants
    /// until both have signed in.
    public static func isSame(typed first: String, signedIn firstTenantID: String? = nil,
                              as second: String, signedIn secondTenantID: String? = nil) -> Bool {
        let a = key(typed: first, signedInTenantID: firstTenantID)
        let b = key(typed: second, signedInTenantID: secondTenantID)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // one signed in, the other typed as its ID, compares by ID too
        return a == b
    }
}

extension Graph.TokenProvider {
    /// The tenant the current token is for (`EntraToken.tenantID`); signs
    /// in when there is no token yet.
    public func tenantID() async throws -> String? {
        EntraToken.tenantID(ofAccessToken: try await token())
    }
}
