import Foundation

extension JamfPlatform {
    /// How long to wait between checks on a job (a deployment, a sync), and
    /// when to stop. The same in every app: from 2 s, growing ×1.5 to 10 s,
    /// for at most 5 minutes; an app may set a shorter limit.
    public struct PollingPolicy: Sendable, Hashable {
        public var firstInterval: Duration
        public var growth: Double
        public var longestInterval: Duration
        public var timeLimit: Duration

        public static let standard = PollingPolicy()

        public init(
            firstInterval: Duration = .seconds(2),
            growth: Double = 1.5,
            longestInterval: Duration = .seconds(10),
            timeLimit: Duration = .seconds(300)
        ) {
            self.firstInterval = firstInterval
            self.growth = growth
            self.longestInterval = longestInterval
            self.timeLimit = timeLimit
        }

        /// The wait after check 1, 2, …
        public func interval(afterCheck check: Int) -> Duration {
            var interval = firstInterval
            for _ in 1..<max(check, 1) {
                interval = min(interval * growth, longestInterval)
            }
            return min(interval, longestInterval)
        }
    }

    /// The end of a wait for a job.
    public enum PollOutcome<Value: Sendable>: Sendable {
        /// The job got where it was going.
        case finished(Value)
        /// The time limit came first; the last value seen, if any. The job
        /// itself may carry on in Jamf.
        case timedOut(last: Value?)

        /// The value of a finished job, or the last one seen.
        public var value: Value? {
            switch self {
            case .finished(let value): value
            case .timedOut(let last): last
            }
        }

        public var isFinished: Bool {
            if case .finished = self { return true }
            return false
        }
    }

    /// Checks on a job until it is done or the time limit is reached. Cancel
    /// (canceling the task) stops it at once, also during a wait.
    public struct Poller: Sendable {
        public var policy: PollingPolicy
        private let sleep: @Sendable (Duration) async throws -> Void
        private let now: @Sendable () -> ContinuousClock.Instant

        /// - Parameters:
        ///   - sleep, now: injectable for tests; a test’s `sleep` can move its `now` on.
        public init(
            policy: PollingPolicy = .standard,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
        ) {
            self.policy = policy
            self.sleep = sleep
            self.now = now
        }

        /// - Parameters:
        ///   - check: one look at the job.
        ///   - isDone: whether the job got where it was going.
        ///   - isNotReadyYet: errors that mean "not there yet" (e.g. a 404 just
        ///     after a create); they are checked again. Any other error stops
        ///     the wait and is thrown.
        ///   - progress: called with each value seen.
        public func poll<Value: Sendable>(
            check: @Sendable () async throws -> Value,
            isDone: @Sendable (Value) -> Bool,
            isNotReadyYet: @Sendable (any Error) -> Bool = { _ in false },
            progress: @Sendable (Value) async -> Void = { _ in }
        ) async throws -> PollOutcome<Value> {
            let deadline = now() + policy.timeLimit
            var last: Value?
            var checks = 0
            while true {
                try Task.checkCancellation()
                checks += 1
                do {
                    let value = try await check()
                    last = value
                    await progress(value)
                    if isDone(value) { return .finished(value) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error where isNotReadyYet(error) {
                    // not there yet: look again
                }
                let remaining = deadline - now()
                guard remaining > .zero else { return .timedOut(last: last) }
                do {
                    // the last wait ends at the limit, so there is one check at the limit
                    try await sleep(min(policy.interval(afterCheck: checks), remaining))
                } catch {
                    throw CancellationError()
                }
            }
        }
    }
}
