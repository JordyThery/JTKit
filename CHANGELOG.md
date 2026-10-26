# Changelog

## 0.8.0 (2026-10-26)
Step 7 for Serial Number Reader: Jamf Pro lookups, Jamf School and Action
entries. Additions, plus two changes to wording every app shows. The MDM
command list, the Platform device calls and the Classic API basics follow
with Checkpoint.
- `JamfPro`: device lookups on `JamfPlatform.Client` (direct or through the
  gateway): a computer (`v4/computers-inventory`) or mobile device
  (`v2/mobile-devices/detail`) by serial or UDID, as a `Match` (none, one,
  several). Only a record whose serial or UDID is the one asked for counts
  (ignoring case). Serials and UDIDs with other characters than letters,
  digits and hyphens are refused before sending (`validatedIdentifier`,
  error kind `.invalidIdentifier`).
- Batches: `computers(serials:)` and `mobileDevices(serials:)`, 50 quoted
  serials per `=in=` filter, 4 requests at a time, one by one when Jamf Pro
  refuses the filter (HTTP 400); failures per serial.
- Typed, tolerant records `JamfPro.Computer` and `JamfPro.MobileDevice`:
  every section and field optional; a value of an unexpected type reads as
  nil instead of failing the lookup. v4 names (`lastCheckIn`), with v1's
  `lastContactTime` still read. "-1" department, building and site IDs are nil.
- A lookup can record its successful answer (`recording: .results`), trimmed
  to the record's ID and the sections asked for; the default stays "errors only".
- Asset tags: `setAssetTag(_:computerID:)` (`v4/computers-inventory-detail`)
  and `setAssetTag(_:mobileDeviceID:)` (`v2/mobile-devices`), safe to repeat.
- `jamfProVersion()` (`v1/jamf-pro-version`).
- `JamfPro.Privilege`: one table of the Jamf Pro privileges the apps need.
  Requests carry theirs (`send(_:privilege:)`, also on `get` and `json`).
- Hints (changed wording): on a Jamf Pro server, a refused request (403)
  names the missing privilege, pointing to Settings › API Roles and Clients
  for an API client and to Settings › User Accounts and Groups for a user
  account. A refused sign-in on a Jamf Pro server mentions no region or Jamf
  Account: "Check the username and password." or "Check the client ID and
  client secret, and that the API client is enabled in Jamf Pro under Settings
  › API Roles and Clients." The Platform API's wording is unchanged.
  `JamfPlatformError` gains `signIn` and `privilege`; the client sets them.
- `JamfSchool.Client` on JTKit's `HTTPClient`: Network ID and API key
  (Basic, shown as "Basic <redacted>"), 429 retried for every request, server
  errors and network drops for reads; failures read from the status, the
  body's `code` and known failure messages (also under HTTP 200). Device by
  serial (a `Match`) or UDID (nil for "DeviceNotFound"), fleet, devices in
  groups, groups, locations, ADE placeholders, asset tag, Test Connection.
  `JamfSchool.Device` reads both shapes of the answer (flags as booleans or
  0/1, the check-in in the instance's time zone). `JamfSchoolError` with
  Checkpoint's explanations and standard hints.
- Action entries: `ActivityLog.recordAction` and `ActivityLogEntry.action`,
  category "Action", with the devices it was about masked in the bug-report
  export.

## 0.7.2 (2026-10-26)
Step 6 for Profile2Blueprint. Additions only.
- `JamfPlatform.PermissionProblem`: Test Connection's message when signing in
  worked but a read permission is missing or couldn't be checked, built from
  `checkPermissions`' results. Moved from AppSettings2Blueprint's
  `ConnectionTestProblem` (also copied in Blueprint Managed Preferences
  Editor), unchanged; those two keep their copies until their next update.

## 0.7.1 (2026-10-26)
Step 6 for JamfMigrator. Additions; nothing an app calls today changes.
- `JamfPlatform.Client` also reaches a Jamf Pro server directly
  (`JamfPlatform.Server.jamfPro`): built from a Jamf Pro `Connection`, or with
  `server: .jamfPro` and `.organization` scope. Gateway-form paths are mapped
  (`pro/…` → `api/…`, `proclassic/…` → `JSSResource/…`); Platform-only paths
  are refused before sending. `server` tells which one a client uses.
- `JamfPlatform.Client`: `headers:` for headers of the app's own on every
  request, and `recorder` for the few requests that don't go through the
  client (e.g. an image on another host).
- The "forbidden" hint depends on where the request went: on a Jamf Pro
  server it says a privilege is missing and points to Settings › API Roles
  and Clients, on the Platform API to Jamf Account. `JamfPlatformError.server`
  carries it; the client sets it. `PermissionCheck.jamfProHint` names the
  privilege and points to the same place; `hint(on:)` picks the right hint.
- JTKit sends "AppName/version" as the User-Agent of every request it makes
  (`JTKit.userAgent`: the bundle name without spaces), unless the request
  sets its own: the request recorder, sign-ins and the update checker.

## 0.7.0 (2026-10-26)
Step 6: the Jamf Platform API, built with AppSettings2Blueprint. Additions,
plus one new option in the shared connection editor. The device, DDM and
device-action calls follow in a later 0.7.x.
- `LosslessJSON` (`Core/`): JSON that keeps key order, duplicate keys and the
  exact text of numbers, with its reader, writer, paths, `isSemanticallyEqual`
  and `aligned(to:)`. Moved from AppSettings2Blueprint's `JSONValue`, renamed
  so it doesn't collide with the copies still in other apps. Reads invalid
  UTF-8 as an error on macOS 14 too.
- Everything else is under `JamfPlatform` (`Jamf/Platform/`), for the same reason:
  - `JamfPlatform.Client`: built from a `Connection` (region gateway or host
    override, `X-Environment-Id` checked as a UUID before anything is sent),
    or with `.legacyTenant` (`X-Tenant-Id`) or `.organization` scope. On
    `HTTPClient`; the app's allow-list stays the app's. Redirects only to
    HTTPS on the same host and port. `errorStatus: .returned` hands an error
    status back instead of throwing (Jamf Deployer's preflight). `hints` adds
    the app's own hints to every error it throws.
  - `JamfPlatformError`: one reader for the gateway's, the benchmarks' and
    the sign-in's error shapes (`JamfPlatform.ErrorBody`), named codes
    (`JamfPlatform.ErrorCode`), one message format (status line,
    `CODE (field): description`, Trace ID, the app's hints, the standard
    hints), a copyable `report`. Messages go through `Redaction`; the Trace
    ID stays visible in the bug-report export.
  - `JamfPlatform.Poller` and `PollingPolicy`: from 2 s growing ×1.5 to 10 s,
    for at most 5 minutes (shorter if an app sets it); Cancel stops at once;
    the app names the errors that mean "not ready yet".
  - `checkPermissions`: reads only, 4 at a time; allowed, missing permission
    (403 only), not found, failed, unreachable; "Add the … permission" hints.
  - `JamfPlatform.Page` and `allPages`: stop on `hasNext`, then `totalCount`,
    then a short page; reaching the page limit is an error.
  - `JamfPlatform.Blueprints`: list (search, sort), detail, create, change
    steps (merge-patch), change scope, deploy, report, delete;
    `startDeployment` and `watchDeployment`, which tells the new deployment
    from the previous one by its start time. Models keep unknown states.
    `BlueprintDetail` holds the exact bytes and the lossless JSON.
  - `deviceGroups(filter:sort:)` and `JamfPlatform.RSQL`; `DeviceGroup` keeps
    unknown device and group types.
  - `JamfPlatform.environments(for:secret:recorder:)`: lists an
    organization's environments; an integration scoped to one environment
    gets `cannotListEnvironments`, which says so and where to find the ID.
- `ConnectionsSettingsTab(environments:)`: a "Load Environments" button below
  the Environment ID, then a picker; typing the ID still works, also when
  the list can't be loaded. Reviewed with the apple-design skill: the
  button's tooltip is short and a failure shows the editor's warning symbol.

## 0.6.4 (2026-10-26)
For Intune Deployer's adoption of step 5. Additions only.
- `Redaction`: an Azure Storage upload address hides its signature (`sig` is
  a secret field, in addresses, forms and text), and GitHub tokens (`ghp_`,
  `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`) are hidden anywhere in free
  text, also inside a recorded error answer. A codeload address's `?token=`
  was already hidden; now tested. An `Authorization: token …` header keeps
  only the word "token", as every scheme does; now tested.
- `RequestRecorder.download(_:)`: downloads to a temporary file, as
  `URLSession.download` does, and records the request. The file is never
  recorded; an error answer is, as with `send`.
- `RequestRecorder.send(recordsOnlyFailures:)`: adds an entry only when the
  request fails, e.g. for the blocks of an upload the app sums up itself.
- `RequestRecorder.note(duration:)`: a note can carry a duration, e.g. an
  upload's summary.

## 0.6.3 (2026-10-26)
Fix, found while Jamf Deployer adopted step 5 (decided by Jordy: the default
in every app, not an option).
- `JamfTokenProvider`: the sign-in follows a redirect only to HTTPS on the
  same host and port (`RedirectRule.sameHostHTTPSOnly`). Before, it followed
  every redirect, and a 307 or 308 sends the POST again, with the client
  secret, to wherever it points. A username and password sign-in is covered
  too. Requests after the sign-in keep the client's own redirect rule.
- `JTKitTestSupport`: `MockResponse.redirect(_:to:)` answers with a real
  redirect, so a client's redirect rule can be tested. Other responses
  behave as before.

## 0.6.2 (2026-10-26)
For Checkpoint's adoption of step 5. Additions only.
- `Redaction`: Jamf Pro extension attributes (`extensionAttributes`,
  `extension_attributes`) are hidden whole, like the personal blocks: they
  hold whatever an administrator's script reports, so they can hold a secret
  no key list finds.
- `HTTPRequest.recordedJSON` (and `RequestRecorder.send(recordedJSON:)`): an
  app can trim a JSON body before it is redacted and recorded, e.g. to keep
  only the inventory sections it asked for. The answer the app receives is
  unchanged; identifiers are collected from what is recorded. With a filter,
  a body that isn't JSON can't be trimmed, so it isn't recorded at all.

## 0.6.1 (2026-10-26)
Fix, found while Serial Number Reader adopted step 5.
- `IdentifierMasker`: "Export for Bug Report…" now also masks identifiers in
  a recorded address, where they follow a percent escape (a Jamf Pro lookup
  `filter=serialNumber%3D%3D%22C02XK1JHJG5H%22` left the serial visible) or
  are themselves encoded (`jane%40corp.example`).
- `RequestRecorder`: a recorded error answer (status 400 and up) also gets the
  free-text cleaning the on-screen message already gets, so a secret inside
  the server's message (`client_secret=…`, `Bearer …`) is hidden in the log
  and its exports too. Before, JSON answers were cleaned by key only.

## 0.6.0 (2026-10-26)
ROADMAP step 5: Jamf sign-in, HTTP basics and the shared activity log, first
adopted by Profile2Blueprint. Additions only; apps that don't use them work as
before (Jamf Deployer and Intune Deployer get the new window look when they
next update).
- `Core/`: `RequestRecorder` sends one request, times it, redacts it and adds
  an entry to the activity log. Request bodies are never recorded, response
  bodies only for errors, unless a request is marked safe (`recordsBodies`).
  Bodies over 256 KB aren't recorded; text is cut at 20,000 characters.
  Sensitive Jamf calls (unlock token, erase, FileVault key, lock PIN, Recovery
  Lock and LAPS passwords) record only method, path, status and duration.
- `Core/`: `HTTPClient` on top of it: bearer token, the app's headers, the
  app's list of allowed requests (paths with `..` or encoded slashes always
  refused), redirect rules, write spacing, Jamf Pro direct path mapping.
  `RetryRules`, the same in every app: at most 4 attempts; 429 for every
  method; server errors and network drops for reads and edits marked safe to
  repeat; `Retry-After` in seconds or as an HTTP date; doubling waits with a
  little randomness; no wait over 120 s; one new sign-in after a 401. Each
  wait is logged and cancelling stops it at once.
- `Jamf/`: `JamfTokenProvider`: API client (Platform API and Jamf Pro) and
  username/password, both token formats, renewed 60 s before expiry, one
  shared sign-in, made from a `Connection` (`Connection.jamfBaseURL`).
- `Core/`: `Redaction` (headers, forms, JSON at any depth, XML elements, free
  text, query parameters, error messages) and `FormEncoding`.
- `Core/`: `IdentifierMasker`: serials, UDIDs, IMEI/MEID/EID, MAC and IP
  addresses, emails, usernames, full names and device names, replaced with
  stable placeholders in the bug-report export.
- `Core/`: `ActivityLogEntry` gains `isWarning`, `service`, `connection`,
  `request` (`ActivityRequestDetails`) and `identifiers`. `ActivityLogWindow`
  (⇧⌘L) with search, Problems Only, a detail pane, Clear, "Export for Bug
  Report…" and "Export Unmasked…" (`ActivityLogExport`, with app and macOS
  versions), also in the menu bar; ⌘C copies an entry. Failed statuses show a
  failure symbol, warnings a warning symbol.
- `AppShell/`: `ConnectionPicker`, `ConnectionMenuItems` and
  `ConnectionCommands` take the app's own items below the connections
  (`extraItems`); the picker takes a `label` shown instead of the connection.
- `Core/`: `KeychainSecretStore.deleteSecrets(withAccountPrefix:)` (also in
  `InMemorySecretStore`).
- `JTKitTestSupport`: `MockServer`, a fake server per session, so tests using
  different servers can run at the same time.

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
