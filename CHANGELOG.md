# Changelog

## 0.5.5 (2026-10-25)
From adopting ROADMAP step 4 in Intune Deployer. Additions only; apps that
don't use them work as before.
- `AppShell/`: `ConnectionsSettingsTab(importer:)` adds "Import…" to the +
  menu (`ConnectionImport`): the app reads a connection from a file, e.g. a
  tenant profile exported on another Mac; JTKit shows the open panel, saves
  and selects it. An import never replaces a saved connection with the same
  id: it is refused with a plain message. With an importer, + is always a
  menu, also for one service or with `add:`.

## 0.5.4 (2026-10-25)
From adopting ROADMAP step 4 in Jamf Deployer. Additions only; apps that
don't use them work as before.
- `AppShell/`: `ConnectionsSettingsTab(readOnlyFields:)` shows chosen shared
  fields of a connection as text, e.g. what was fixed when it was made
  (`ConnectionField`: sign-in method, region, server URL, Environment ID,
  client ID, username).
- `AppShell/`: `protectServices:` limits the Jamf Protect add-on to some
  services, e.g. Jamf Platform API connections only.
- `AppShell/`: `delete:` replaces what deleting does, for an app that removes
  more than the record and its secrets (it may take a while and fail with a
  message); `deleteMessage:` gives the confirmation its text. The list is
  read again afterwards.
- `Core/`: after a save, `ConnectionStore` reads the list back from its
  storage, and the editor continues from what was saved. For the built-in
  JSON file and UserDefaults storage nothing changes; an adapter that keeps
  more than the records (Jamf Deployer's) can rely on it.
- `Core/`: `JSONFile.encode` gives the exact bytes `JSONFile.save` writes, to
  check that a file on disk is still in that format before changing it.

## 0.5.3 (2026-10-25)
From adopting ROADMAP step 4 in Checkpoint. Additions only; apps that don't
use them work as before.
- `AppShell/`: "All" for a connection role (`ConnectionRole(…, all:)` with an
  `AllConnectionsChoice`), e.g. Checkpoint's "All Organizations". The picker
  and the Connection menu list it below the role's connections, dimmed until
  there are two or more. The same in every app: "All" lasts for the session
  only and is never saved; the app saves only the single connection chosen,
  so at launch the role falls back to the last one used. Choosing a single
  connection ends "All".
- `AppShell/`: a role can be limited to some services (`services:`), so one
  list can hold connections for different roles (Checkpoint's Apple and
  MDM). `ConnectionPicker(store:role:…, help:)` shows one role's picker.
- `AppShell/`: `ConnectionsSettingsTab(serviceGroups:)` lets a saved
  connection switch service only within its group, and gives the + menu a
  section per group. `signInMethods:` limits the sign-in methods offered for
  a service, e.g. Intune with an app registration only.
- `AppShell/` and `Core/`: the Apple private key is imported from its .pem
  file (`ApplePrivateKey`) and never shown: the editor has an "Import .pem
  File…" / "Replace Private Key…" button and a status line instead of a text
  box. Files that aren't an unencrypted private key are refused with a plain
  message.

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
