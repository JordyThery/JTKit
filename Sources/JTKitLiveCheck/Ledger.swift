import Foundation

/// The objects a live-check run created (or that its sweep found), written to
/// disk after every change, so a crash still leaves a cleanup list. Only
/// objects in the ledger may be changed or deleted.
public nonisolated final class Ledger: @unchecked Sendable {
    public nonisolated struct Item: Codable, Sendable, Equatable, Hashable {
        /// Which tenant: a Jamf host, `platform:<environment ID>`,
        /// `intune:<tenant ID>`.
        public var target: String
        /// The kind of object, as in its path, e.g. `"categories"`, `"blueprints"`.
        public var resource: String
        public var id: String
        public var name: String
        public var removed: Bool
        /// Found by the sweep rather than created by this run.
        public var fromSweep: Bool
        /// The guarded network has seen this name on the server: it sent the
        /// object’s create, or read the object back before its first change
        /// or delete. Objects recorded by test code (`recordCreated`,
        /// `adoptForSweep`, an earlier run’s ledger) start unconfirmed.
        public internal(set) var confirmed: Bool
        /// The same object under another API’s type and ID, e.g. a Platform
        /// device group’s Classic twin (`computergroups/57`), as `resource/id`.
        public internal(set) var aliases: [String]

        public init(target: String, resource: String, id: String, name: String, removed: Bool = false, fromSweep: Bool = false) {
            self.init(target: target, resource: resource, id: id, name: name, removed: removed, fromSweep: fromSweep,
                      confirmed: false)
        }

        init(target: String, resource: String, id: String, name: String, removed: Bool = false, fromSweep: Bool = false,
             confirmed: Bool, aliases: [String] = []) {
            self.target = target.lowercased()
            self.resource = Ledger.normalized(resource)
            self.id = id
            self.name = name
            self.removed = removed
            self.fromSweep = fromSweep
            self.confirmed = confirmed
            self.aliases = aliases
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(target: try container.decode(String.self, forKey: .target),
                      resource: try container.decode(String.self, forKey: .resource),
                      id: try container.decode(String.self, forKey: .id),
                      name: try container.decode(String.self, forKey: .name),
                      removed: try container.decodeIfPresent(Bool.self, forKey: .removed) ?? false,
                      fromSweep: try container.decodeIfPresent(Bool.self, forKey: .fromSweep) ?? false,
                      confirmed: try container.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false,
                      aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [])
        }

        /// Whether `resource`/`id` names this object, under its own key or an alias.
        func matches(resource: String, id: String) -> Bool {
            let resource = Ledger.normalized(resource)
            if self.resource == resource && self.id.lowercased() == id.lowercased() { return true }
            return aliases.contains(Ledger.aliasKey(resource: resource, id: id))
        }
    }

    public nonisolated enum LedgerError: Error, Equatable, CustomStringConvertible {
        case notATestObject(String)
        /// The ledger file couldn’t be written (or read when it was opened):
        /// creates are refused from then on.
        case unsaved(String)
        public var description: String {
            switch self {
            case .notATestObject(let name): "“\(name)” isn’t named as a test object, so it can’t be added to the ledger"
            case .unsaved(let reason): "The ledger can’t be saved: \(reason)"
            }
        }
    }

    public let fileURL: URL
    private let lock = NSLock()
    private var storage: [Item]
    private var failure: String?

    /// Opens the ledger at `fileURL`, keeping what an earlier, crashed run
    /// left. A file that exists but can’t be read leaves the ledger empty and
    /// broken (`saveFailure`): nothing is created, and the run fails.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            let data = try Data(contentsOf: fileURL)
            storage = try JSONDecoder().decode([Item].self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            storage = []
        } catch {
            storage = []
            failure = "\(fileURL.lastPathComponent) can’t be read (\(error.localizedDescription))"
        }
    }

    public var items: [Item] { lock.withLock { storage } }

    /// Why the ledger can’t be trusted any more (a failed read or write), or
    /// nil. Once set, the policy refuses every create.
    public var saveFailure: String? { lock.withLock { failure } }

    /// What hasn’t been removed yet, newest first (dependents before what they use).
    public var outstanding: [Item] { items.filter { !$0.removed }.reversed() }

    public func contains(target: String, resource: String, id: String) -> Bool {
        item(target: target, resource: resource, id: id) != nil
    }

    /// The ledger’s entry for an object, under its own key or an alias, the ID
    /// compared without case (Graph’s GUIDs come back in either case).
    public func item(target: String, resource: String, id: String) -> Item? {
        let target = target.lowercased()
        return lock.withLock {
            storage.first { $0.target == target && $0.matches(resource: resource, id: id) }
        }
    }

    /// Records an object; its name must start with a test prefix.
    func add(_ item: Item, testPrefixes: [String]) throws {
        guard testPrefixes.contains(where: { item.name.hasPrefix($0) }) else {
            throw LedgerError.notATestObject(item.name)
        }
        try lock.withLock {
            if !storage.contains(where: { $0.target == item.target && $0.resource == item.resource && $0.id == item.id }) {
                storage.append(item)
            }
            try save()
        }
    }

    /// Marks an object removed; only a delete’s read-back calls it.
    func recordRemoval(target: String, resource: String, id: String) throws {
        try update(target: target, resource: resource, id: id) { $0.removed = true }
    }

    /// Marks an object removed.
    @available(*, deprecated, message: "Only a delete’s read-back marks an object removed; let the cleanup delete it")
    public func markRemoved(target: String, resource: String, id: String) {
        try? recordRemoval(target: target, resource: resource, id: id)
    }

    /// The server showed the object under its ledger name.
    func confirm(target: String, resource: String, id: String) throws {
        try update(target: target, resource: resource, id: id) { $0.confirmed = true }
    }

    /// Records the object under another API’s type and ID as well.
    func addAlias(target: String, resource: String, id: String, aliasResource: String, aliasID: String) throws {
        let alias = Self.aliasKey(resource: aliasResource, id: aliasID)
        try update(target: target, resource: resource, id: id) { item in
            if !item.aliases.contains(alias) { item.aliases.append(alias) }
        }
    }

    private func update(target: String, resource: String, id: String, _ change: (inout Item) -> Void) throws {
        let target = target.lowercased()
        try lock.withLock {
            for index in storage.indices where storage[index].target == target && storage[index].matches(resource: resource, id: id) {
                change(&storage[index])
            }
            try save()
        }
    }

    /// Called with the lock held. A failed write marks the ledger broken.
    private func save() throws {
        if let failure { throw LedgerError.unsaved(failure) }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(storage).write(to: fileURL, options: .atomic)
        } catch {
            let reason = "\(fileURL.lastPathComponent) can’t be written (\(error.localizedDescription))"
            failure = reason
            throw LedgerError.unsaved(reason)
        }
    }

    /// One name per kind of object, whichever API path reached it:
    /// `computer-groups`, `computergroups` and `computerGroups` are the same.
    static func normalized(_ resource: String) -> String {
        resource.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func aliasKey(resource: String, id: String) -> String {
        "\(normalized(resource))/\(id.lowercased())"
    }
}
