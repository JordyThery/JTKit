# Changelog

## 0.5.2 (2026-10-25)
From adopting ROADMAP step 4 in AppSettings2Blueprint.
- `AppShell/`: the shared connection picker and "Connection" menu, a new
  standard for every app with a connection picker. `ConnectionPicker` is the
  toolbar control, named after the connection in use (an "Add Connection…"
  button while none are saved). `ConnectionCommands` adds the "Connection"
  menu to the menu bar. Both show `ConnectionMenuItems`: the saved
  connections with the one in use checked (a section per role when there are
  several), then "Edit Connections…", which opens Settings › Connections
  (`SettingsWindow(opensTabsByName: true)`).

## 0.5.1 (2026-10-25)
From adopting ROADMAP step 4 in Profile2Blueprint.
- `AppShell/`: `SettingsTabLink` opens the Settings window on a named tab,
  e.g. "Edit Tenants…" opening Connections. Apps turn it on with
  `SettingsWindow(opensTabsByName: true)` once every tab has a name:
  `SettingsTab` is named by its title, `ConnectionsSettingsTab` is
  `SettingsTabName.connections`, other tabs use `settingsTabName(_:)`. Off by
  default, so apps with unnamed tabs keep working as before.
- `AppShell/`: when Test Connection fails, the editor shows "Connection
  failed" with the error's full text below it, selectable for copying: its
  description, failure reason and recovery suggestion. Apps put details such
  as the HTTP status or trace ID in `failureReason`.

## 0.5.0 (2026-10-25)
Keychain and saved connections (ROADMAP step 4, first adopted in JamfMigrator).
- `Core/`: `SecretStore` and `KeychainSecretStore` (from JamfMigrator):
  login-keychain items under the app's own service name, with its
  accessibility and label, and the optional move from the data-protection
  keychain JamfMigrator needs.
- `Core/`: `Connection`, one record for every service (Jamf Platform API,
  Jamf Pro, Jamf School, Intune, Apple Business/School Manager) with sign-in
  methods and an optional Jamf Protect add-on. Apps keep their own record type
  and file format through `ConnectionRecord`.
- `Core/`: `ConnectionStore` with `JSONFileConnectionStorage` and
  `UserDefaultsConnectionStorage`, reading and writing each app's list where
  it already is. Safety rule: an unreadable list is copied aside, reported,
  and never saved over. The first save makes a one-time backup next to the
  original (`<file>.backup`, `<key>.backup`).
- `AppShell/`: `ConnectionsSettingsTab`, the shared Connections tab: a list
  of several services beside an editor with Save and Revert, Test Connection,
  "Use This Connection" or "Use as …" roles, a delete confirmation and an
  unsaved-changes confirmation. Secret fields start empty (stored secrets are
  never shown); the Delete key deletes the selected connection.
- `JTKitTestSupport`: `InMemorySecretStore`. JTKitTestSupport now depends on
  JTKit.

## 0.4.4 (2026-10-25)
- `AppShell/`: `Acknowledgement(licenceName:)` sets the label under which
  a licence folds out in About. Use it for texts that open with a copyright
  line instead of the licence's name (OpenTofu's MPL-2.0, Go's BSD-3-Clause),
  found adopting step 3 in Jamf Deployer. Without it the label is still the
  text's first line.

## 0.4.3 (2026-10-25)
- `AppShell/`: `SettingsTabs { … }` with only tabs works again, as in 0.4.1
  (the General tab then has Appearance alone). 0.4.2 dropped that form and
  broke Serial Number Reader's Settings preview.

## 0.4.2 (2026-10-25)
App shell: General tab with Appearance, wider Settings (ROADMAP step 3, from adopting it in Checkpoint).
- `AppShell/`: `AppAppearance` (System / Light / Dark). The Settings window
  now always opens with a General tab whose first item is the Appearance
  picker; apps pass their own general settings to `SettingsWindow(general:)`
  and they appear below it. JTKit applies the choice to the whole app, at
  launch and as it changes, and saves it under "appearance" (Checkpoint's
  key). Apps that only pass `tabs` get a General tab with Appearance alone.
- `AppShell/`: `SettingsLayout.width` is 680 points instead of 520, the width
  AppSettings2Blueprint and Blueprint Managed Preferences Editor already use,
  with room for a list beside an editor (Checkpoint's Apple and MDM tabs, and
  the connections tab in step 4).

## 0.4.1 (2026-10-25)
App shell consistency (ROADMAP step 3, from adopting it in Serial Number Reader).
- `AppShell/`: `AboutCopyright`. The About window writes the copyright line
  itself, "© 2026 Jordy Thery. Released under the MIT License.", from
  `AboutConfiguration.copyright` (licence defaults to MIT). It no longer reads
  `NSHumanReadableCopyright`; apps that don't pass `copyright` show no line.
- `AppShell/`: `SettingsWindow`, `SettingsTabs` and `SettingsTab`, the shared
  Settings window: tabs in the toolbar, the app's tabs first and Updates always
  last, every tab `SettingsLayout.width` (520 points) wide.

## 0.4.0 (2026-10-25)
App shell (ROADMAP step 3), from AppSettings2Blueprint. JTKit is now macOS 14 only.
- `AppShell/`: `AboutWindow`, the shared About window. It opens only from the
  app menu, is left out of the Window menu, and has only a working close
  button (minimize and zoom are dimmed). It shows the app icon, name,
  "Version x (build)", the copyright line from the app's Info.plist and what
  the app passes in `AboutConfiguration`: author, summary, links, disclaimer
  and acknowledgements.
- `AppShell/`: `Acknowledgement` and `AcknowledgementsView`: each project's
  credit, links and full licence text, folded away under the licence's name.
- `AppShell/`: `AppInfoCommands`: "About [App]", a separator, then
  "Check for Updates…" in the app menu.
- `Updates/`: `UpdateSettingsSection`, the "Check for updates daily" switch for
  Settings. It uses the checker's `automaticCheckKey` and store, so saved
  choices keep working.
- iOS removed: no iOS platform in `Package.swift`, no `#if os(macOS)` guards.

## 0.3.1 (2026-10-25)
- `Core/`: `ActivityLogEntry` takes an optional `failedWithoutStatus` for
  requests that never got a response. Such entries count as failed and show a
  red "—" in the activity log (VoiceOver: "Failed, no response"). Entries
  without a status that aren't marked stay as before: not failed, empty cell.

## 0.3.0 (2026-10-25)
Folds in Jamf Deployer's DeployerKit (ROADMAP step 2). Still macOS 14 / iOS 17.
- `Core/`: `ActivityLog` and `ActivityLogEntry` (capacity now a parameter,
  default 1,000), `ActivityLogView` (macOS), `JSONFile`, `TextExportDocument`.
- `AppShell/`: guided tour (`TourState`, `TourStep`, `.tourAnchor`,
  `.guidedTour`, macOS) and the shared components `StatusBadge`,
  `StatusIndicator`, `DetailHeader`, and `SheetFrame` (macOS).
- Accessibility, without changing the look: Escape skips the tour; VoiceOver
  stays inside the tour card and reads "Step 1 of 8"; with Reduce Motion the
  tour card fades between steps instead of sliding; failed statuses in the
  activity log are spoken as failed; spinners and headers are labelled, and
  DetailHeader's decorative symbol is hidden from VoiceOver.
- `Updates/`: a release is only offered when its download and page are on
  GitHub over HTTPS (from DeployerKit). Otherwise the manual check says so and
  the automatic check stays silent.

## 0.2.0 (2026-10-25)
- `Updates/`: GitHub-release update checker and update sheet, moved from
  AppSettings2Blueprint (the most recent copy). Each app passes an
  `UpdateConfiguration` with its GitHub repository and display name; the
  `UserDefaults` keys default to the names all apps already use, so saved
  preferences keep working. The sheet is macOS-only.
- `JTKitTestSupport`: `MockURLProtocol` and request/response helpers for
  network tests without real network calls.

## 0.1.0 (2026-10-25)
- Initial package scaffold. No shared components yet.
