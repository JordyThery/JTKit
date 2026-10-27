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

        public init(target: String, resource: String, id: String, name: String, removed: Bool = false, fromSweep: Bool = false) {
            self.target = target.lowercased()
            self.resource = Ledger.normalized(resource)
            self.id = id
            self.name = name
            self.removed = removed
            self.fromSweep = fromSweep
        }
    }

    public nonisolated enum LedgerError: Error, Equatable, CustomStringConvertible {
        case notATestObject(String)
        public var description: String {
            switch self {
            case .notATestObject(let name): "“\(name)” isn't named as a test object, so it can't be added to the ledger"
            }
        }
    }

    public let fileURL: URL
    private let lock = NSLock()
    private var storage: [Item]

    /// Opens the ledger at `fileURL`, keeping what an earlier, crashed run left.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        storage = (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: fileURL))) ?? []
    }

    public var items: [Item] { lock.withLock { storage } }

    /// What hasn't been removed yet, newest first (dependents before what they use).
    public var outstanding: [Item] { items.filter { !$0.removed }.reversed() }

    public func contains(target: String, resource: String, id: String) -> Bool {
        let key = Item(target: target, resource: resource, id: id, name: "")
        return lock.withLock {
            storage.contains { $0.target == key.target && $0.resource == key.resource && $0.id == key.id }
        }
    }

    /// Records an object; its name must start with a test prefix.
    public func add(_ item: Item, testPrefixes: [String]) throws {
        guard testPrefixes.contains(where: { item.name.hasPrefix($0) }) else {
            throw LedgerError.notATestObject(item.name)
        }
        lock.withLock {
            if !storage.contains(where: { $0.target == item.target && $0.resource == item.resource && $0.id == item.id }) {
                storage.append(item)
            }
            save()
        }
    }

    public func markRemoved(target: String, resource: String, id: String) {
        let key = Item(target: target, resource: resource, id: id, name: "")
        lock.withLock {
            for index in storage.indices
            where storage[index].target == key.target && storage[index].resource == key.resource && storage[index].id == key.id {
                storage[index].removed = true
            }
            save()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(storage).write(to: fileURL, options: .atomic)
    }

    /// One name per kind of object, whichever API path reached it:
    /// `computer-groups`, `computergroups` and `computerGroups` are the same.
    static func normalized(_ resource: String) -> String {
        resource.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
