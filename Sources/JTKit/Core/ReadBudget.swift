import Foundation

/// So many reads in flight at a time, shared by every task of one step: a
/// read waits for a turn, turns go in the order asked, and canceling the
/// task ends its wait at once without taking a turn.
actor ReadBudget {
    private let limit: Int
    private var inUse = 0
    private var waiting: [(id: UUID, turn: CheckedContinuation<Void, any Error>)] = []

    init(_ limit: Int) {
        self.limit = max(limit, 1)
    }

    /// Runs `work` within the budget.
    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await take()
        defer { give() }
        return try await work()
    }

    private func take() async throws {
        if inUse < limit {
            inUse += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (turn: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    turn.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, turn))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).turn.resume(throwing: CancellationError())
    }

    /// The turn goes straight to the next read waiting, if any.
    private func give() {
        if waiting.isEmpty {
            inUse -= 1
        } else {
            waiting.removeFirst().turn.resume()
        }
    }
}
