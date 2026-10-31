import Foundation
import Testing

/// The release-check template’s functions, run with stubs in a home folder
/// of the test’s own: nothing reaches a tenant, xcodebuild or the Keychain.
@Suite("Release-check template: functions")
struct ReleaseCheckScriptTests {
    private static let template = ReleaseCheckTemplateTests.template

    /// A home folder of the test’s own, with the release check’s folder in it.
    private static func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "rc-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base(home).appending(path: "runs"), withIntermediateDirectories: true)
        return home
    }

    private static func base(_ home: URL) -> URL {
        home.appending(path: "Library/Application Support/JTKit Release Check", directoryHint: .isDirectory)
    }

    /// Runs `body` in zsh with the template loaded and `rc_log` printing only.
    @discardableResult
    private static func zsh(_ body: String, home: URL, appCode: String = "XX") throws -> (status: Int32, output: String) {
        let script = """
        APP_NAME="Test App"; APP_CODE="\(appCode)"
        source "\(template.path)"
        rc_log() { print -r -- "$*" }
        \(body)
        """
        return try ReleaseCheckTemplateTests.run("/bin/zsh", ["-c", script],
                                                 environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path])
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: L2: a test that ran nothing never passes

    private static let zeroTests = """
        Test Suite 'Selected tests' started at 2026-10-30 17:52:56.395.
        Test Suite 'Selected tests' passed at 2026-10-30 17:52:56.396.
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
        ** TEST EXECUTE SUCCEEDED **
        """
    private static let swiftAllSkipped = """
        Test Suite 'Selected tests' passed at 2026-10-30 17:52:56.396.
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
        􀟈  Test run started.
        ​􀙟  Suite "Live: sign in" skipped.
        􀙟  Test signInAndRead() skipped: "JTKIT_LIVE isn’t set"
        􁁛  Test run with 1 test in 1 suite passed after 0.001 seconds.
        ** TEST EXECUTE SUCCEEDED **
        """
    private static let xctestAllSkipped = """
        Test Case '-[App_UITests.DemoSmokeUITests test1Launch]' started.
        /x/DemoSmokeUITests.swift:12: -[App_UITests.DemoSmokeUITests test1Launch] : Test skipped - URL is not set for the test runner
        Test Case '-[App_UITests.DemoSmokeUITests test1Launch]' skipped (0.002 seconds).
        Test Suite 'Selected tests' passed at 2026-10-30 17:53:25.887.
        \t Executed 1 test, with 1 test skipped and 0 failures (0 unexpected) in 0.002 (0.003) seconds
        ** TEST EXECUTE SUCCEEDED **
        """
    private static let swiftMix = """
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
        􀟈  Test run started.
        􀟈  Test tenantA() started.
        􁁛  Test tenantA() passed after 3.1 seconds.
        􀙟  Test tenantB() skipped.
        􁁛  Test run with 2 tests in 1 suite passed after 3.2 seconds.
        ** TEST EXECUTE SUCCEEDED **
        """
    private static let xctestMix = """
        Test Case '-[A.B test1]' passed (1.0 seconds).
        Test Case '-[A.B test2]' skipped (0.0 seconds).
        \t Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 1.0 (1.1) seconds
        """
    /// Serial Number Reader’s sign-in, 2026-10-30: XCTest ran nothing, Swift Testing one test.
    private static let realSwiftPass = """
        Test Suite 'Selected tests' started at 2026-10-30 17:52:56.395.
        Test Suite 'Serial Number Reader Tests.xctest' passed at 2026-10-30 17:52:56.396.
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
        Test Suite 'Selected tests' passed at 2026-10-30 17:52:56.396.
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
        􁁛 Test run with 1 test in 1 suite passed after 3.266 seconds.
        ** TEST EXECUTE SUCCEEDED **
        """
    private static let realXCTestPass = """
        Test Case '-[Serial_Number_Reader_UITests.DemoSmokeUITests test1Launch]' passed (8.933 seconds).
        Test Suite 'DemoSmokeUITests' passed at 2026-10-30 17:53:25.885.
        \t Executed 1 test, with 0 failures (0 unexpected) in 8.933 (8.935) seconds
        Test Suite 'Selected tests' passed at 2026-10-30 17:53:25.887.
        \t Executed 1 test, with 0 failures (0 unexpected) in 8.933 (8.937) seconds
        ** TEST EXECUTE SUCCEEDED **
        """
    private static let unitTestsWithLiveSkipped = """
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
        ​􀙟 Suite "Live: sign in" skipped.
        􀙟 Test signInAndRead() skipped.
        ​􀙟 Test removeTestObjects() skipped.
        􁁛 Test run with 114 tests in 21 suites passed after 8.054 seconds.
        """
    private static let failures = [
        "\t Executed 3 tests, with 1 failure (0 unexpected) in 1.0 (1.1) seconds",
        "􀢄  Test run with 2 tests in 1 suite failed after 0.1 seconds with 1 issue.",
        "\t Executed 1 test, with 0 failures (0 unexpected) in 1.0 (1.1) seconds\n** TEST EXECUTE FAILED **",
    ]

    /// AppSettings2Blueprint’s sign-in, 2026-10-30 (Xcode 27): XCTest names
    /// each case, with no "Executed N tests" line.
    private static let realXCTestCasePass = """
        ** TEST EXECUTE SUCCEEDED **

        Testing started
        Test suite 'LiveSignInTests' started on 'My Mac - AppSettings2Blueprint (90371)'
        Test case 'LiveSignInTests/signInAndRead()' passed on 'My Mac - AppSettings2Blueprint (90371)' (4.259 seconds)
        """
    private static let xctestCaseSkipped = """
        Test case 'LiveSignInTests/signInAndRead()' skipped on 'My Mac - App (1)' (0.001 seconds)
        """
    private static let xctestCaseFailed = """
        Test case 'A/one()' passed on 'My Mac - App (1)' (1.0 seconds)
        Test case 'A/two()' failed on 'My Mac - App (1)' (1.0 seconds)
        """

    /// The template’s result reader on a log: its answer and what it printed.
    /// With `summary`, a result bundle whose summary (from a stand-in for
    /// `xcrun xcresulttool`) is that JSON.
    private static func outcome(_ log: String, allowSkips: Bool = false, summary: String? = nil) throws -> (state: Int, reason: String) {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: "test.log")
        try write(log, to: file)
        let bundle = home.appending(path: "test.xcresult", directoryHint: .isDirectory)
        var setup = ""
        if let summary {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let json = home.appending(path: "summary.json")
            try write(summary, to: json)
            let xcrun = home.appending(path: "bin/xcrun")
            try write("#!/bin/zsh\n[[ \"$*\" == \"xcresulttool get test-results summary --path \(bundle.path)\" ]] || exit 1\ncat \"\(json.path)\"\n", to: xcrun)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: xcrun.path)
            setup = "PATH=\"\(xcrun.deletingLastPathComponent().path):$PATH\""
        }
        let result = try zsh("""
            \(setup)
            reason="$(rc_test_outcome "\(file.path)" \(allowSkips ? 1 : 0) "\(bundle.path)")"; state=$?
            print -r -- "state=$state reason=$reason"
            """, home: home)
        let line = result.output.split(separator: "\n").last.map(String.init) ?? ""
        let state = Int(line.split(separator: " ").first?.dropFirst("state=".count) ?? "") ?? -1
        return (state, line.components(separatedBy: "reason=").last ?? "")
    }

    @Test("A selection that ran 0 tests, or only skipped ones, fails the stage")
    func nothingRanFails() throws {
        #expect(try Self.outcome(Self.zeroTests) == (3, "ran no tests"))
        #expect(try Self.outcome(Self.swiftAllSkipped) == (3, "ran no tests (1 skipped)"))
        #expect(try Self.outcome(Self.xctestAllSkipped) == (3, "ran no tests (1 skipped)"))
        #expect(try Self.outcome(Self.swiftAllSkipped, allowSkips: true).state == 3, "even where skips are expected")
    }

    @Test("A mix with a skip fails, except in the unit tests, where the live checks skip themselves")
    func aSkipFails() throws {
        #expect(try Self.outcome(Self.swiftMix).state == 3)
        #expect(try Self.outcome(Self.xctestMix).state == 3)
        #expect(try Self.outcome(Self.swiftMix, allowSkips: true) == (0, "1 passed, 1 skipped"))
        #expect(try Self.outcome(Self.unitTestsWithLiveSkipped, allowSkips: true) == (0, "112 passed, 2 skipped"))
        #expect(try Self.outcome(Self.unitTestsWithLiveSkipped).state == 3)
    }

    @Test("A real pass of one or more tests passes; failures fail; no result is no result")
    func realResults() throws {
        #expect(try Self.outcome(Self.realSwiftPass) == (0, "1 passed"))
        #expect(try Self.outcome(Self.realXCTestPass) == (0, "1 passed"))
        for log in Self.failures {
            #expect(try Self.outcome(log).state == 3, "\(log)")
        }
        #expect(try Self.outcome("error: the build failed\n** BUILD FAILED **").state == 4)
    }

    @Test("Xcode 27’s per-case lines are read: a pass passes, a skip or a failure doesn’t")
    func perCaseLines() throws {
        #expect(try Self.outcome(Self.realXCTestCasePass) == (0, "1 passed"))
        #expect(try Self.outcome(Self.xctestCaseSkipped) == (3, "ran no tests (1 skipped)"))
        #expect(try Self.outcome(Self.xctestCaseFailed).state == 3)
    }

    @Test("The result bundle’s summary decides, whatever the log says")
    func bundleSummaryFirst() throws {
        func summary(passed: Int, failed: Int, skipped: Int) -> String {
            #"{"passedTests": \#(passed), "failedTests": \#(failed), "skippedTests": \#(skipped), "result": "\#(failed > 0 ? "Failed" : "Passed")"}"#
        }
        #expect(try Self.outcome("", summary: summary(passed: 1, failed: 0, skipped: 0)) == (0, "1 passed"))
        #expect(try Self.outcome(Self.realXCTestPass, summary: summary(passed: 0, failed: 0, skipped: 0)) == (3, "ran no tests"),
                "a log that looks like a pass doesn’t outvote a bundle that ran nothing")
        #expect(try Self.outcome("", summary: summary(passed: 0, failed: 0, skipped: 2)) == (3, "ran no tests (2 skipped)"))
        #expect(try Self.outcome("", summary: summary(passed: 3, failed: 0, skipped: 1)).state == 3)
        #expect(try Self.outcome("", allowSkips: true, summary: summary(passed: 3, failed: 0, skipped: 1)) == (0, "3 passed, 1 skipped"))
        #expect(try Self.outcome(Self.realXCTestPass, summary: summary(passed: 257, failed: 3, skipped: 4)).state == 3)
        #expect(try Self.outcome(Self.realXCTestPass, summary: "not json") == (0, "1 passed"), "an unreadable bundle falls back to the log")
    }

    // MARK: L2, L3, L14: running a selection

    /// A stand-in for xcodebuild: logs its arguments, prints `FAKE_OUTPUT`,
    /// and with `FAKE_STEP` adds a line to the live folder’s results.jsonl.
    private static func fakeXcodebuild(in home: URL) throws -> URL {
        let fake = home.appending(path: "fake-xcodebuild")
        try write("""
            #!/bin/zsh
            print -r -- "$*" >> "$FAKE_CALLS"
            [[ -n "$FAKE_STEP" ]] && print -r -- "{\\"step\\": \\"$FAKE_STEP\\", \\"passed\\": true}" >> "$FAKE_LIVE/results.jsonl"
            print -r -- "$FAKE_OUTPUT"
            exit 0
            """, to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        return fake
    }

    /// Runs `rc_test` with the fake; its answer and the fake’s calls.
    private static func runTest(_ options: String, output: String, step: String = "") throws -> (state: Int, calls: [String]) {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = try fakeXcodebuild(in: home)
        let run = home.appending(path: "run")
        let calls = home.appending(path: "calls")
        try FileManager.default.createDirectory(at: run.appending(path: "logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: run.appending(path: "live"), withIntermediateDirectories: true)
        let quoted = output.replacingOccurrences(of: "'", with: "'\\''")
        let result = try zsh("""
            RC_RUN="\(run.path)" RC_LIVE_DIR="\(run.path)/live" RC_XB=("\(fake.path)") RC_RETRY_WAIT=0 RC_CHECK_ERRORS=()
            export FAKE_CALLS="\(calls.path)" FAKE_LIVE="\(run.path)/live" FAKE_STEP="\(step)" FAKE_OUTPUT='\(quoted)'
            rc_test "App Tests/LiveTests/tenantA()" \(options); print "state=$?"
            """, home: home)
        let state = Int(result.output.components(separatedBy: "state=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
        let made = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        return (state, made.split(separator: "\n").map(String.init))
    }

    @Test("Live steps and the cleanup run once, also without a result; the other selections twice")
    func liveStepsAreNeverRetried() throws {
        #expect(try Self.runTest("--once --results-line", output: "no result here").calls.count == 1)
        #expect(try Self.runTest("--once --cleanup-line", output: "").calls.count == 1)
        let retried = try Self.runTest("", output: "no result here")
        #expect(retried.calls.count == 2 && retried.state == 1)
        #expect(try Self.runTest("", output: Self.zeroTests).calls.count == 1, "a result that fails isn’t retried")

        let source = try String(contentsOf: Self.template, encoding: .utf8)
        #expect(source.contains(#"rc_test "$test" --once --results-line"#))
        #expect(source.contains(#"rc_test "$CLEANUP_TEST" --once --cleanup-line"#))
        #expect(source.contains(#"rc_test "$UNIT_TESTS" --allow-skips"#))
    }

    @Test("A live step must add its line to results.jsonl, and the cleanup its cleanup line")
    func stepLinesAreRequired() throws {
        #expect(try Self.runTest("--once --results-line", output: Self.realSwiftPass).state == 1, "no line")
        #expect(try Self.runTest("--once --results-line", output: Self.realSwiftPass, step: "tenantA: deploy").state == 0)
        #expect(try Self.runTest("--once --cleanup-line", output: Self.realSwiftPass, step: "cleanup: one object").state == 1)
        #expect(try Self.runTest("--once --cleanup-line", output: Self.realSwiftPass, step: "cleanup").state == 0)
        #expect(try Self.runTest("--once --results-line", output: Self.swiftAllSkipped, step: "x").state == 1, "skipped")
    }

    @Test("HOST_KEYCHAIN_TEST’s before and after runs keep their own result bundles")
    func labelsKeepResultBundlesApart() throws {
        let before = try Self.runTest("--label before", output: Self.realSwiftPass)
        let after = try Self.runTest("--label after", output: Self.realSwiftPass)
        #expect(before.calls.first?.contains("App Tests-LiveTests-tenantA().before.1.xcresult") == true)
        #expect(after.calls.first?.contains("App Tests-LiveTests-tenantA().after.1.xcresult") == true)
        let source = try String(contentsOf: Self.template, encoding: .utf8)
        #expect(source.contains(#"rc_test "$HOST_KEYCHAIN_TEST" --label before"#))
        #expect(source.contains(#"rc_test "$HOST_KEYCHAIN_TEST" --label after"#))
    }

    // MARK: L9: one release check at a time

    @Test("A second release check can’t take the lock while the first runs; a killed check leaves no stale lock")
    func lockIsHeldByTheRunningCheck() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = Process()
        first.executableURL = URL(filePath: "/bin/zsh")
        first.arguments = ["-c", """
            APP_NAME="First App"; source "\(Self.template.path)"; rc_log() { print -r -- "$*" }
            rc_lock && sleep 60
            """]
        first.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        try first.run()
        let owner = Self.base(home).appending(path: "state/release-check.lock.owner")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: owner.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }

        let second = try Self.zsh("rc_lock && print TOOK-THE-LOCK", home: home)
        #expect(second.status != 0 && !second.output.contains("TOOK-THE-LOCK"))
        #expect(second.output.contains("Another release check is running on this Mac (First App"), "\(second.output)")

        kill(first.processIdentifier, SIGKILL)
        first.waitUntilExit()
        let third = try Self.zsh("rc_lock && print TOOK-THE-LOCK; rc_unlock", home: home)
        #expect(third.output.contains("TOOK-THE-LOCK"), "\(third.output)")
    }

    @Test("While the lock is held, the exit trap (cleanup and report) still sees a command that failed")
    func exitTrapSeesFailuresUnderTheLock() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appending(path: "trap.zsh")
        try Self.write("""
            APP_NAME="Trap App"; source "\(Self.template.path)"; rc_log() { print -r -- "$*" }
            rc_lock || exit 9
            check() { local v; if v="$(/usr/bin/false)"; then print "TRAP-SAW-SUCCESS"; else print "TRAP-SAW-FAILURE"; fi; v="$(sh -c 'exit 3')"; print "status=$?"; rc_unlock; }
            trap check EXIT
            """, to: script)
        let result = try ReleaseCheckTemplateTests.run("/bin/zsh", [script.path],
                                                       environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path])
        #expect(result.output.contains("TRAP-SAW-FAILURE") && result.output.contains("status=3"), "\(result.output)")
        let again = try Self.zsh("rc_lock && print TOOK-THE-LOCK; rc_unlock", home: home)
        #expect(again.output.contains("TOOK-THE-LOCK"), "rc_unlock frees the lock: \(again.output)")
    }

    // MARK: L6: earlier runs’ ledgers, for every app

    private static func item(_ target: String, _ id: String, _ name: String, removed: Bool = false) -> String {
        #"{"target":"\#(target)","resource":"categories","id":"\#(id)","name":"\#(name)","removed":\#(removed),"fromSweep":false}"#
    }

    private static func prepare(_ home: URL, earlier: [String: String]) throws -> URL {
        let base = Self.base(home)
        let list = base.appending(path: "allowlist.json")
        try JSONEncoder().encode(sampleList()).write(to: list)
        for (run, ledger) in earlier { try write(ledger, to: base.appending(path: "runs/\(run)/live/ledger.json")) }
        let current = base.appending(path: "runs/XX-3", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: current.appending(path: "live"), withIntermediateDirectories: true)
        return current
    }

    private static let setup = """
        RC_RUN="$RC_BASE/runs/XX-3" RC_ROLES=(jamf-test-a) RC_CHECK_ERRORS=()
        rc_live_setup || exit 1
        """

    @Test("An earlier run’s objects join the ledger also without a sandbox, and a finished run is marked")
    func earlierRunsAreAdopted() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let current = try Self.prepare(home, earlier: [
            "XX-1": "[\(Self.item("test-a.jamf.example", "7", "JTKTEST XX 1027-1200 – Left"))]",
            "XX-2": "[\(Self.item("test-a.jamf.example", "8", "JTKTEST XX 1028-1200 – Gone", removed: true))]",
            "YY-1": "[\(Self.item("other.jamf.example", "9", "Another app’s object"))]",
        ])
        let result = try Self.zsh(Self.setup, home: home)
        #expect(result.status == 0, "\(result.output)")
        let merged = try JSONSerialization.jsonObject(with: Data(contentsOf: current.appending(path: "live/ledger.json"))) as? [[String: Any]]
        #expect(merged?.map { $0["id"] as? String } == ["7"])
        #expect(merged?.first?["fromSweep"] as? Bool == true && merged?.first?["confirmed"] as? Bool == false)

        // This run removed it: the earlier run is marked and not read again.
        var removed = try #require(merged)
        removed[0]["removed"] = true
        try JSONSerialization.data(withJSONObject: removed).write(to: current.appending(path: "live/ledger.json"))
        let finish = try Self.zsh(#"RC_RUN="$RC_BASE/runs/XX-3" RC_LIVE_DIR="$RC_RUN/live" RC_LIVE_PARENT="" RC_CHECK_ERRORS=(); rc_live_finish"#, home: home)
        #expect(finish.output.contains("Earlier run’s objects all removed: XX-1"), "\(finish.output)")
        #expect(FileManager.default.fileExists(atPath: Self.base(home).appending(path: "runs/XX-1/live/taken-over").path))
        try FileManager.default.removeItem(at: current.appending(path: "live/ledger.json"))
        _ = try Self.zsh(Self.setup, home: home)
        #expect(!FileManager.default.fileExists(atPath: current.appending(path: "live/ledger.json").path), "nothing left to adopt")
    }

    @Test("An earlier object that can’t be adopted fails stage 1", arguments: [
        ("test-a.jamf.example", "UIT - Security"),
        ("read.jamf.example", "JTKTEST XX 1027-1200 – On a tenant this run doesn’t use"),
    ])
    func unadoptableObjectsFailStageOne(target: String, name: String) throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try Self.prepare(home, earlier: ["XX-1": "[\(Self.item(target, "7", name))]"])
        let result = try Self.zsh(Self.setup + "\nprint SET-UP", home: home)
        #expect(result.status != 0 && !result.output.contains("SET-UP"), "\(result.output)")
        #expect(result.output.contains("An earlier run’s ledger can’t be used"))
    }

    // MARK: L12: credentials only while needed

    @Test("Credentials are read right before sign-in and stage 4, and forgotten in between")
    func credentialsOnlyWhileNeeded() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try Self.prepare(home, earlier: [:])
        let result = try Self.zsh("""
            security() { print -r -- "not-a-real-secret" }
            CREDENTIALS=("jamf-test-a:jamfPlatform:client-secret") RC_ROLES=(jamf-test-a) RC_SECRET_VARS=()
            rc_read_credentials
            print "read=$(printenv TEST_RUNNER_JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET)"
            rc_forget_credentials
            print "after=$(printenv TEST_RUNNER_JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET)."
            """, home: home)
        #expect(result.output.contains("read=not-a-real-secret") && result.output.contains("after=."), "\(result.output)")

        let source = try String(contentsOf: Self.template, encoding: .utf8)
        let main = String(source[try #require(source.range(of: "release_check_main() {")).lowerBound...])
        func position(_ text: String, after: String.Index? = nil) throws -> String.Index {
            try #require(main.range(of: text, range: (after ?? main.startIndex)..<main.endIndex)).lowerBound
        }
        let signIn = try position(#"rc_test "$SIGNIN_TEST""#)
        let forget = try position("rc_forget_credentials", after: signIn)
        let firstRead = try position("rc_read_credentials")
        let stage2 = try position("# Stage 2")
        let stage4 = try position("# Stage 4")
        let readAgain = try position("rc_read_credentials", after: forget)
        let liveStarted = try position("RC_LIVE_STARTED=1", after: readAgain)
        #expect(firstRead < signIn && forget < stage2)
        #expect(readAgain > stage4 && readAgain < liveStarted)
    }

    // MARK: The fingerprint and the version label

    @Test("Lists an app leaves unset fingerprint nothing: no empty setting, path or Keychain prefix")
    func unsetListsAddNothing() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let out = home.appending(path: "fp")
        let result = try Self.zsh("""
            unset FINGERPRINT_DEFAULTS KEYCHAIN_PREFIXES
            FINGERPRINT_PATHS=("\(home.appending(path: "missing").path)")
            rc_check_failed() { print -r -- "CHECK FAILED: $*" }
            rc_fingerprint "\(out.path)" && cat "\(out.path).names"
            """, home: home)
        #expect(result.status == 0)
        #expect(!result.output.contains("CHECK FAILED"))
        #expect(result.output.split(separator: "\n").map(String.init) == ["absent \(home.appending(path: "missing").path)"],
                "only the one path; no “defaults” line for an empty pair")
    }

    @Test("The report names JTKit by its own version and commit, not by the nearest git tag")
    func versionLabel() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try String(contentsOf: Self.template.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JTKit/JTKit.swift"), encoding: .utf8)
        let version = try #require(source.firstMatch(of: /public static let version = "([^"]+)"/)?.1)
        let result = try Self.zsh("""
            RC_LIB_DIR="\(Self.template.deletingLastPathComponent().path)"
            rc_jtkit_version
            """, home: home)
        let label = result.output.split(separator: "\n").last.map(String.init) ?? ""
        #expect(label.wholeMatch(of: /(.+) \([0-9a-f]{7,}\)/)?.1 == Substring(version), "\(label)")
    }

    // MARK: L10 and the legacy sweep

    @Test("No setting moves the allow-list, and the one-time legacy sweep is gone")
    func noOverrides() throws {
        let scripts = Self.template.deletingLastPathComponent()
        for file in ["release-check-lib.sh", "release-check-setup.sh"] {
            let text = try String(contentsOf: scripts.appending(path: file), encoding: .utf8)
            #expect(!text.contains("JTKIT_ALLOWLIST"), "\(file)")
            #expect(!text.contains("export TEST_RUNNER_JTKIT_LIVE_ALLOWLIST"), "\(file)")
            #expect(!text.contains("legacy-swept") && !text.contains("export TEST_RUNNER_JTKIT_LIVE_LEGACY_PREFIXES"), "\(file)")
        }
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try Self.zsh(#"print -r -- "$RC_ALLOWLIST""#, home: home)
        #expect(result.output.contains(Self.base(home).appending(path: "allowlist.json").path))
    }
}
