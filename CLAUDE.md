# JTKit: instructions for Claude

JTKit is the shared Swift package for Jordy's apps in `~/Developer`. Jordy is not a programmer: explain what you changed in plain language, make small steps, and keep each app's behaviour and look identical when moving code into JTKit.

## Layout

One library product, `JTKit` (macOS 14+, iOS 17+, Swift 6 language mode). Organise `Sources/JTKit/` in folders:

- `Core/`: Keychain, JSONValue, log redaction, request and activity logs, HTTP basics
- `Updates/`: GitHub-release update checker and update view
- `AppShell/`: About, acknowledgements, reusable Settings sections
- `Jamf/`: token providers (OAuth client credentials, basic auth), Jamf Pro API, Classic API, Platform API (Blueprints, device groups), Jamf School
- `Intune/`: Entra ID / Microsoft Graph auth and Intune device endpoints
- `ABM/`: Apple Business / School Manager API

Test helpers (MockURLProtocol, fixtures) go in a separate library product `JTKitTestSupport` when first needed, never in `JTKit` itself.

## Rules for shared code

1. Nothing app-specific is hard-coded: app name, GitHub repo, bundle IDs, Keychain service names, URLs, UserDefaults keys come in as parameters or a configuration value.
2. Only what apps need is `public`; everything else stays internal.
3. Swift 6 concurrency: model types are `Sendable`; UI state is `@MainActor`.
4. Platform-specific code goes inside `#if os(macOS)` / `#if os(iOS)` (Device Assist is iOS).
5. Every component gets Swift Testing tests in `Tests/JTKitTests`, with no real network calls.
6. No third-party dependencies without asking Jordy first.
7. Views follow Apple's HIG: run the apple-design skill review on any view added or changed here.
8. Strings and assets in the package are loaded with `Bundle.module`.

## Moving a component out of the apps

One component, one app at a time:

1. Compare the copies listed below. Start from the most complete, best-tested one. Where copies differ, make the difference an option, not an app-specific branch.
2. Add it to JTKit with tests.
3. Switch the app to the JTKit version and delete the app's own copy. Behaviour and look stay the same.
4. **Preserve stored data.** Keep each app's existing Keychain service and account names, UserDefaults keys, file locations and Codable field names by passing them in from the app. Changing them silently loses users' saved connections and settings.
5. Build the app and run its tests.

Apps depend on JTKit through its GitHub URL (Up to Next Major Version). Never add a local-path reference to JTKit inside an app's project. `~/Developer/Apps.xcworkspace` already makes every app build against the local JTKit during development.

Only change an app when Jordy asks for that app.

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
| Request / activity log | AppSettings2Blueprint and Blueprint Managed Preferences Editor `RequestLog`; Checkpoint, Intune Deployer, Jamf Deployer, Profile2Blueprint `ActivityLog` |
| Jamf Platform API client + token provider | AppSettings2Blueprint `PlatformAPIClient`, Blueprint Managed Preferences Editor `PlatformAPIClient`, Jamf Deployer `JamfPlatformClient`, JamfMigrator `PlatformClient` + `TokenProvider`, Profile2Blueprint `HTTPClient` + `TokenProvider` |
| Connection / tenant profiles | AppSettings2Blueprint and Blueprint Managed Preferences Editor `ConnectionProfile` + `ProfileStore`; Jamf Deployer, JamfMigrator, Profile2Blueprint `Tenant` + `TenantStore`; Intune Deployer `TenantStore` |
| Jamf Pro API client | Checkpoint `JamfClient` (2,204 lines), Device Assist `JamfClient` (603, iOS), Serial Number Reader `JamfClient` (598) |
| Jamf School client | Checkpoint `JamfSchoolClient` (616), Serial Number Reader `JamfSchoolClient` (250) |
| Intune / Graph | Checkpoint `IntuneClient`, Intune Deployer `GraphClient` + `AuthManager` |
| Apple Business Manager | Checkpoint `ABMClient` |
| About view | AppSettings2Blueprint, Jamf Deployer, Profile2Blueprint |
| Test helper `MockURLProtocol` | AppSettings2Blueprint, Profile2Blueprint |

Settings views exist in every app but are mostly app-specific; share sections (connections, updates, logging), not whole screens.

Not candidates: IntuneOnboard's `OnboardCore` and Jamf Deployer's `DeployerKit` / `JamfDeployerCore` are app-specific packages.

## Suggested order

1. Updates: near-identical in 8 apps, quick win. Start with AppSettings2Blueprint (has tests).
2. Keychain (mind rule 4: keep existing service names).
3. JSONValue, redaction, request/activity log.
4. Jamf token providers and connection/tenant profiles.
5. Platform API (Blueprints) client.
6. Jamf Pro, Jamf School, Intune and ABM clients: largest and most diverged.
