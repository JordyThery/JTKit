# JTKit: instructions for Claude

JTKit is the shared Swift package for Jordy's apps in `~/Developer`. Jordy is not a programmer: explain what you changed in plain language, make small steps, and keep each app's behaviour and look identical when moving code into JTKit.

## Layout

One library product, `JTKit` (macOS 14+ only, Swift 6 language mode). Organise `Sources/JTKit/` in folders:

- `Core/`: Keychain, JSONValue, log redaction, request and activity logs, HTTP basics
- `Updates/`: GitHub-release update checker and update view
- `AppShell/`: About window, acknowledgements, the Settings window and reusable Settings sections (updates; connections from step 4), shared design components
- `Jamf/`: token providers (OAuth client credentials, basic auth), Jamf Pro API, Classic API, Platform API (Blueprints, device groups), Jamf School
- `Intune/`: Entra ID / Microsoft Graph auth and Intune device endpoints
- `ABM/`: Apple Business / School Manager API

Test helpers (MockURLProtocol, fixtures) go in a separate library product `JTKitTestSupport` when first needed, never in `JTKit` itself.

## Rules for shared code

1. Nothing app-specific is hard-coded: app name, GitHub repo, bundle IDs, Keychain service names, URLs, UserDefaults keys come in as parameters or a configuration value.
2. Only what apps need is `public`; everything else stays internal.
3. Swift 6 concurrency: model types are `Sendable`; UI state is `@MainActor`.
4. macOS only. IntuneOnboard and Device Assist (iOS) are out of JTKit entirely; don't add iOS code or `#if os(iOS)` branches.
5. Every component gets Swift Testing tests in `Tests/JTKitTests`, with no real network calls.
6. No third-party dependencies without asking Jordy first.
7. Views follow Apple's HIG: run the apple-design skill review on any view added or changed here. Design-review fixes change only JTKit's shared look, never a single app.
8. Strings and assets in the package are loaded with `Bundle.module`.
9. Follow "Standards for every app" in `ROADMAP.md` (About, acknowledgements, updates, connections, activity log). When adopting a step in an app, bring the app in line with the standards that step covers.

## Moving a component out of the apps

One component, one app at a time:

1. Compare the copies listed below. Start from the most complete, best-tested one. Where copies differ, make the difference an option, not an app-specific branch.
2. Add it to JTKit with tests.
3. Switch the app to the JTKit version and delete the app's own copy. Behaviour and look stay the same.
4. **Preserve stored data.** Keep each app's existing Keychain service and account names, UserDefaults keys, file locations and Codable field names by passing them in from the app. Changing them silently loses users' saved connections and settings.
5. Build the app and run its unit tests (see "Testing").

Apps depend on JTKit through its GitHub URL (Up to Next Major Version). Never add a local-path reference to JTKit inside an app's project. `~/Developer/Apps.xcworkspace` already makes every app build against the local JTKit during development.

Only change an app when Jordy asks for that app.

## Testing

Decided by Jordy on 2026-10-25: build, unit tests and Jordy's check by hand are enough. Never run the full UI test suites or the `run-*-ui-tests.sh` scripts of Jamf Deployer and AppSettings2Blueprint: they take too long and don't test the right things. Run a single UI test only when Jordy asks for it by name. "Run its tests" in a prompt or in `ROADMAP.md` means the unit tests.

## Releasing JTKit

Bump `JTKit.version`, add a CHANGELOG entry, commit, tag `x.y.z` (a breaking API change means a new major version) and push with tags. Before releasing an app, update its JTKit package version so the committed app matches what was built.

## Inventory of duplicated code (October 2026)

Paths are relative to `~/Developer`. Line counts show how far copies have drifted.

| Component | Copies |
|---|---|
| Update checker + update view (GitHub `releases/latest`) | AppSettings2Blueprint, Blueprint Managed Preferences Editor, Checkpoint, Intune Deployer, Jamf Deployer, JamfMigrator, Profile2Blueprint, Serial Number Reader: `UpdateChecker.swift` (123–181 lines) and `UpdateView.swift` (166–174 lines) |
| Keychain | AppSettings2Blueprint `KeychainStore`, Blueprint Managed Preferences Editor `KeychainStore`, Checkpoint `Keychain`, Jamf Deployer `KeychainItem`, JamfMigrator `SecretStore`, Profile2Blueprint `KeychainStore`, Serial Number Reader `KeychainStore` |
| JSONValue | AppSettings2Blueprint, Blueprint Managed Preferences Editor, Jamf Deployer, Profile2Blueprint |
| Log redaction | AppSettings2Blueprint `LogRedactor`, Profile2Blueprint `Redactor` (Jamf Deployer `PlanRedactor` has a different purpose) |
| Request / activity log | AppSettings2Blueprint and Blueprint Managed Preferences Editor `RequestLog`; Checkpoint, Intune Deployer, Jamf Deployer, Profile2Blueprint `ActivityLog`. All but Profile2Blueprint's migration history are replaced by JTKit's activity log in step 5. |
| Jamf Platform API client + token provider | AppSettings2Blueprint `PlatformAPIClient`, Blueprint Managed Preferences Editor `PlatformAPIClient`, Jamf Deployer `JamfPlatformClient`, JamfMigrator `PlatformClient` + `TokenProvider`, Profile2Blueprint `HTTPClient` + `TokenProvider` |
| Connection / tenant profiles | AppSettings2Blueprint and Blueprint Managed Preferences Editor `ConnectionProfile` + `ProfileStore`; Jamf Deployer, JamfMigrator, Profile2Blueprint `Tenant` + `TenantStore`; Intune Deployer `TenantStore` |
| Jamf Pro API client | Checkpoint `JamfClient` (2,204 lines), Serial Number Reader `JamfClient` (598) |
| Jamf School client | Checkpoint `JamfSchoolClient` (616), Serial Number Reader `JamfSchoolClient` (250) |
| Intune / Graph | Checkpoint `IntuneClient`, Intune Deployer `GraphClient` + `AuthManager` |
| Apple Business Manager | Checkpoint `ABMClient` |
| About view | AppSettings2Blueprint (window, with acknowledgements), Jamf Deployer (window, "Built with" credits), Profile2Blueprint (sidebar page). The other five use the standard macOS About panel. |
| Third-party notices | AppSettings2Blueprint: App Settings Utility (MIT, complete). Missing or incomplete: Jamf Deployer (jamformer MIT, Terraform providers MPL-2.0), Intune Deployer (MSAL MIT), JamfMigrator (Replicator MIT). |
| Test helper `MockURLProtocol` | AppSettings2Blueprint, Profile2Blueprint |

Settings views exist in every app but are mostly app-specific; share sections (updates from step 3, connections from step 4), not whole screens. No app has a logging setting; logs are windows (activity log, ROADMAP step 5).

Jamf Deployer's `DeployerKit` is an earlier shared package; its pieces move into JTKit (ROADMAP step 2). Not candidates: Jamf Deployer's `JamfDeployerCore` is app-specific. IntuneOnboard (with `OnboardCore`) and Device Assist are out of JTKit entirely.

## Order and sources

Follow `ROADMAP.md`: it lists the steps in order, the source copy for each building block, which app goes first, and what Jordy checks by hand.
