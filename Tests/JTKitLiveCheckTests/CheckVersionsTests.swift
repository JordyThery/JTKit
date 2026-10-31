import Foundation
import Testing

/// `Scripts/check-versions.sh`, run in a made-up app folder with stand-ins
/// for git and gh: nothing reaches GitHub.
@Suite("Start-of-conversation version check")
struct CheckVersionsTests {
    private static let script = ReleaseCheckTemplateTests.template.deletingLastPathComponent()
        .appending(path: "check-versions.sh")

    private static let changelog = """
        # Changelog

        ## 1.0.0 (2026-10-31)
        First stable release.
        - details

        ## 0.13.3 (2026-10-31)
        Asset tags again.

        ## 0.13.2 (2026-10-31)
        The lock.

        ## 0.13.1 (2026-10-31)
        Read-backs.
        """

    /// Runs the script in `<root>/Sample App` with JTKit at `version` and the
    /// app `ahead` commits past its release v2.0; `nil` leaves out Package.resolved.
    private static func run(version: String?, ahead: Int = 0, tags: [String] = ["0.13.1", "0.13.3", "1.0.0", "0.9.1"]) throws -> (status: Int32, output: String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "cv-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Sample App", directoryHint: .isDirectory)
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        let swiftpm = app.appending(path: "Sample.xcodeproj/project.xcworkspace/xcshareddata/swiftpm", directoryHint: .isDirectory)
        for folder in [swiftpm, bin, root.appending(path: "JTKit")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(changelog.utf8).write(to: root.appending(path: "JTKit/CHANGELOG.md"))
        if let version {
            let resolved = #"{"pins": [{"identity": "jtkit", "state": {"revision": "abc", "version": "\#(version)"}}], "version": 3}"#
            try Data(resolved.utf8).write(to: swiftpm.appending(path: "Package.resolved"))
        }
        let refs = tags.map { "0000000000000000000000000000000000000000\trefs/tags/\($0)" }.joined(separator: "\\n")
        let stubs = [
            "git": """
                #!/bin/zsh
                case "$1" in
                  ls-remote) print "\(refs)" ;;
                  remote) print "https://github.com/Owner/Sample-App.git" ;;
                  *) exit 1 ;;
                esac
                """,
            "gh": """
                #!/bin/zsh
                [[ "$1" == auth ]] && exit 0
                case "$2" in
                  repos/Owner/Sample-App/releases/latest) print '{"tag_name": "v2.0"}' ;;
                  repos/Owner/Sample-App/compare/v2.0...main) print '{"ahead_by": \(ahead)}' ;;
                  *) exit 1 ;;
                esac
                """,
        ]
        for (name, text) in stubs {
            let file = bin.appending(path: name)
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        return try ReleaseCheckTemplateTests.run("/bin/zsh", ["-c", "cd \"\(app.path)\" && \"\(script.path)\""],
                                                 environment: ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path])
    }

    @Test("Up to date: the latest JTKit and main at its release")
    func upToDate() throws {
        let result = try Self.run(version: "1.0.0")
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("Sample App: JTKit 1.0.0, the latest."))
        #expect(result.output.contains("Sample App: no unreleased commits since v2.0."))
    }

    @Test("An older JTKit lists the CHANGELOG entries in between, newest first, and nothing older")
    func outOfDate() throws {
        let result = try Self.run(version: "0.13.1")
        #expect(result.status == 1)
        #expect(result.output.contains("Sample App: JTKit 0.13.1, out of date: the latest is 1.0.0. In between:"), "\(result.output)")
        let listed = result.output.split(separator: "\n").filter { $0.hasPrefix("  ") }.map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(listed == ["1.0.0 (2026-10-31): First stable release.", "0.13.3 (2026-10-31): Asset tags again.",
                           "0.13.2 (2026-10-31): The lock."])
    }

    @Test("Unreleased commits are information only: the latest JTKit still passes; tags are compared as versions")
    func commitsSinceRelease() throws {
        let result = try Self.run(version: "1.0.0", ahead: 35, tags: ["0.9.1", "1.0.0", "0.10.0"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("Sample App: JTKit 1.0.0, the latest."), "0.9.1 and 0.10.0 sort below 1.0.0")
        #expect(result.output.contains("Sample App: 35 unreleased commits since v2.0."))
        #expect(try Self.run(version: "1.0.0", ahead: 1).output.contains("Sample App: 1 unreleased commit since v2.0."))
        let behind = try Self.run(version: "0.13.3", ahead: 35)
        #expect(behind.status == 1, "only the JTKit version decides")
    }

    @Test("Without a resolved JTKit the check says so and can’t pass")
    func nothingResolved() throws {
        let result = try Self.run(version: nil)
        #expect(result.status == 2)
        #expect(result.output.contains("no resolved version found"))
    }
}
