import AppKit
import Foundation
import JTKit
import Testing
@testable import JTKitMSAL

/// MSAL as the tests need it: tokens for the permissions granted so far,
/// and a sign-in window that takes a moment and grants what it was asked for.
@MainActor
final class FakeMSAL: SignInBackend {
    enum Failure: Error { case interactionRequired, cancelled }

    var cached: [MicrosoftAccount]
    var granted: Set<String> = []
    var expired = false
    var cancelsWindow = false
    var windowTime: Duration = .milliseconds(50)
    /// What each window was asked for, in order.
    private(set) var windows: [(scopes: Set<String>, account: MicrosoftAccount?)] = []
    private(set) var silentRefreshes: [Bool] = []
    private(set) var removed: [MicrosoftAccount] = []
    private var open = 0
    private(set) var mostOpen = 0

    init(accounts: [MicrosoftAccount] = []) {
        cached = accounts
    }

    func accounts() -> [MicrosoftAccount] { cached }

    func account(identifier: String) -> MicrosoftAccount? {
        cached.first { $0.identifier == identifier }
    }

    func silentToken(scopes: [String], account: MicrosoftAccount, authority: URL, forceRefresh: Bool) async throws -> MicrosoftToken {
        silentRefreshes.append(forceRefresh)
        guard !expired, Set(scopes.map { $0.lowercased() }).isSubset(of: granted) else { throw Failure.interactionRequired }
        return MicrosoftToken(accessToken: "silent", scopes: Array(granted).sorted(), account: account)
    }

    func interactiveToken(scopes: [String], account: MicrosoftAccount?, authority: URL) async throws -> MicrosoftToken {
        open += 1
        mostOpen = max(mostOpen, open)
        windows.append((Set(scopes.map { $0.lowercased() }), account))
        try await Task.sleep(for: windowTime)
        open -= 1
        if cancelsWindow { throw Failure.cancelled }
        granted.formUnion(scopes.map { $0.lowercased() })
        expired = false
        let signedIn = account ?? MicrosoftAccount(username: "admin@contoso.com", identifier: "home.tid", homeTenantID: "tid")
        if !cached.contains(signedIn) { cached.append(signedIn) }
        return MicrosoftToken(accessToken: "window-\(windows.count)", scopes: Array(granted).sorted(), account: signedIn)
    }

    func remove(_ account: MicrosoftAccount) {
        removed.append(account)
        cached.removeAll { $0 == account }
    }

    func needsInteraction(_ error: any Error) -> Bool {
        (error as? Failure) == .interactionRequired
    }
}

// a time limit, so a sign-in that waits forever fails instead of hanging
@Suite("Microsoft sign-in", .timeLimit(.minutes(1)))
@MainActor
struct MicrosoftSignInTests {
    private static let clientID = "e445f0a6-0000-0000-0000-000000000000"
    private static let tenant = "c0ffee00-0000-0000-0000-000000000000"
    private static let account = MicrosoftAccount(username: "admin@contoso.com", identifier: "uid.tid", homeTenantID: Self.tenant)
    private static let read = ["User.Read", "DeviceManagementConfiguration.Read.All"]
    private static let write = ["User.Read", "DeviceManagementConfiguration.ReadWrite.All"]

    private func signIn(_ fake: FakeMSAL) throws -> MicrosoftSignIn {
        try MicrosoftSignIn(clientID: Self.clientID, backend: fake)
    }

    @Test("A silent token first: no window when the permissions are granted")
    func silentFirst() async throws {
        let fake = FakeMSAL(accounts: [Self.account])
        fake.granted = Set(Self.read.map { $0.lowercased() })
        let token = try await signIn(fake).token(for: Self.account, tenantID: Self.tenant, scopes: Self.read)
        #expect(token.accessToken == "silent")
        #expect(fake.windows.isEmpty)
    }

    @Test("After an expired sign-in, the window is for the saved account, not the account picker")
    func expiredUsesSavedAccount() async throws {
        let fake = FakeMSAL(accounts: [Self.account])
        fake.granted = Set(Self.read.map { $0.lowercased() })
        fake.expired = true
        _ = try await signIn(fake).token(for: Self.account, tenantID: Self.tenant, scopes: Self.read)
        #expect(fake.windows.count == 1)
        #expect(fake.windows.first?.account == Self.account)
    }

    @Test("Requests for the same permissions at the same time share one window")
    func sameScopesShareOneWindow() async throws {
        let fake = FakeMSAL(accounts: [Self.account])
        let microsoft = try signIn(fake)
        async let a = microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: Self.read)
        async let b = microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: Self.read.reversed())
        async let c = microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: Self.read.map { $0.uppercased() })
        let tokens = try await [a, b, c]
        #expect(Set(tokens.map(\.accessToken)) == ["window-1"])
        #expect(microsoft.windowCount == 1)
    }

    @Test("Other permissions wait until the window closes, then get a window of their own")
    func otherScopesAskAgainAfterTheWindow() async throws {
        let fake = FakeMSAL(accounts: [Self.account])
        let microsoft = try signIn(fake)
        async let reading = microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: Self.read)
        // starts while the read window is open
        async let writing: MicrosoftToken = {
            try await Task.sleep(for: .milliseconds(10))
            return try await microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: Self.write)
        }()
        let (readToken, writeToken) = try await (reading, writing)
        #expect(fake.windows.map(\.scopes) == [Set(Self.read.map { $0.lowercased() }), Set(Self.write.map { $0.lowercased() })])
        #expect(fake.mostOpen == 1, "never two windows at once")
        #expect(readToken.scopes.contains("devicemanagementconfiguration.read.all"))
        #expect(writeToken.scopes.contains("devicemanagementconfiguration.readwrite.all"), "the write request gets a write token, not the read one")
    }

    @Test("When the first window’s consent covers the waiting request, no second window opens")
    func waitingRequestCoveredByFirstWindow() async throws {
        let fake = FakeMSAL(accounts: [Self.account])
        let microsoft = try signIn(fake)
        let both = Self.read + Self.write
        async let first = microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: both)
        async let second: MicrosoftToken = {
            try await Task.sleep(for: .milliseconds(10))
            return try await microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: Self.read)
        }()
        _ = try await (first, second)
        #expect(microsoft.windowCount == 1)
    }

    @Test("A closed window fails every request that shared it")
    func cancelledWindow() async throws {
        let fake = FakeMSAL(accounts: [Self.account])
        fake.cancelsWindow = true
        let microsoft = try signIn(fake)
        async let a = microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: Self.read)
        async let b = microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: Self.read)
        var failures = 0
        do { _ = try await a } catch { failures += 1 }
        do { _ = try await b } catch { failures += 1 }
        #expect(failures == 2)
        #expect(microsoft.windowCount == 1)
    }

    @Test("Sign In shows the account picker, and waits for a window that’s open")
    func signInWaitsAndPicks() async throws {
        let fake = FakeMSAL(accounts: [Self.account])
        let microsoft = try signIn(fake)
        async let token = microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: Self.read)
        async let signedIn: MicrosoftToken = {
            try await Task.sleep(for: .milliseconds(10))
            return try await microsoft.signIn(tenantID: Self.tenant, scopes: Self.read)
        }()
        _ = try await (token, signedIn)
        #expect(fake.mostOpen == 1)
        #expect(fake.windows.last.map { $0.account == nil } == true)
    }

    @Test("Forgetting the token asks MSAL for a fresh one next time")
    func forcedRefresh() async throws {
        let fake = FakeMSAL(accounts: [Self.account])
        fake.granted = Set(Self.read.map { $0.lowercased() })
        let microsoft = try signIn(fake)
        let source = MicrosoftTokenSource { force in
            try await microsoft.token(for: Self.account, tenantID: Self.tenant, scopes: Self.read, forceRefresh: force).accessToken
        }
        _ = try await source.token()
        await source.forgetToken()
        _ = try await source.token()
        _ = try await source.token()
        #expect(fake.silentRefreshes == [false, true, false])
    }

    @Test("At launch the account is found by its ID, else by tenant (capitals ignored), else the only one")
    func savedAccount() throws {
        let other = MicrosoftAccount(username: "b", identifier: "b.other", homeTenantID: "other")
        let fake = FakeMSAL(accounts: [other, Self.account])
        let microsoft = try signIn(fake)
        #expect(microsoft.savedAccount(identifier: "b.other", tenantID: Self.tenant) == other)
        #expect(microsoft.savedAccount(identifier: "gone", tenantID: Self.tenant.uppercased()) == Self.account)
        #expect(microsoft.savedAccount(identifier: nil, tenantID: "contoso.com") == nil)
        fake.cached = [other]
        #expect(microsoft.savedAccount(identifier: nil, tenantID: "contoso.com") == other)
    }

    @Test("Sign-out removes the account from MSAL")
    func signOut() throws {
        let fake = FakeMSAL(accounts: [Self.account])
        try signIn(fake).signOut(Self.account)
        #expect(fake.removed == [Self.account])
        #expect(fake.cached.isEmpty)
    }

    @Test("The client ID must be a UUID; the tenant gives the sign-in address")
    func addresses() throws {
        #expect(throws: MicrosoftSignInError.invalidClientID) { try MicrosoftSignIn(clientID: "app", backend: FakeMSAL()) }
        #expect(MicrosoftSignInError.invalidClientID.localizedDescription
                == "The client ID isn’t a UUID. Copy the Application (client) ID from Entra.", "the same sentence as the Entra sign-in")
        #expect(try MicrosoftSignIn.validatedClientID(" \(Self.clientID)\n") == Self.clientID)
        #expect(try MicrosoftSignIn.authorityURL(tenantID: " contoso.com ").absoluteString == "https://login.microsoftonline.com/contoso.com")
        #expect(throws: MicrosoftSignInError.missingTenantID) { try MicrosoftSignIn.authorityURL(tenantID: " ") }
        #expect(try MicrosoftSignIn.authorityURL(tenantID: Self.tenant).absoluteString == "https://login.microsoftonline.com/\(Self.tenant)")
        for tenant in ["..", "contoso.com/../x", "a/b", "contoso.com?x", "contoso"] {
            #expect(throws: MicrosoftSignInError.invalidTenantID, "\(tenant)") { try MicrosoftSignIn.authorityURL(tenantID: tenant) }
        }
    }
    @Test("A silent-only token never opens the window: interaction needed is an error")
    func silentOnlyNeverOpensTheWindow() async throws {
        let fake = FakeMSAL(accounts: [Self.account])
        fake.granted = Set(Self.read.map { $0.lowercased() })
        let microsoft = try signIn(fake)
        let token = try await microsoft.silentToken(for: Self.account, tenantID: Self.tenant, scopes: Self.read)
        #expect(token.accessToken == "silent")
        await #expect(throws: MicrosoftSignInError.interactionRequired) {
            try await microsoft.silentToken(for: Self.account, tenantID: Self.tenant, scopes: Self.write)
        }
        fake.expired = true
        await #expect(throws: MicrosoftSignInError.interactionRequired) {
            try await microsoft.silentToken(for: Self.account, tenantID: Self.tenant, scopes: Self.read)
        }
        #expect(fake.windows.isEmpty)
        #expect(microsoft.windowCount == 0)
    }

    @Test("Strict account: only the one account of exactly this tenant, never the only other one")
    func strictAccount() throws {
        let other = MicrosoftAccount(username: "admin@fabrikam.com", identifier: "uid.other", homeTenantID: "0ther000-0000-0000-0000-000000000000")
        let microsoft = try signIn(FakeMSAL(accounts: [other]))
        #expect(microsoft.account(strictlyFor: Self.tenant, identifier: nil) == nil)
        #expect(microsoft.account(strictlyFor: Self.tenant, identifier: other.identifier) == nil,
                "a saved identifier of another tenant's account doesn't count")
        #expect(microsoft.savedAccount(identifier: nil, tenantID: Self.tenant) == other, "the loose lookup still falls back")
        let both = try signIn(FakeMSAL(accounts: [other, Self.account]))
        #expect(both.account(strictlyFor: Self.tenant.uppercased(), identifier: nil) == Self.account)
        #expect(both.account(strictlyFor: Self.tenant, identifier: Self.account.identifier) == Self.account)
        let twice = MicrosoftAccount(username: "second@contoso.com", identifier: "uid2.tid", homeTenantID: Self.tenant)
        #expect(try signIn(FakeMSAL(accounts: [Self.account, twice])).account(strictlyFor: Self.tenant, identifier: nil) == nil,
                "two accounts of the tenant: none chosen")
    }
}

@Suite("MSAL notice")
struct MSALNoticeTests {
    @Test("The notice follows the MSAL version JTKit pins")
    func pinnedVersion() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Package.swift")
        let manifest = try String(contentsOf: package, encoding: .utf8)
        #expect(manifest.contains(#"microsoft-authentication-library-for-objc", exact: "\#(MicrosoftSignIn.msalVersion)""#))
    }

    @Test("MIT license by Microsoft, with a link to MSAL")
    func license() {
        let msal = Acknowledgement.msal
        #expect(msal.heading == "Microsoft Authentication Library for iOS and macOS (MSAL) by Microsoft Corporation")
        #expect(msal.licenseName == "MIT License")
        #expect(msal.license == Acknowledgement.msalLicense)
        #expect(msal.license?.contains("Copyright (c) Microsoft Corporation") == true)
        #expect(msal.links.map(\.url.absoluteString) == ["https://github.com/AzureAD/microsoft-authentication-library-for-objc"])
        #expect(Acknowledgement.msal(summary: "App sentence.").summary == "App sentence.")
    }
}

@Suite("MSAL sign-in window anchor")
@MainActor
struct MSALPresentationTests {
    @Test("A window without a view controller gets a zero-size host for one sign-in, removed afterwards")
    func hostViewRemoved() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = NSView()
        let contentView = try #require(window.contentView)
        for _ in 0..<3 {
            let (viewController, host) = try #require(MSALBackend.presentation(in: [window]))
            #expect(viewController.view.window === window)
            #expect(contentView.subviews.count == 1)
            host?.removeFromSuperview()
        }
        #expect(contentView.subviews.isEmpty, "no view left behind per sign-in")

        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let controlled = NSWindow(contentViewController: content)
        let (viewController, host) = try #require(MSALBackend.presentation(in: [controlled]))
        #expect(viewController === controlled.contentViewController)
        #expect(host == nil)
    }
}
