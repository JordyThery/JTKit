# JTKit: instructions for Claude

JTKit is the shared Swift package for Jordy’s apps in `~/Developer`. Jordy isn’t a programmer: explain what you changed in plain language, make small steps, and keep each app’s behavior and look identical when moving code into JTKit.

## Layout

One library product, `JTKit` (macOS 14+ only, Swift 6 language mode). Organize `Sources/JTKit/` in folders:

- `Core/`: Keychain, JSONValue, log redaction, request and activity logs, HTTP basics
- `Updates/`: GitHub-release update checker and update view
- `AppShell/`: About window, acknowledgements, the Settings window and reusable Settings sections (updates; connections from step 4), shared design components
- `Jamf/`: token providers (OAuth client credentials, basic auth), Jamf Pro API, Classic API, Platform API (Blueprints, device groups), Jamf School
- `Intune/`: Entra ID / Microsoft Graph auth and Intune device endpoints
- `ABM/`: Apple Business / School Manager API
- `Demo/`: demo mode (switch, private network, fake servers, Contoso sample data)

Test helpers (MockURLProtocol, fixtures) are in the separate library product `JTKitTestSupport`, never in `JTKit` itself. `JTKitMSAL` is Microsoft’s sign-in window (the only product that depends on MSAL). For the release checks: `JTKitUITestSupport` (UI test targets only, XCTest, doesn’t link JTKit; Swift 5 language mode), `JTKitLiveCheck` (apps’ unit test targets only, never shipped; the allow-list, rules, ledger and guarded network of the live checks) and `Scripts/release-check-lib.sh` with `release-check-setup.sh` (the release-check template each app’s `Scripts/release-check.sh` loads).

## Rules for shared code

1. Nothing app-specific is hard-coded: app name, GitHub repo, bundle IDs, Keychain service names, URLs, UserDefaults keys come in as parameters or a configuration value.
2. Only what apps need is `public`; everything else stays internal.
3. Swift 6 concurrency: model types are `Sendable`; UI state is `@MainActor`.
4. macOS only. IntuneOnboard and Device Assist (iOS) are out of JTKit entirely; don’t add iOS code or `#if os(iOS)` branches.
5. Every component gets Swift Testing tests in `Tests/JTKitTests`, with no real network calls.
6. No third-party dependencies without asking Jordy first.
7. Views follow Apple’s HIG: run the apple-design skill review on any view added or changed here. Design-review fixes change only JTKit’s shared look, never a single app.
8. The package has no resources: text is plain English Swift strings (American spelling, contractions with a curly apostrophe: doesn’t, can’t), and images are SF Symbols. Adding a resource means loading it with `Bundle.module`.
9. Follow "Standards for every app" in `ROADMAP.md` (About, acknowledgements, updates, connections, activity log). When adopting a step in an app, bring the app in line with the standards that step covers.

## Moving a component out of the apps

One component, one app at a time:

1. Compare the apps’ copies. Start from the most complete, best-tested one. Where copies differ, make the difference an option, not an app-specific branch.
2. Add it to JTKit with tests.
3. Switch the app to the JTKit version and delete the app’s own copy. Behavior and look stay the same.
4. **Preserve stored data.** Keep each app’s existing Keychain service and account names, UserDefaults keys, file locations and Codable field names by passing them in from the app. Changing them silently loses users’ saved connections and settings.
5. Build the app and run its unit tests (see "Testing").

Apps depend on JTKit through its GitHub URL (Up to Next Major Version). Never add a local-path reference to JTKit inside an app’s project. `~/Developer/Apps.xcworkspace` already makes every app build against the local JTKit during development.

Only change an app when Jordy asks for that app.

## Testing

Never run the full UI test suites or the `run-*-ui-tests.sh` scripts of Jamf Deployer and AppSettings2Blueprint: they take too long and don’t test the right things (decided by Jordy on 2026-10-25). Run a single UI test only when Jordy asks for it by name. "Run its tests" in a prompt or in `ROADMAP.md` means the unit tests.

From step 11 on, each app has a release check (`Scripts/release-check.sh`, see ROADMAP step 11), in five stages: build from its own project against the published JTKit and sign in to the app’s allow-listed tenants (`--tenants`: all of them), unit tests, short UI smoke tests in demo mode, **required live checks against sandbox tenants** (decided by Jordy on 2026-10-26: they replace most of his hand checks), and a report. Claude may run the release check and the apps’ smoke-test classes unattended (decided by Jordy on 2026-10-27; start it with `nohup` and poll); the rule above for the full UI suites still stands.

Live checks (decided by Jordy on 2026-10-27):
- Only tenants on the allow-list, `~/Library/Application Support/JTKit Release Check/allowlist.json`: outside every repo, never committed, hostnames, non-secret IDs and access levels only. Deny by default. Never add a customer tenant. Never name a real tenant in a repo; tests and scripts use role names.
- Access is enforced in code (`JTKitLiveCheck`): read-only tenants get GET only (plus sign-in and sign-out); Apple Business/School Manager is read only, assign, unassign, release and deadline changes never run; elsewhere only `JTKTEST`-prefixed objects are created, and only objects the run created are changed or deleted. Cleanup on every exit, also on failure. The production Jamf Pro is read only, and only with `--include-production`.
- Never ask for secrets in chat and never print them. Credentials come from the login Keychain: the apps’ saved connections, or `release-check-setup.sh`, which asks Jordy in Terminal with hidden input.
- Jamf Deployer’s live check keeps OpenTofu’s state and its store in a temporary folder and never pushes in Team Mode.
- New UI test targets are added with Xcode’s own new-target tool, never by editing `project.pbxproj`.

## Releasing an app

Follow the release gate in ROADMAP.md: release check passes (including live sandbox checks), a full apple-design review of the app, an independent code review of the app, then Jordy’s check by hand. Only then tag and release. Build the release from the app’s own project, so it uses the published JTKit version.

## Releasing JTKit

Bump `JTKit.version`, add a CHANGELOG entry, commit, tag `x.y.z` (a breaking API change means a new major version) and push with tags. Before releasing an app, update its JTKit package version so the committed app matches what was built.

**Before tagging any JTKit version, build every app that uses it** in `Apps.xcworkspace`, against the local JTKit: AppSettings2Blueprint, Blueprint Managed Preferences Editor, Checkpoint, Intune Deployer, Jamf Deployer, JamfMigrator, Profile2Blueprint, Serial Number Reader. Report any that fail and don’t tag until they all build. JTKit’s own tests can’t catch a change that breaks how an app calls it (0.4.2 broke Serial Number Reader’s Settings preview).

## Order and sources

Follow `ROADMAP.md`: it lists the steps in order, the source copy for each building block, which app goes first, and what Jordy checks by hand.
