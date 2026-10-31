import Foundation
import Testing

/// The release-check template (`Scripts/release-check-lib.sh`) runs its
/// checks in the Mac’s own Python, `/usr/bin/python3` (3.9 on macOS 27). A
/// block that doesn’t compile there does nothing at all, so its check never
/// runs. These tests compile every block with that Python, and run the
/// report with a broken check.
@Suite("Release-check template")
struct ReleaseCheckTemplateTests {
    static let template = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Scripts/release-check-lib.sh")
    static let python = "/usr/bin/python3"

    /// Every Python block: heredocs (`<<'EOF'`, `<<'PY'`) and `"$RC_PY" -c '…'`.
    static func pythonBlocks() throws -> [(line: Int, code: String)] {
        let text = try String(contentsOf: template, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        var blocks: [(Int, String)] = []
        var index = 0
        while index < lines.count {
            var line = lines[index]
            // A command continued on the next line (a trailing backslash).
            if line.contains("\"$RC_PY\"") {
                while line.hasSuffix("\\"), index + 1 < lines.count {
                    index += 1
                    line = String(line.dropLast()) + lines[index]
                }
            }
            if line.contains("\"$RC_PY\""), let marker = ["<<'EOF'", "<<'PY'"].first(where: line.contains) {
                let end = marker == "<<'EOF'" ? "EOF" : "PY"
                var body: [String] = []
                index += 1
                while index < lines.count, lines[index] != end {
                    body.append(lines[index])
                    index += 1
                }
                blocks.append((index - body.count, body.joined(separator: "\n")))
            } else if let range = line.range(of: "\"$RC_PY\" -c '") {
                // Up to the next single quote, possibly lines later.
                var rest = String(line[range.upperBound...])
                let start = index + 1
                while !rest.contains("'"), index + 1 < lines.count {
                    index += 1
                    rest += "\n" + lines[index]
                }
                blocks.append((start, String(rest[..<rest.firstIndex(of: "'")!])))
            }
            index += 1
        }
        return blocks
    }

    static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                            environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("Every Python block compiles with the Mac’s /usr/bin/python3, and none is missed")
    func everyPythonBlockCompiles() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.python), "no \(Self.python) on this Mac")
        let blocks = try Self.pythonBlocks()
        let text = try String(contentsOf: Self.template, encoding: .utf8)
        let calls = text.components(separatedBy: "\"$RC_PY\"").count - 1
        #expect(blocks.count == calls, "found \(blocks.count) Python blocks for \(calls) calls of $RC_PY")
        #expect(blocks.count >= 10)
        for (line, code) in blocks {
            let result = try Self.run(Self.python, ["-c", "import sys; compile(sys.stdin.read(), 'block', 'exec')"], input: code)
            #expect(result.status == 0, "the Python block at line \(line) doesn't compile: \(result.output)")
        }
    }

    @Test("The template is valid zsh")
    func zshSyntax() throws {
        let result = try Self.run("/bin/zsh", ["-n", Self.template.path])
        #expect(result.status == 0, "\(result.output)")
    }

    /// Runs the template’s report for a run folder made by the test.
    private func report(ledger: String, unrecorded: String? = nil) throws -> String {
        let run = FileManager.default.temporaryDirectory.appending(path: "rc-report-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: run.appending(path: "live"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: run) }
        try Data(ledger.utf8).write(to: run.appending(path: "live/ledger.json"))
        if let unrecorded { try Data(unrecorded.utf8).write(to: run.appending(path: "live/unrecorded-creates.jsonl")) }
        try Data("abc\n".utf8).write(to: run.appending(path: "fingerprint.before"))
        try Data("abc\n".utf8).write(to: run.appending(path: "fingerprint.after"))
        let script = """
        APP_NAME="Test"; APP_CODE="XX"
        source "\(Self.template.path)"
        RC_RUN="\(run.path)" RC_KIND="test" RC_JTKIT="test" RC_FAULT="" RC_CHECK_ERRORS=() RC_STAGE_NAMES=() RC_STAGE_STATUS=()
        rc_log() { print -r -- "$*" }
        rc_report
        """
        return try Self.run("/bin/zsh", ["-c", script], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]).output
    }

    @Test("A check that can’t run fails the run, named; a clean ledger passes")
    func brokenCheckFailsTheRun() throws {
        #expect(try report(ledger: "[]").contains("- Result: **passed**"))
        let broken = try report(ledger: "{ not json")
        #expect(broken.contains("- Result: **FAILED"), "\(broken)")
        #expect(broken.contains("a check couldn’t run: the ledger’s not-removed objects"), "\(broken)")
    }

    @Test("A create the ledger doesn’t hold fails the run, named")
    func unrecordedCreateFailsTheRun() throws {
        let output = try report(ledger: "[]", unrecorded: #"{"resource":"categories","name":"JTKTEST XX 1030 – C","status":201,"reason":"its answer held no readable ID"}"# + "\n")
        #expect(output.contains("FAILED: created but not in the ledger: categories “JTKTEST XX 1030 – C” (its answer held no readable ID)"), "\(output)")
        #expect(output.contains("- **Created but not in the ledger:** categories “JTKTEST XX 1030 – C”"), "\(output)")
    }

    @Test("An object a read-back still finds fails the run, named")
    func notRemovedFailsTheRun() throws {
        let output = try report(ledger: #"[{"target":"x","resource":"devicegroups","id":"g1","name":"JTKTEST XX 1030 – Group","removed":false,"fromSweep":false}]"#)
        #expect(output.contains("FAILED: not removed (a read-back still finds them): devicegroups g1 “JTKTEST XX 1030 – Group”"), "\(output)")
    }
}
