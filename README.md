<p align="center">
  <img src="docs/icon.png" width="128" alt="JTKit icon">
</p>

# JTKit

*The shared toolbox behind a family of Mac admin apps.*

[![Latest version](https://img.shields.io/github/v/tag/JordyThery/JTKit?label=version)](https://github.com/JordyThery/JTKit/tags)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## What it does

JTKit is a Swift package with the code that my Mac admin apps share: checking for updates, the About and Settings windows, saved connections with their secrets in the Keychain, and clients for **Jamf Pro**, **Jamf School**, **Microsoft Intune**, **Apple Business** and **Apple School Manager**. Every app gets the same behavior, the same look and the same safeguards, written and tested once.

| Product | What it is | Used by |
| --- | --- | --- |
| `JTKit` | The package itself: everything described below | Every app |
| `JTKitMSAL` | Microsoft’s sign-in window for Intune, the only product that depends on MSAL | Apps that sign in to Intune interactively |
| `JTKitTestSupport` | Test helpers: a mock server, an in-memory secret store, JTKit’s own live checks | Apps’ unit test targets |
| `JTKitUITestSupport` | A base class and smoke checks for UI tests in Demo Mode, and live UI tests | Apps’ UI test targets |
| `JTKitLiveCheck` | The rules, allow-list and guarded network of the release check’s live tests | Apps’ unit test targets, never shipped |

The package also builds `jtkit-live-gateway`, which the release check starts for live UI tests; apps never use it.

### Updates

`UpdateChecker` asks GitHub, at most once a day, whether the app has a newer release, shows its release notes in a sheet and downloads it on request. It doesn’t install anything: replacing the app stays a manual step. Settings gets a switch for the daily check, and the check talks only to GitHub.

### About and Settings

One About window, opened from the app menu, with the version, a copyright line JTKit writes itself, links and acknowledgements with full license texts. One Settings window with tabs in the toolbar and Updates always last, plus a Connection menu and picker that list the saved connections. Apps follow the Mac’s own Light or Dark setting.

### Connections and Keychain

A connections list and editor for several services in one list. Names, addresses and IDs are saved in the app’s settings or its own connections file; client secrets, passwords, API keys and private keys go to the Keychain (`KeychainSecretStore`), under each app’s own service name.

### Jamf Pro, Jamf Platform API and Jamf School

Sign-in with an API client or a username and password, with tokens renewed as needed. Jamf Pro device lookups, records, PreStages, sites, recovery secrets and MDM commands through the Jamf Pro API and the Classic API; Blueprints, device groups, devices and environments through the Jamf Platform API, also as a gateway to Jamf Pro; devices, groups, locations, Automated Device Enrollment and commands in Jamf School.

### Microsoft Intune through Graph

Microsoft Entra ID sign-in and Intune managed devices and device actions through Microsoft Graph, with Graph’s paging, request limits and permission checks. Interactive sign-in uses Microsoft’s own window, in `JTKitMSAL`.

### Apple Business and Apple School Manager

One client for both: devices, MDM servers, assignments, AppleCare coverage, Activation Lock and activities, paced to 18 requests a minute, below Apple’s limit of about 20 per organization.

### Demo Mode

Fake Jamf Pro, Jamf Platform API, Jamf School, Intune and Apple servers inside the app, with sample data, so an app can be tried without a tenant.

### Activity log and redaction

Every request to Jamf, Microsoft Graph and Apple is recorded in an activity log window (⌘⇧L): method, address, status, duration, attempt and headers, and the answer of a request that failed, with secrets redacted. The log is kept in memory only. The bug-report export masks the device, user and network identifiers it finds.

### Principles the code enforces

- **Secrets are never logged or written to disk.** They live in the Keychain. Request bodies are never recorded unless an app marks a request as safe, sensitive calls are recorded without headers or bodies, and everything else is redacted before it is shown or exported.
- **Every request to a service goes through one place.** `RequestRecorder` sends, times, redacts and logs each request to Jamf, Microsoft Graph and Apple, sign-in included; `HTTPClient` adds the shared retry rules on top. The only requests outside it are the update check and download from GitHub, and Microsoft’s own sign-in window.
- **Demo Mode never reaches a tenant.** Demo clients get a private network that answers only from the servers inside the app, and a request for a demo connection on any other session is refused before it is sent.
- **The release check’s live tests deny by default.** Every request is checked before it is sent: only tenants on a local allow-list are reached, read-only tenants get reads and sign-in only, plus commands to the devices listed for testing, and elsewhere only test objects are created, changed or deleted.

## Used by

- [AppSettings2Blueprint](https://github.com/JordyThery/AppSettings2Blueprint)
- [Blueprint Managed Preferences Editor](https://github.com/JordyThery/Blueprint-Managed-Preferences-Editor)
- [Checkpoint](https://github.com/JordyThery/Checkpoint)
- [Intune Deployer](https://github.com/JordyThery/intune-deployer)
- [Jamf Deployer](https://github.com/JordyThery/jamf-deployer)
- [Jamf Migrator](https://github.com/JordyThery/JamfMigrator)
- [Profile2Blueprint](https://github.com/JordyThery/Profile2Blueprint)
- [Serial Number Reader](https://github.com/JordyThery/Serial-Number-Reader)

All of them are listed at [jordythery.be/apps.html](https://jordythery.be/apps.html).

## Requirements

- macOS 14 or later
- Swift 6 tools
- Xcode 27 or later

## Add it to an app

1. In Xcode: **File › Add Package Dependencies…**
2. Paste `https://github.com/JordyThery/JTKit`
3. Dependency rule: **Up to Next Major Version**
4. Add the `JTKit` library to the app target, then `import JTKit` where needed.

In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/JordyThery/JTKit", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "JTKit", package: "JTKit"),
    ]),
]
```

## Dependencies

Only `JTKitMSAL` depends on a third-party package: Microsoft’s [MSAL](https://github.com/AzureAD/microsoft-authentication-library-for-objc), pinned to an exact version. Apps that don’t add `JTKitMSAL` ship none of MSAL, although resolving the package still downloads it.

## Versioning

JTKit follows [semantic versioning](https://semver.org) since 1.0: patch versions fix, minor versions add, major versions break. See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

## Development

Open `Package.swift` in Xcode and press ⌘U to run the tests; they make no network calls. `swift test` also runs the live-check rules’ own tests. The live checks run only when the release check switches them on, and never without the local allow-list. [ROADMAP.md](ROADMAP.md) is the development plan.

## Support

If JTKit saves you time, you can [buy me a coffee](https://buymeacoffee.com/jordythery). ☕️

## Disclaimer

This package is provided as-is, without warranty of any kind. Use it at your own risk. This is a personal project. It is not affiliated with or endorsed by my employer, Jamf, Apple or Microsoft. Issues and pull requests are appreciated. Support is best-effort.

## License

MIT
