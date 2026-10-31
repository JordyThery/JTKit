import AppKit
import Foundation
import MSAL

/// MSAL itself: one `MSALPublicClientApplication` per client ID. The tenant
/// is given with each request (its authority).
@MainActor
final class MSALBackend: SignInBackend {
    private let application: MSALPublicClientApplication

    init(clientID: String, redirectURI: String) throws {
        let config = MSALPublicClientApplicationConfig(clientId: clientID, redirectUri: redirectURI, authority: nil)
        application = try MSALPublicClientApplication(configuration: config)
    }

    func accounts() -> [MicrosoftAccount] {
        ((try? application.allAccounts()) ?? []).map(Self.account)
    }

    func account(identifier: String) -> MicrosoftAccount? {
        msalAccount(identifier).map(Self.account)
    }

    func silentToken(scopes: [String], account: MicrosoftAccount, authority: URL, forceRefresh: Bool) async throws -> MicrosoftToken {
        guard let msalAccount = msalAccount(account.identifier) else { throw MicrosoftSignInError.notSignedIn }
        let parameters = MSALSilentTokenParameters(scopes: scopes, account: msalAccount)
        parameters.authority = try MSALAADAuthority(url: authority)
        parameters.forceRefresh = forceRefresh
        return try await withCheckedThrowingContinuation { continuation in
            application.acquireTokenSilent(with: parameters) { @Sendable result, error in
                continuation.resume(with: Self.outcome(result: result, error: error))
            }
        }
    }

    func interactiveToken(scopes: [String], account: MicrosoftAccount?, authority: URL) async throws -> MicrosoftToken {
        guard let (viewController, host) = Self.presentation(in: Self.candidateWindows()) else {
            throw MicrosoftSignInError.noWindow
        }
        // a zero-size view added for this sign-in goes when it ends
        defer { host?.removeFromSuperview() }
        let webview = MSALWebviewParameters(authPresentationViewController: viewController)
        let parameters = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webview)
        parameters.authority = try MSALAADAuthority(url: authority)
        if let account, let msalAccount = msalAccount(account.identifier) {
            // an expired sign-in or a new permission: for the saved account
            parameters.account = msalAccount
        } else {
            parameters.promptType = .selectAccount
        }
        return try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { @Sendable result, error in
                continuation.resume(with: Self.outcome(result: result, error: error))
            }
        }
    }

    func remove(_ account: MicrosoftAccount) {
        guard let msalAccount = msalAccount(account.identifier) else { return }
        try? application.remove(msalAccount)
    }

    func needsInteraction(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == MSALErrorDomain && error.code == MSALError.interactionRequired.rawValue
    }

    private func msalAccount(_ identifier: String) -> MSALAccount? {
        guard !identifier.isEmpty else { return nil }
        return try? application.account(forIdentifier: identifier)
    }

    private nonisolated static func account(_ account: MSALAccount) -> MicrosoftAccount {
        MicrosoftAccount(username: account.username ?? "unknown", identifier: account.identifier ?? "",
                         homeTenantID: account.homeAccountId?.tenantId)
    }

    private nonisolated static func outcome(result: MSALResult?, error: (any Error)?) -> Result<MicrosoftToken, any Error> {
        if let result {
            return .success(MicrosoftToken(accessToken: result.accessToken, scopes: result.scopes,
                                           account: account(result.account)))
        }
        return .failure(error ?? MicrosoftSignInError.noToken)
    }

    /// MSAL needs a view controller whose view is in a window.
    ///
    /// The anchor must be the frontmost (key) window: anchored to the main
    /// window while one of the app’s sheets is open, macOS queues the sign-in
    /// sheet behind it, it never appears and the sign-in hangs.
    private static func candidateWindows() -> [NSWindow] {
        var candidates: [NSWindow] = []
        if let key = NSApp.keyWindow { candidates.append(key) }
        if let main = NSApp.mainWindow, main !== NSApp.keyWindow { candidates.append(main) }
        candidates.append(contentsOf: NSApp.windows.filter { $0.isVisible && !candidates.contains($0) })
        return candidates
    }

    /// The first window’s view controller. SwiftUI sheet windows may have no
    /// content view controller; such a window gets a zero-size one, returned
    /// as `host` so the caller removes its view after the sign-in.
    static func presentation(in windows: [NSWindow]) -> (viewController: NSViewController, host: NSView?)? {
        for window in windows {
            if let viewController = window.contentViewController {
                return (viewController, nil)
            }
            if let contentView = window.contentView {
                let host = NSViewController()
                host.view = NSView(frame: .zero)
                contentView.addSubview(host.view)
                return (host, host.view)
            }
        }
        return nil
    }
}

extension MicrosoftSignIn {
    /// The person closed Microsoft’s sign-in window.
    public nonisolated static func isCancellation(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == MSALErrorDomain && error.code == MSALError.userCanceled.rawValue
    }
}
