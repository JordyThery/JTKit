import Foundation
import Testing
@testable import JTKit

/// The same condition is said in the same sentence everywhere, and text a
/// user sees uses the package’s terms: server URL, Private key, username,
/// Apple Business Manager, MDM server, “Network error:”.
@Suite("Text")
struct TextTests {
    private let recorder = RequestRecorder(session: URLSession(configuration: .ephemeral), log: nil)

    @Test("The Apple sign-in method is called Private key")
    func applePrivateKeyName() {
        #expect(SignInMethod.applePrivateKey.displayName == "Private key")
        #expect(SignInMethod.applePrivateKey.secretName == "Private key")
    }

    @Test("Typed-in values: the server URL and the Protect URL by their field names; the client ID in the Entra wording")
    func connectionIssues() {
        #expect(Connection(name: "A", service: .jamfPro, serverURL: "example.com").issues
                == ["Enter the server URL, starting with https://."])
        #expect(Connection(name: "A", service: .intune, clientID: "app").issues
                == ["The client ID isn’t a UUID. Copy the Application (client) ID from Entra."])
    }

    @Test("A client ID that isn’t a UUID: the editor and the sign-in say the same")
    func clientIDWording() async {
        let connection = Connection(name: "A", service: .intune, signIn: .entraClientSecret, clientID: "app", tenantID: "contoso.com")
        do {
            _ = try Graph.TokenProvider(connection: connection, secret: { "s" }, recorder: recorder)
            Issue.record("accepted")
        } catch {
            #expect(connection.issues.contains(error.localizedDescription.components(separatedBy: "\n")[0]))
        }
    }

    @Test("A sign-in method a service can’t use is named as the picker shows it")
    func signInMethodNames() {
        let platform = Connection(name: "A", service: .jamfPlatform, signIn: .usernamePassword, clientID: "c")
        do {
            _ = try JamfPlatform.TokenProvider(connection: platform, secret: { "s" }, recorder: recorder)
            Issue.record("accepted")
        } catch {
            #expect(error.localizedDescription == "Jamf Platform API can’t sign in with Username and password.")
        }
        let intune = Connection(name: "A", service: .intune, signIn: .microsoftInteractive,
                                clientID: UUID().uuidString, tenantID: "contoso.com")
        do {
            _ = try Graph.TokenProvider(connection: intune, secret: { "s" }, recorder: recorder)
            Issue.record("accepted")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Intune can’t sign in with Microsoft sign-in here."))
        }
    }

    @Test("Devices that came back for another serial are counted in words")
    func deviceMismatchCount() {
        #expect(JamfPlatform.DeviceMismatch(serial: "A1", count: 1).localizedDescription
                == "The platform device inventory returned 1 result for A1, none with that serial number.")
        #expect(JamfPlatform.DeviceMismatch(serial: "A1", count: 3).localizedDescription
                == "The platform device inventory returned 3 results for A1, none with that serial number.")
    }

    @Test("No answer reads “Network error:” for every service")
    func networkError() {
        let apple = ABM.APIError(.transport(method: "GET", path: "v1/orgDevices", code: .timedOut, message: "The request timed out."),
                                 service: .business)
        #expect(apple.message().hasPrefix("Network error: The request timed out.\n"))
        #expect(!apple.message().contains("didn’t answer"))
        let graph = Graph.APIError(.transport(method: "GET", path: "me", code: .timedOut, message: "The request timed out."))
        #expect(graph.message().hasPrefix("Network error: The request timed out."))
        let jamf = JamfPlatform.APIError(.transport(method: "GET", path: "x", code: .timedOut, message: "The request timed out."))
        #expect(jamf.message().hasPrefix("Network error: The request timed out."))
    }

    @Test("A refused sign-in reads “Sign-in failed: HTTP 401 Unauthorized”, also from the HTTP layer")
    func refusedSignIn() {
        let response = HTTPResponse(status: 401, headers: [:], data: Data())
        #expect(HTTPError.status(response, method: "POST", path: "auth/token", duringSignIn: true).localizedDescription
                == "Sign-in failed: HTTP 401 Unauthorized")
    }

    @Test("An unreadable answer names the service it came from")
    func unexpectedResponse() {
        #expect(Graph.APIError(.invalidResponse("no value")).message() == "Unexpected response from Microsoft Graph: no value")
        #expect(JamfPlatform.APIError(.invalidResponse("no list")).message()
                == "Unexpected response from the Jamf Platform API: no list")
        #expect(JamfPlatform.APIError(.invalidResponse("no list"), server: .jamfPro).message()
                == "Unexpected response from Jamf Pro: no list")
    }

    @Test("Apple’s limit is stated once: the log’s wait and the hint say the same")
    func appleLimit() {
        #expect(ABM.APIError.limitHint == "\(ABM.rateLimit.explanation). Wait a minute, then try again.")
        #expect(ABM.rateLimit.requests == 18)
    }

    @Test("Apple’s writes name Apple Business Manager in full and the MDM server")
    func appleTerms() {
        let assign = ABM.ActivityType.assign.consequence(count: 2, service: .business)
        #expect(assign.contains("not in Apple Business Manager"))
        let cancel = ABM.ActivityType.cancelMigration.consequence(count: 1, service: .business)
        #expect(cancel.contains("its assigned MDM server in Apple Business Manager"))
        #expect(cancel.contains("is canceled"))
        #expect(ABM.ActivityType.unassign.consequence(count: 1, service: .school).contains("won’t enroll automatically"))
    }

    @Test("The bug-report export says usernames")
    func exportHeader() {
        let masked = ActivityLogExport.text([], masked: true)
        #expect(masked.contains("Device identifiers, usernames and IP addresses are replaced with placeholders."))
        let unmasked = ActivityLogExport.text([], masked: false)
        #expect(unmasked.contains("Not masked: device identifiers, usernames and IP addresses are shown as recorded."))
    }

    // MARK: Curly apostrophes

    /// A date format’s quotes are syntax.
    static let straightApostropheExceptions = [
        "yyyy-MM-dd'T'HHmmss",
    ]

    @Test("No string literal in Sources has a straight apostrophe in its text")
    func curlyApostrophes() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50)
        var found = [String]()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for literal in Self.stringLiterals(in: text) where !Self.straightApostropheExceptions.contains(literal) {
                if literal.contains(/[A-Za-z]'[A-Za-z]/) || literal.contains(/\)'s\b/) {
                    found.append("\(file.lastPathComponent): \(literal)")
                }
            }
        }
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    @Test("No string literal outside the demo servers says “cannot”, “does not”, “is not” or “will not”")
    func contractions() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            // the demo servers copy the real servers’ wording
            .filter { file in
                let name = file.lastPathComponent
                return !(file.path.contains("/Demo/") && ["Server", "Store", "Objects"].contains { name.contains($0) })
            }
        #expect(files.count > 50)
        var found = [String]()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for literal in Self.stringLiterals(in: text)
            where literal.contains(/(?i)\b(cannot|can not|does not|do not|is not|are not|will not|could not|did not|was not)\b/) {
                found.append("\(file.lastPathComponent): \(literal)")
            }
        }
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    @Test("Command texts: consequences, no vendor comparison, contractions")
    func commandTexts() {
        #expect(MDMCommand.redeployFramework.consequence(on: .jamfPro)
                == "The Jamf management framework (the jamf binary) will be reinstalled on the Mac through MDM, so a Mac that stopped checking in but still responds to MDM checks in again.")
        #expect(MDMCommand.wipeComputer.consequence(on: .jamfPro) == "All data on the Mac will be erased. This can’t be undone.")
        #expect(MDMCommand.wipeComputer.consequence(on: .intune).hasSuffix("This can’t be undone."))
        #expect(MDMCommand.lockMobile.consequence(on: .jamfSchool) == "The device will lock immediately; the owner’s passcode unlocks it.")
        #expect(MDMCommand.lockMobile.consequence(on: .intune) == "The device will lock immediately; the owner’s passcode unlocks it.")
        let retire = MDMCommand.unmanage.consequence(on: .intune)
        #expect(!retire.contains("Jamf"))
        #expect(retire.hasSuffix("Its record is deleted too once the device acknowledges."))
        #expect(MDMCommand.unavailableOverPlatformAPI == "Renew MDM Profile doesn’t work over the Platform API. Use a Jamf Pro connection.")
        #expect(MDMCommand.unavailableOverPlatformAPI(.blankPush) == "Send Blank Push doesn’t work over the Platform API. Use a Jamf Pro connection.")
        #expect(JamfPlatform.DeviceActionRefused(verb: "restart").localizedDescription
                == "Jamf Pro won’t restart this device. It may be unmanaged, personally owned, or running an OS version that doesn’t support the command.")
    }

    @Test("Apple Business Manager in full; a refused Apple sign-in reads like the others")
    func appleTexts() {
        #expect(ABM.Service.business.label == "Apple Business Manager")
        let refused = ABM.APIError(.signIn(status: 401, code: nil, description: nil), service: .business)
        #expect(refused.message().hasPrefix("Sign-in failed: HTTP 401 Unauthorized\n"))
        #expect(ABM.APIError(.unreadableKey, service: .school).message().hasPrefix(
            ApplePrivateKey.ImportError.notPrivateKey.errorDescription ?? "-"))
    }

    @Test("An Environment ID that isn’t a UUID: the editor and the client say the same")
    func environmentIDWording() {
        let sentence = "The Environment ID isn’t a UUID (8-4-4-4-12 hexadecimal characters). Copy it from Jamf Account."
        #expect(Connection(name: "A", service: .jamfPlatform, environmentID: "env").issues == [sentence])
        #expect(JamfPlatform.APIError(.invalidEnvironmentID("env")).message().hasPrefix(sentence))
    }

    @Test("The scan finds string literals, and skips comments and interpolated code")
    func stringLiteralScan() {
        let code = #"""
        let a = "isn't" // a comment's text
        /* the block's text */ let b = "x \(f("y")) it's"
        let c = #"raw's"#
        """#
        #expect(Self.stringLiterals(in: code) == ["isn't", "x \\(…) it's", "raw's"])
    }

    /// The text of every string literal, with each interpolation as `\(…)`.
    static func stringLiterals(in source: String) -> [String] {
        let chars = Array(source)
        var literals = [String]()
        var i = 0
        func at(_ index: Int, _ text: String) -> Bool {
            let end = index + text.count
            return end <= chars.count && String(chars[index..<end]) == text
        }
        while i < chars.count {
            if at(i, "//") {
                while i < chars.count && chars[i] != "\n" { i += 1 }
            } else if at(i, "/*") {
                i += 2
                while i < chars.count && !at(i, "*/") { i += 1 }
                i += 2
            } else if chars[i] == "\"" || (chars[i] == "#" && at(i, "#\"")) {
                var hashes = 0
                while chars[i] == "#" { hashes += 1; i += 1 }
                let multiline = at(i, "\"\"\"")
                let quote = multiline ? "\"\"\"" : "\""
                let closer = quote + String(repeating: "#", count: hashes)
                let escape = "\\" + String(repeating: "#", count: hashes)
                i += quote.count
                var literal = ""
                while i < chars.count && !at(i, closer) {
                    if at(i, escape + "(") {
                        i += escape.count + 1
                        var depth = 1
                        while i < chars.count && depth > 0 {
                            if chars[i] == "\"" {
                                i += 1
                                while i < chars.count && chars[i] != "\"" { i += chars[i] == "\\" ? 2 : 1 }
                            } else if chars[i] == "(" {
                                depth += 1
                            } else if chars[i] == ")" {
                                depth -= 1
                            }
                            i += 1
                        }
                        literal += "\\(…)"
                    } else if at(i, escape) {
                        literal += String(chars[i..<min(i + escape.count + 1, chars.count)])
                        i += escape.count + 1
                    } else {
                        literal.append(chars[i])
                        i += 1
                    }
                }
                i += closer.count
                literals.append(literal)
            } else {
                i += 1
            }
        }
        return literals
    }
}
