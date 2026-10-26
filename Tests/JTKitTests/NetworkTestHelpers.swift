import Foundation
@testable import JTKit
import JTKitTestSupport

/// A value shared between a test and the fake server's handler.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    @discardableResult
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&stored) }
    }
}

/// Counts calls: `next()` returns 1, 2, 3…
final class Counter: @unchecked Sendable {
    private let count = Locked(0)
    var value: Int { count.value }

    func next() -> Int {
        count.withLock { $0 += 1; return $0 }
    }
}

/// Records waits instead of waiting.
final class SleepLog: @unchecked Sendable {
    private let waits = Locked<[Duration]>([])
    var recorded: [Duration] { waits.value }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        waits.withLock { $0.append(duration) }
    }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let current = Locked(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { current.value }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// The bearer token a client sends, without a sign-in.
struct FixedToken: BearerTokenSource {
    let tokens: Locked<[String]>
    let forgotten = Counter()

    init(_ values: String...) {
        tokens = Locked(values)
    }

    func token() async throws -> String {
        tokens.value.first ?? "token"
    }

    func forgetToken() async {
        _ = forgotten.next()
        tokens.withLock { if $0.count > 1 { $0.removeFirst() } }
    }
}

func tokenJSON(_ token: String, expiresIn: Int = 900) -> String {
    #"{"access_token":"\#(token)","expires_in":\#(expiresIn),"token_type":"Bearer"}"#
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
