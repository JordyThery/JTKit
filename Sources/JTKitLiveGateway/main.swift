import Foundation
import JTKitLiveCheck

// The release check’s gateway for live UI tests (JTKit 1.1.0, B1): started
// by release-check-lib.sh around each live UI test, with the same settings
// the live tests get (`TEST_RUNNER_JTKIT_LIVE_*`, prefix stripped, or
// without it). Decides every request of the app under -JTKitLiveCheck and of
// the UI test by the release check’s rules (LiveCheckRun, LiveGateway).
// Stops on SIGTERM or SIGINT, and by itself once the release check’s lock is
// released or held by another check. Prints no secret.

var environment: [String: String] = [:]
for (key, value) in ProcessInfo.processInfo.environment where !key.hasPrefix("TEST_RUNNER_") {
    environment[key] = value
}
for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("TEST_RUNNER_") {
    environment[String(key.dropFirst("TEST_RUNNER_".count))] = value
}

func lockOwner() -> String {
    ((try? String(contentsOf: LiveGateway.defaultLockOwnerURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

let gateway: LiveGateway
do {
    let run = try LiveCheckRun(environment: environment)
    gateway = try LiveGateway(run: run)
    print("jtkit-live-gateway: listening on 127.0.0.1:\(gateway.port) for \(run.roles.sorted().joined(separator: ", "))")
} catch {
    FileHandle.standardError.write(Data("jtkit-live-gateway: \(error)\n".utf8))
    exit(1)
}

let owner = lockOwner()
func stop(_ reason: String) -> Never {
    gateway.stop()
    print("jtkit-live-gateway: stopped (\(reason)), \(gateway.handledRequests) requests")
    exit(0)
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
// handlers on the main queue, which the main run loop runs on the main thread
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { stop("SIGTERM") }
terminate.resume()
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { stop("SIGINT") }
interrupt.resume()

let watch = DispatchSource.makeTimerSource(queue: .main)
watch.schedule(deadline: .now() + 2, repeating: 2)
watch.setEventHandler {
    if lockOwner() != owner { stop("the release check’s lock was released") }
}
watch.resume()

// the main run loop drains the main queue on the main thread
RunLoop.main.run()
