# JTKit

Shared Swift code for my Mac admin apps (Checkpoint, Profile2Blueprint, AppSettings2Blueprint, Jamf Migrator, Serial Number Reader, Intune Deployer, Jamf Deployer, Blueprint Managed Preferences Editor): updates, About and Settings building blocks, Keychain, and connections to Jamf, Intune and Apple Business Manager.

Requires macOS 14. From 0.4.0 JTKit is macOS only.

## Add it to an app

1. In Xcode: **File › Add Package Dependencies…**
2. Paste `https://github.com/JordyThery/JTKit`
3. Dependency rule: **Up to Next Major Version**
4. Add the `JTKit` library to the app target, then `import JTKit` where needed.

## Working on JTKit and an app together

Open `~/Developer/Apps.xcworkspace`. Because JTKit is in that workspace as a local package, every app in it builds against the local copy instead of the GitHub version.

## Releasing

Bump `JTKit.version`, add a CHANGELOG entry, commit, tag the version (`0.2.0`, …) and push with tags. Then update the package in each app (**File › Packages › Update to Latest Package Versions**) before releasing that app.

## Status

0.1.0 is an empty scaffold. Components are moved in one at a time; see [CLAUDE.md](CLAUDE.md) for the plan and the inventory of duplicated code.

## License

MIT
