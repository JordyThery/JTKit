# JTKit: instructions for Claude

JTKit is the shared Swift package for Jordy’s apps in `~/Developer`. Jordy isn’t a programmer: explain what you changed in plain language, make small steps, and keep each app’s behavior and look identical when moving code into JTKit.

## Layout

Two main library products, both in Swift 6 language mode:

- `JTKit` (macOS 14+ only): everything below. It includes and re-exports `JTKitContentCaching`.
- `JTKitContentCaching` (1.12.0, Foundation only, macOS 14 and iOS 17, in `Sources/JTKitContentCaching/`): the content cache model, the macOS 27 status items, savings and health. Used by Muster (iOS) directly and by the Mac apps through `JTKit`.

Organize `Sources/JTKit/` in folders:

- `Core/`: Keychain, JSONValue, log redaction, request and activity logs, HTTP basics
- `Updates/`: GitHub-release update checker and update view
- `AppShell/`: About window, acknowledgements, the Settings window and reusable Settings sections (updates; connections from step 4), shared design components
- `Jamf/`: token providers (OAuth client credentials, basic auth), Jamf Pro API, Classic API, Platform API (`Platform/`: Blueprints, device groups, devices, declaration reports, environments, software update and content cache reads, paging, polling, permissions), Jamf School
- `Intune/`: Entra ID / Microsoft Graph auth and Intune device endpoints
- `ABM/`: Apple Business or Apple School Manager API
- `SoftwareUpdate/`: the software update rules (`SoftwareUpdateRules`, from Software Update Dashboard in 1.9.0): targets and deadlines per device, classification, readiness, Blueprint health, Inspect, and the reader of a refresh. Saves nothing: apps pass in what they remember
- `AppleReleases/` (1.5.0): Apple’s release data from SOFA and GDMF, read only, and `OSVersion`
- `ContentCaching/` (1.11.0): `ContentCacheRules` and `CacheSweep`, the content caches from Jamf Pro and the caching Blueprints (the model itself is in `JTKitContentCaching`)
- `Demo/`: demo mode (switch, private network, fake servers, Contoso sample data)

Test helpers are in the separate library product `JTKitTestSupport`, never in `JTKit` itself: `MockServer` (with `MockURLProtocol`), an in-memory secret store and the Blueprint deploy live check (`LiveBlueprintDeployCheck`). JTKit’s own fixtures stay in `Tests/JTKitTests/Fixtures`, read by path. `JTKitMSAL` is Microsoft’s sign-in window (the only product that depends on MSAL). For the release checks: `JTKitUITestSupport` (UI test targets only, XCTest, doesn’t link JTKit; Swift 5 language mode), `JTKitLiveCheck` (apps’ unit test targets only, never shipped; the allow-list, rules, ledger and guarded network of the live checks) and `Scripts/release-check-lib.sh` with `release-check-setup.sh` (the release-check template each app’s `Scripts/release-check.sh` loads). `Scripts/check-versions.sh` is the start-of-conversation check each app’s CLAUDE.md runs: its JTKit version against the latest tag, and its commits since its latest release.

## Rules for shared code

1. Nothing app-specific is hard-coded: app name, GitHub repo, bundle IDs, Keychain service names, URLs, UserDefaults keys come in as parameters or a configuration value.
2. Only what apps need is `public`; everything else stays internal.
3. Swift 6 concurrency: model types are `Sendable`; UI state is `@MainActor`.
4. macOS only, except `JTKitContentCaching`: it stays Foundation only (no AppKit, SwiftUI, Security or networking), so it keeps building for iOS. Nothing else in JTKit gets iOS code or `#if os(iOS)` branches, and IntuneOnboard and Device Assist (iOS) stay out of JTKit entirely.
5. Every component gets Swift Testing tests in `Tests/JTKitTests` (the live-check rules: `Tests/JTKitLiveCheckTests`; MSAL: `Tests/JTKitMSALTests`), with no real network calls.
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

Apps depend on JTKit through its GitHub URL (Up to Next Major Version). Never add a local-path reference to JTKit inside an app’s project. **Exception: Muster** (iOS, `JTKitContentCaching` only) pins an exact version, because an App Store app gets only the version it was tested with. Raising it is a Muster change, made only when Jordy asks for Muster: set `exactVersion` for JTKit in Muster’s `project.yml`, run `xcodegen generate` there, resolve the packages and test Muster on that version; **Update to Latest Package Versions** doesn’t move an exact pin. `~/Developer/Apps.xcworkspace` already makes every app build against the local JTKit during development.

Only change an app when Jordy asks for that app.

## Testing

Never run the full UI test suites or the `run-*-ui-tests.sh` scripts of Jamf Deployer and AppSettings2Blueprint: they take too long and don’t test the right things (decided by Jordy on 2026-10-25). Run a single UI test only when Jordy asks for it by name. "Run its tests" in a prompt or in `ROADMAP.md` means the unit tests.

From step 11 on, each app has a release check (`Scripts/release-check.sh`, see ROADMAP step 11), in five stages: build from its own project against the published JTKit and sign in to the app’s allow-listed tenants (`--tenants`: all of them), unit tests, short UI smoke tests in demo mode, **required live checks against sandbox tenants** (decided by Jordy on 2026-10-26: they replace most of his hand checks), and a report. While fixing one test, `release-check.sh --only <test>` (1.3.0) runs just that test on the last build of the same source; it’s a partial run, never a release check. Ask Jordy before starting a release check or any UI test; once he says go, it may run unattended (start with `nohup`, then poll). The rule above for the full UI suites still stands.

Live checks (decided by Jordy on 2026-10-27):
- Only tenants on the allow-list, `~/Library/Application Support/JTKit Release Check/allowlist.json`: outside every repo, never committed, hostnames, non-secret IDs and access levels only. Deny by default. Never add a customer tenant. Never name a real tenant in a repo; tests and scripts use role names.
- Access is enforced in code (`JTKitLiveCheck`): read-only tenants get GET only (plus sign-in and sign-out); Apple Business or Apple School Manager is read only, assign, unassign, release and deadline changes never run; elsewhere only `JTKTEST`-prefixed objects are created, and only objects the run created are changed or deleted. Cleanup on every exit, also on failure. The production Jamf Pro is read only, and only with `--include-production` (or the allow-list’s `productionReads`); from 1.3.0 a production entry that opts in (`productionTestDevices`) also takes Blank Push, Update Inventory and check-in to its listed test devices, never an interruptive command. No interruptive command ever goes to the Mac the release check runs on (decided by Jordy on 2026-11-02).
- Never ask for secrets in chat and never print them. Credentials come from the login Keychain: the apps’ saved connections, or `release-check-setup.sh`, which asks Jordy in Terminal with hidden input.
- Jamf Deployer’s live check keeps OpenTofu’s state and its store in a temporary folder and never pushes in Team Mode.
- New UI test targets are added with Xcode’s own new-target tool, never by editing `project.pbxproj`.

## Working on JTKit and an app together

Open `~/Developer/Apps.xcworkspace`. Because JTKit is in that workspace as a local package, every app in it builds against the local copy instead of the GitHub version.

## Releasing an app

Follow the release gate in ROADMAP.md: release check passes (including live sandbox checks), a full apple-design review of the app, an independent code review of the app, then Jordy’s check by hand. Only then tag and release. Build the release from the app’s own project, so it uses the published JTKit version.

**Signing and notarization are Jordy’s** (decided by Jordy on 2026-11-23). Jordy archives, signs with Developer ID, notarizes and staples every release himself in Xcode, and supplies the notarized app. Claude never signs or notarizes, never runs a notarization script and never suggests a notary profile. This applies to every app released as a notarized download (not to the App Store and TestFlight apps). Claude’s steps, with the app Jordy supplies:

1. Check it: its `CFBundleShortVersionString` matches the tag, `codesign --verify --deep --strict`, `spctl -a`, `xcrun stapler validate`. Stop and tell Jordy if any check fails.
2. Zip it with `ditto -c -k --keepParent`, under the zip name in the app’s CLAUDE.md.
3. Unzip a copy elsewhere (outside the repo) and run the same checks on it.
4. Attach the zip to the GitHub release after Jordy approves the release notes.

## Releasing JTKit

From 1.0, JTKit follows semantic versioning (patch: fixes, minor: additions, major: breaking changes). A tag is created only after Jordy’s approval; until then the work waits on a branch.

Bump `JTKit.version`, add a CHANGELOG entry (it’s for developers using the package; never say how a problem was found, decided by Jordy on 2026-11-01), commit, tag `x.y.z` (a breaking API change means a new major version) and push with tags. Then update the package in each app (**File › Packages › Update to Latest Package Versions**) before releasing that app, so the committed app matches what was built.

The README is public and describes the package to other developers. When a change makes a statement in it untrue (products, areas, principles, requirements), update it in the same commit.

**Before tagging any JTKit version, build every app that uses it** in `Apps.xcworkspace`, against the local JTKit: AppSettings2Blueprint, Checkpoint, Intune Deployer, Jamf Deployer, JamfMigrator, Serial Number Reader, Software Update Dashboard (Profile2Blueprint and Blueprint Managed Preferences Editor were archived on 2026-11-11 and are no longer built). A private app outside the workspace also depends on JTKit: build it against the local JTKit as well (its own CLAUDE.md says how; it is named only in the private notes). Report any that fail and don’t tag until they all build. JTKit’s own tests can’t catch a change that breaks how an app calls it (0.4.2 broke Serial Number Reader’s Settings preview).

**A change to `JTKitContentCaching`** is also built for the iOS Simulator before tagging, not only for macOS (`xcodebuild -scheme JTKitContentCaching -destination 'generic/platform=iOS Simulator' build`), and then Muster is checked too: build it in `Apps.xcworkspace` against the local JTKit.

## Order and sources

Follow `ROADMAP.md`: it lists the steps in order, the source copy for each building block, which app goes first, and what Jordy checks by hand.
