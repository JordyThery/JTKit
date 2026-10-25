# Changelog

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
