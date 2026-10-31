import Foundation

extension JamfPlatform {
    /// One page of a Platform API list: `{results, totalCount?, hasNext?}`.
    public struct Page<Item: Sendable>: Sendable {
        public var results: [Item]
        public var totalCount: Int?
        public var hasNext: Bool?
        /// Results that couldn’t be read (e.g. without an ID); they still count
        /// towards the end of the list.
        public var unreadableCount: Int

        public init(results: [Item], totalCount: Int? = nil, hasNext: Bool? = nil, unreadableCount: Int = 0) {
            self.results = results
            self.totalCount = totalCount
            self.hasNext = hasNext
            self.unreadableCount = unreadableCount
        }

        /// Reads a page; `item` returns nil for a result it can’t read.
        public init(json: LosslessJSON, item: (LosslessJSON) -> Item?) throws {
            guard let raw = json["results"]?.arrayValue else {
                throw JamfPlatform.APIError(.invalidResponse("The list has no \"results\" array."))
            }
            let parsed = raw.compactMap(item)
            self.init(results: parsed,
                      totalCount: json["totalCount"]?.numberValue?.intValue,
                      hasNext: json["hasNext"]?.boolValue,
                      unreadableCount: raw.count - parsed.count)
        }
    }

    /// Whether another page follows, by the rules every app uses: an empty page
    /// ends the list; then `hasNext` when the server sends it; then
    /// `totalCount`; without either, a short page.
    static func hasMore<Item>(after page: Page<Item>, received: Int, pageSize: Int) -> Bool {
        let count = page.results.count + page.unreadableCount
        if count == 0 { return false }
        if let hasNext = page.hasNext { return hasNext }
        if let total = page.totalCount { return received < total }
        return count >= pageSize
    }

    /// Reads every page, from page 0. Reaching `maxPages` with more to come is
    /// an error, never a quiet cut-off.
    ///
    /// - Parameter fetch: reads one page (zero-based).
    public static func allPages<Item: Sendable>(
        of path: String,
        pageSize: Int,
        maxPages: Int = 1_000,
        fetch: (Int) async throws -> Page<Item>
    ) async throws -> [Item] {
        var items = [Item]()
        var received = 0
        for page in 0..<max(maxPages, 1) {
            try Task.checkCancellation()
            let result = try await fetch(page)
            items += result.results
            received += result.results.count + result.unreadableCount
            if !hasMore(after: result, received: received, pageSize: pageSize) { return items }
        }
        throw JamfPlatform.APIError(.pageLimitReached(path: path, pages: maxPages))
    }
}

extension JamfPlatform.Client {
    /// Every item of a paged list (`page`, `page-size` and the given query).
    public func allPages<Item: Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        pageSize: Int = 100,
        maxPages: Int = 1_000,
        privilege: JamfPro.Privilege? = nil,
        item: @escaping @Sendable (LosslessJSON) -> Item?
    ) async throws -> [Item] {
        try await allPages(path, query: query, pageSize: pageSize, maxPages: maxPages,
                           privileges: privilege.map { [$0] } ?? [], item: item)
    }

    /// As `allPages(_:privilege:)`, for a list that needs several
    /// privileges, all named when Jamf Pro refuses it.
    public func allPages<Item: Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        pageSize: Int = 100,
        maxPages: Int = 1_000,
        privileges: [JamfPro.Privilege],
        item: @escaping @Sendable (LosslessJSON) -> Item?
    ) async throws -> [Item] {
        try await JamfPlatform.allPages(of: path, pageSize: pageSize, maxPages: maxPages) { page in
            try await self.page(path, page: page, pageSize: pageSize, query: query, privileges: privileges, item: item)
        }
    }

    /// One page of a list.
    public func page<Item: Sendable>(
        _ path: String,
        page: Int,
        pageSize: Int,
        query: [URLQueryItem] = [],
        privilege: JamfPro.Privilege? = nil,
        item: (LosslessJSON) -> Item?
    ) async throws -> JamfPlatform.Page<Item> {
        try await self.page(path, page: page, pageSize: pageSize, query: query,
                            privileges: privilege.map { [$0] } ?? [], item: item)
    }

    /// One page of a list that needs several privileges.
    public func page<Item: Sendable>(
        _ path: String,
        page: Int,
        pageSize: Int,
        query: [URLQueryItem] = [],
        privileges: [JamfPro.Privilege],
        item: (LosslessJSON) -> Item?
    ) async throws -> JamfPlatform.Page<Item> {
        let paging = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "page-size", value: String(pageSize))]
        return try JamfPlatform.Page(json: try await json(path, query: paging + query, privileges: privileges), item: item)
    }
}
