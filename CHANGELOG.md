# Changelog

## 0.12.2 (2026-10-28)
Step 11, for Profile2Blueprint, the first sandboxed app. An addition; no app has to change.
- `Scripts/release-check-lib.sh`: `TEST_HOST_CONTAINER="<bundle ID>"` for an
  app whose test host runs in the App Sandbox and so can't reach the
  allow-list or the run folder. The live folder (a copy of the allow-list, the
  ledger and the results) is then a folder of the run's inside the app's
  container, readable by you only (checked), copied back to the run folder
  for the report. At the end the allow-list copy must be unchanged, or the run
  fails. A folder an earlier run left (a crash, or a cleanup that didn't
  finish) is read at the start: its outstanding objects join this run's
  ledger (only `JTKTEST` names; anything else stops the run), and the folder
  is deleted only once this run has removed them.
- One release check per Mac at a time, for every app: a lock in `state/`
  beside the allow-list (the running check's process). A second check stops
  before it reads a credential or reaches a tenant; a lock whose process has
  ended (a killed run) is taken over. Closes the step 12 item about two checks
  on one tenant removing each other's `JTKTEST` objects.
- Stage 3 fails when the smoke-test file is missing or has no tests (it
  passed with none before).
- A live-check test for Classic macOS configuration profiles and computer
  groups through the Platform gateway (creates need the prefix in the first
  `<name>`; scope changes and deletes need the ledger).

## 0.12.1 (2026-10-28)
Step 11, for AppSettings2Blueprint. An addition; no app has to change.
- `Scripts/release-check-lib.sh`: `FINGERPRINT_DEFAULTS=("<domain> <key>" …)`
  fingerprints single UserDefaults values (a hash of each, never the value),
  for apps whose saved connections share a preferences file with window
  frames and other state macOS changes while the UI smoke tests run.
- `JTKitUITestSupport`: `checkConnectionsEditor(service:fill:)` also finds an
  unlabelled name field (by the new connection's name), and `fill` lets an app
  fill in made-up values its editor needs before Save is enabled.

## 0.12.0 (2026-10-27)
Step 11, for Jamf Deployer: autonomous testing and the release check. Additions; no app has to change.
- `JTKitUITestSupport` (new product, UI test targets only): `JTKitUITestCase`
  with Jamf Deployer's general helpers (launching the Debug build, `field`,
  `any`, `anyContaining`, `element(identifier:)`, `dialogButton`, `tap`,
  `type`, `paste`, `scrollIntoView`, `waitUntilGone`, `openSidebar`,
  `saveInChosenFolder`, `goToFolder`, `relaunch`, a folder per test, the
  failure dump plus a screenshot) and the shared demo checks
  `launchInDemo(scenario:)`, `checkAbout()`, `checkSettingsTabs(_:)`,
  `checkConnectionsEditor(service:)`, `checkConnectionsEditorOpens()`,
  `checkActivityLog()` and `checkDemoTitles()`. Its launch arguments are
  checked against `DemoMode`'s by a test.
- `JTKitLiveCheck` (new product, apps' unit test targets only, never
  shipped): the allow-list (`AllowList`, a private file outside every git work
  tree), `LiveCheckPolicy` (deny by default; read-only tenants GET only plus
  sign-in and sign-out; Apple activities never; creates only with the run's
  `JTKTEST` prefix; changes and deletes only of objects in the run's ledger;
  device commands never; the Graph token's tenant checked; every tenant read
  only until stage 4), `Ledger` (on disk after every change),
  `LiveCheckNetwork` (a session for the app's `RequestRecorder` that decides
  each request before it's sent and never follows a redirect) and
  `LiveCheckRun` (the run's settings, credentials, engine check, sweep,
  report lines, and the `--fault` points that test the check itself).
- `Scripts/release-check-lib.sh` and `release-check-setup.sh`: the
  five-stage release check each app's `Scripts/release-check.sh` loads (build
  and sign in, unit tests, UI smoke tests in demo mode, live checks with
  cleanup on every exit, a report with the before-and-after fingerprint of
  the app's connections and Keychain item names); `--local-jtkit`,
  `--tenants`, `--include-production`, `--stop-before-live`, `--fault`.
- Demo mode: a window whose title is set after JTKit has seen it (the
  Settings window names its tab) gets "— Demo" back straight away.

## 0.11.7 (2026-10-27)
Step 10, for Jamf Deployer. Additions; no app has to change.
- The Platform demo server answers the gateway's `/pro/…` (Jamf Pro API) and
  `/proclassic/…` (Classic API) from a Jamf Pro object store of its own
  (`DemoJamfPlatformServer(jamfPro:)`, `jamfPro`; "Contoso (Demo)" gets
  `DemoJamfProObjects.contosoPlatform()`: Contoso's objects with Automated
  Device Enrollment, Apps and Books and Self Service branding set up). An
  app's own `route(_:to:)` still comes first.
- Setup pages in `DemoJamfProObjects`, as Jamf answers them: volume purchasing
  locations (list; create keeps no token and reads back Apple's details),
  macOS Self Service branding (list, create), the Jamf Pro server address,
  App Catalog titles, the v1 computer and mobile device group lists, the ADE
  public key and token upload (makes an instance; the token isn't kept), and
  the Jamf Protect link (read, register; the password isn't kept).
- `DemoJamfProObjects.add(_:at:)`: an app's own sample objects at a Jamf Pro
  API list path.

## 0.11.6 (2026-10-27)
Step 10, for JamfMigrator. Additions; no app has to change.
- `DemoJamfProObjects`: a general Jamf Pro object store behind a demo Jamf Pro
  server (`DemoJamfProServer(objects:)`), for every type JamfMigrator copies, on
  both APIs. Classic: JSON or XML lists, XML details, create with `…/id/0`
  answering the new ID, `PUT` merged into the stored object (an icon-only PUT
  keeps the rest), `DELETE`, accounts groups by `groupid`, 409 "Duplicate
  name" and 404 as Jamf's HTML pages, written passwords read back as
  `password_sha256`. Jamf Pro API: paged lists, create answering `id` and
  `href`, `PUT`, merge-patch `PATCH`, `DELETE`, duplicate names refused, the
  settings pages (passwords never read back), the version. Jamf's special
  cases: PreStage version locks (409 `OPTIMISTIC_LOCK_FAILED`), profile UUID
  and nested IDs, no admin or Recovery Lock password; patch titles created by
  subscribing through Classic and patched with merge-patch only (415
  otherwise); patch policies created under their title; icon upload and
  download; ADE instances; `/api/v2/groups`.
- Two demo tenants, `Connection.demoJamfProSource` ("Contoso Source (Demo)",
  a golden master with objects of every type that refer to each other) and
  `Connection.demoJamfProDestination` ("Contoso Destination (Demo)", a fresh
  tenant with Jamf's built-ins, one identical object, a few that differ and one
  only there), direct Jamf Pro on `*.demo.invalid`, in `demoConnections`;
  their servers are `DemoMode.jamfProSourceServer` and
  `jamfProDestinationServer`. The `missingPermission` scenario refuses the
  destination's webhooks and single sign-on with 403.
- "Contoso Jamf Pro (Demo)" is unchanged.

## 0.11.5 (2026-10-27)
Step 10, for Intune Deployer. Additions; no app has to change.
- `DemoIntuneServer` holds a general Graph store for "Contoso Intune (Demo)":
  the Intune lists Intune Deployer uses (Settings Catalog, configurations,
  compliance, shell scripts, custom attributes, filters, apps), groups, `me`,
  the organization with its MDM authority, APNs certificate and ADE token, and
  the Settings Catalog. Lists with paging (`@odata.nextLink`), `$filter`
  (`eq`), `$select` and `$expand`; create, PATCH, PUT, DELETE, `/assign`,
  `scheduleActionsForRules`. Graph's own behaviour is kept: beta-only lists
  refuse v1.0, script lists leave out `scriptContent`, a policy's settings
  are their own list, compliance rules only with `$expand`. Checkpoint's
  `managedDevices` is unchanged.
- App uploads: content versions and files whose states move on when read
  (nothing waits), commit, `renewUpload`, publishing; the content goes to a
  fake storage host, `DemoIntuneServer.storageHost` (`*.demo.invalid`), on
  the same demo network. A commit without the uploaded blocks fails, as
  Graph's does; the encryption key in the commit isn't kept.
- `DemoMode.microsoftSignIn()` (`DemoMicrosoftSignIn`): in place of MSAL's
  interactive sign-in, a fixed token the demo tenant accepts
  (`DemoIntuneServer.delegatedToken`), its account
  (`demo.sample@contoso.example`) and the demo network's session.
- `DemoIntuneServer.add(_:to:)`, `objects(at:)`, `add(definitions:)`
  (`DemoSettingDefinition`), `uploadedBytes`, `storeRequestCount`.
- `-JTKitDemoScenario missingPermission` now also refuses every write to the
  demo tenant with Graph's real 403 (Intune's "Forbidden" naming the scope;
  Entra's `Authorization_RequestDenied` for groups); reads still work.
- `Connection.isDemo` is also true for a tenant ID or client ID in the fake
  range, so an exported demo tenant imported under a new ID is still refused
  by `ConnectionStore`.

## 0.11.4 (2026-10-27)
Step 10, for Serial Number Reader. Additions; no app has to change.
- `DemoWorld` device 42: `ZZDEMOP42RX`, Contoso's iPhone 16 (asset tag
  CT-1042), sent by Apple Business Manager to "Contoso Jamf Pro" and in the
  demo Jamf Pro, so an app can show an iPhone Jamf Pro knows. Devices 1–41
  are unchanged; Contoso now has 31 devices (an app that counts them, e.g.
  Checkpoint's demo test, sees 42 in all).
- `ConnectionRole.active(selection:demo:)`: the single-connection role can
  offer demo connections (`DemoConnectionChoice`), as `ConnectionRole(…, demo:)` does.

## 0.11.3 (2026-10-27)
Step 10, for Profile2Blueprint. Additions; no app has to change.
- `DemoJamfPlatformServer.add(groups:)`: an app adds its own sample device
  groups after Contoso's (one with an ID already there replaces it), e.g. a
  second group with the same name.
- `DemoJamfPlatformServer.route(_:to:)`: requests under a path the app
  names (e.g. `proclassic`) go to the app's own `DemoServer`, on the same
  demo network, so an app's requests there run through JTKit's real client
  like the rest. Sign-in stays the Platform server's; the longest path wins.

## 0.11.2 (2026-10-27)
Step 10, for Blueprint Managed Preferences Editor. Additions; no app has to change.
- `DemoJamfPlatformServer.add(_:)`: an app adds its own sample Blueprints to
  the demo server (`demo.jamfPlatformServer`), stored the way the service
  stores them, so an unchanged payload comes back byte for byte after a patch.
- The demo switch can ask first: set `DemoMode.asksBeforeSwitching` (e.g.
  "has unsaved edits") and add `confirmsDemoModeSwitch(_:)` to the window;
  `DemoModeToggle` then waits for "Turn on/off Demo Mode and discard unsaved
  changes?" (`requestSwitch(to:)`, `pendingSwitch`, `confirmSwitch()`,
  `cancelSwitch()`). `DemoModeToggle(demo:whenAsking:)` brings the window
  with the question forward from the Connection menu.
- `ConnectionPickerLabel.demo(_:)`: the picker names the demo connection,
  e.g. "Contoso (Demo)", as Checkpoint's does.

## 0.11.1 (2026-10-27)
Step 10, second part: demo mode for Checkpoint. Additions; no app has to change.
- `DemoWorld`: one shared set of 41 sample devices, the same in Apple
  Business and School Manager, Jamf Pro, Jamf School and Intune: Contoso
  (Apple Business Manager, Jamf Pro and Intune) and Contoso Academy (Apple
  School Manager, Jamf School), with the gaps a real fleet has, each checked
  by a test: three iPhones missing from Intune, expired AppleCare, an
  unassigned iPad, a Mac released by Apple but still in Jamf Pro, a Mac not
  heard from in months, a Mac in no Apple organization.
- Demo servers on the same private network, each run by JTKit's real
  clients in its tests:
  - `DemoJamfProServer`: API client sign-in, version, inventory by serial
    (batched filters), ADE instances with Apple's server IDs, PreStages and
    their scope, sites, departments, buildings, Classic groups, DDM status,
    commands, asset tag and site, unmanage, delete; FileVault, Recovery Lock,
    PIN and LAPS read back obviously fake values.
  - `DemoJamfSchoolServer`: fleet, groups, locations, ADE placeholders,
    commands, asset tag, move, trash; errors in the body as the service does.
  - `DemoIntuneServer`: Entra sign-in and Graph `managedDevices` (paging,
    actions, delete), answered on Microsoft's addresses inside the app.
  - `DemoAppleSignInServer` and `DemoAppleBusinessServer`: Apple's signed
    sign-in, checked against the public key; devices, organization read, MDM
    servers, AppleCare, Activation Lock, assigned server, audit events, and
    the writes as activities (in progress, then completed).
- `DemoMode.source(for:)`: what a client needs for a demo connection
  (`Connection.demoConnections`: Contoso and Contoso Academy in Apple
  Business and School Manager, Contoso Jamf Pro, Contoso Intune, Contoso
  Academy on Jamf School); nil for any other connection. Apple's sign-in key
  is made for each launch and kept in memory only, never saved.
- `DemoConnectionChoice` and `ConnectionRole(…, demo:)`: while demo mode is
  on, a role's picker and the Connection menu list its demo connections and
  "All" above the saved ones, the picker reads e.g. "Contoso (Demo)" with a
  test tube, no saved connection is checked, and choosing one leaves demo
  mode. Session only, never saved.
- `ABM.rateLimit(for:)` and `ABM.Client(…, rateLimit:)`: Apple's limit is off
  for a demo organization only, decided by the connection, never by the demo
  switch; every real organization keeps it (the default).
- `DemoScenario.missingPermission`: Jamf Pro, Jamf School, Intune and Apple
  refuse device reads and commands with 403.

## 0.11.0 (2026-10-27)
Step 10, first part: demo mode, for AppSettings2Blueprint. Additions, and one
safeguard for every app.
- `DemoMode` (`Demo/`): the shared "Demo Mode" switch, saved under the app's
  key. Launch arguments for UI tests: `-JTKitDemo YES` (on for this run, not
  saved), `-JTKitSandbox YES` (in-memory connections and secrets via
  `sandboxDefaults()` and `SandboxSecretStore`, no public lookups),
  `-JTKitDemoScenario jamfSchool`. `scratchDirectory`: a temporary folder per
  launch for what an app saves in demo mode. `jamfPlatform()` gives a
  `DemoSource` (connection, secret, session) in place of a saved connection.
- "— Demo" is added to every window's title while demo mode is on.
- `DemoNetwork`: a private session that answers every request inside the
  app; a host without a demo server fails, so nothing reaches the network.
- `DemoJamfPlatformServer` (from Profile2Blueprint's `DemoBlueprintServer`):
  sign-in, device groups, environments, Blueprints (paged list with search
  and sort, detail, create, merge-patch, deploy, report) with the behaviour
  seen live: no steps without a scope (400 NotBlank `scopeId`), division
  lock (409), Out of Date after a change, deployments that finish over a few
  reads, configuration-profile payloads stored as the service stores them.
- `DemoSamples`: Contoso's device groups and six Blueprints; IDs only in the
  reserved fake range, invented identifiers, checked by a test.
- `DemoModeToggle`, `ConnectionPickerLabel.demo`, and a note above Settings ›
  Connections ("These are your real connections") when the app passes its
  `DemoMode` into the environment.
- `DemoSecretStore` (never writes), `InMemoryConnectionStorage`.
- **Every app:** `ConnectionStore` refuses to save a demo connection (an ID in
  the fake range or an address on `.demo.invalid`) or to read or write its
  secret (`Connection.isDemo`).

## 0.10.0 (2026-10-26)
Step 9: Apple Business Manager and Apple School Manager, for Checkpoint (the
only app that uses them). Additions, and three safeguards for every app.
- `ABM` (`ABM/`): the two services (`ABM.Service`: address, sign-in scope,
  Release in Business only, the names in messages), serial numbers checked
  before they go into an address or a query (letters and digits; lowercase
  made uppercase).
- `ABM.TokenProvider`: the private-key sign-in (OAuth client credentials with
  an ES256-signed client assertion, 20 minutes, a new one each sign-in), the
  key read at each sign-in and kept nowhere, renewal 60 s before expiry, one
  shared sign-in, the EC-labelled PKCS#8 key from Apple School Manager. A
  refused sign-in shows only Apple's `error` and `error_description`.
- `ABM.Client` on `HTTPClient`: device, AppleCare coverage, Activation Lock
  (Apple's documented server error is no answer), assigned server, servers,
  the organization snapshot, built-in management devices and details, audit
  events. Lists follow `links.next` only on Apple's own address; an answer
  without `data` is an error, and so is reaching 1,000 pages. In a snapshot,
  a server whose list can't be read is skipped with a warning and the devices
  that may be on it get an unknown assignment (`Snapshot.unknownAssignments`).
- `ABM.Error`: the shared format (status line, `CODE: title — detail`,
  Apple's Error ID, the app's hints, then the standard ones).
- Typed, tolerant records: `OrgDevice`, `AppleCareCoverage`, `ActivationLock`,
  `MDMServer`, `ManagedDevice`, `ManagedDeviceDetail`, `AuditEvent`,
  `Snapshot`.
- The six writes (`ABM.ActivityType`, `ABM.Activity`) beside `MDMCommand`,
  with its `Confirmation`: every dialog names the organization; Release,
  Assign with Migration Deadline and Update Migration Deadline ask for the
  number from two devices; Release and Cancel Migration are red; Update
  Migration Deadline warns when the deadline is earlier. Checked before
  sending (Release in School, a missing server or deadline, more than 90
  days). Never repeated after a server error or a dropped connection, only
  after a 429. `watch`/`perform` follow Apple's job for up to 2 minutes and
  read its outcome (`ActivityOutcome`) from Apple's documented values.
- `HTTPClient`: `rateLimit` (at most N requests in a rolling window, every
  attempt counted; waits logged, Cancel stops them), `RetryRules.fixedWaits`
  and `everyNetworkErrorIsADrop` (`RetryRules.appleBusiness`: 5, 15, 45 s),
  `HTTPRequest.serverErrorIsAnAnswer`.
- `MDMCommand.Confirmation` gains `asksNumber`; Action entries can carry a
  warning (`isWarning`).
- **Every app:** the token a client sent is taken out of an error answer, the
  error message and the log wherever it appears (`RequestRecorder.send`'s
  `knownSecrets`, `Redaction.removing`); free text loses PEM private keys
  (also cut short) and signed tokens (JWTs, recognised only by their `eyJ`
  start); Apple's signed download address (`downloadUrl`, `Signature=`) is
  hidden; Apple's sign-in is a sensitive call (only method, path, status and
  duration recorded). Found by Checkpoint's tests: a sign-in error repeating
  the signed request, or an API error repeating the token, reached the log,
  the bug-report export and the message.

## 0.9.1 (2026-10-26)
Step 8 for Checkpoint: Intune devices and commands. Additions; one label change.
- `IntuneManagedDevice` (`Intune/IntuneDevices.swift`): a typed, tolerant
  device record (only `id` required) with Checkpoint's 13 fields and its
  derived values: kind (Macs and Windows are computers), ADE, still managed,
  iPhone/iPad, compliance in words, the admin center link. Dates stay as
  Graph writes them.
- `Graph.Client.intuneDevices()` and `intuneDevicesBySerial()`: the whole
  tenant with those fields, 1,000 per page, the answers recorded in the
  activity log (`list`/`listRaw` gain `recordsBodies`). By serial: any case,
  the first record wins, devices without a serial left out.
  `intuneTestConnection()` reads one device ID.
- `MDMCommand`: Intune is a product (`.intune`). Intune's own texts; its own
  names for two commands, "Sync Device" and "Retire Device" (`title(on:)`;
  confirmations use it). Which commands reach which Intune devices, each
  command's Graph request (`intuneRequest(deviceID:)`) and permission
  (`intunePermission`): PrivilegedOperations.All for every device action,
  ReadWrite.All for the new `deleteRecord` (Intune only). Wipe, Retire and
  Delete Record can't be undone: the connection is named and, from two
  devices, the number typed. No PIN on Intune.
- `Graph.Client.send(_:to:)` and `perform(_:intuneDeviceID:)`: one request per
  device; never repeated after a server error or a dropped connection, only
  after a 429; Delete Record is repeated (a 404 then means done). A refusal
  names the command's permission.
- **Changed:** Graph requests show "Intune" in the activity log's Source
  column, not "Graph" (ROADMAP step 8, "Activity log"). Intune Deployer
  shows it too once it builds against 0.9.1.

## 0.9.0 (2026-10-26)
Step 8 for Intune Deployer: Microsoft Graph and Microsoft's sign-in.
Additions, plus a new optional product. The Intune device list and commands
follow with Checkpoint (0.9.1).
- `Graph.Client` (`Intune/`) on JTKit's `HTTPClient`, so the shared retry
  rules apply (4 attempts, waits at most 120 s, `Retry-After` also as a
  date, a 401 gets a new token and one more try). v1.0 and beta addresses,
  queries such as `$select` and `$filter` sent as written, a new
  `client-request-id` with every request, at most 4 requests at a time.
  Updates (PATCH, PUT) are safe to repeat, and so are deletes, where a 404
  after a repeat counts as already gone; creates never are, `/assign` only
  when the app says so. Activity log: category "Graph", service "Intune".
- Paging: `@odata.nextLink` is followed only to `https://graph.microsoft.com`
  (anything else is refused before the token goes there); an answer without
  `value` is an error; reaching 1,000 pages is an error.
- `GraphError`: the Jamf errors' format (status line, `code: message`,
  Request ID and date, the app's hints, the standard hints). A 403 names the
  missing permission from `Graph.Permission`'s table and who grants it
  (delegated: accept at sign-in or admin consent; application: API
  permissions and admin consent). The Request ID stays visible in the
  bug-report export.
- `EntraTokenProvider`: an app registration's client secret (client
  credentials, `.default` scope, Microsoft's public cloud). Renews 60 s
  before expiry, one shared sign-in, the secret read at each sign-in, forget
  token, redirects only to HTTPS on the same host. Refused sign-ins show
  Microsoft's error code and Trace ID, with hints for a wrong or expired
  secret, an unknown app and an unknown tenant. `Graph.Client(connection:…)`
  builds both from an Intune connection.
- Never recorded, in every app: an app upload's `commit` (the app's
  encryption key), FileVault and BitLocker recovery keys, LAPS passwords.
- `HTTPClient`: `maxConcurrent` (a request keeps its turn while it waits to
  be retried); `HTTPRequest.encodedQuery` (refused if not correctly encoded)
  and `notFoundAfterRepeatIsDone`.
- New product `JTKitMSAL`, the only one depending on MSAL (pinned exactly to
  2.16.0, the newest release on 2026-10-26): `MicrosoftSignIn`, one per
  client ID. Silent token first, then Microsoft's sign-in window; one window
  at a time, shared by requests for the same permissions, while a request
  for other permissions waits for it to close and then asks again (decided
  by Jordy); after an expired sign-in the window is for the saved account;
  the saved account found again at launch; sign-out; forced refresh.
  `MicrosoftTokenSource` hands its tokens to `Graph.Client`.
  `Acknowledgement.msal` is the notice for the pinned version. Apps without
  JTKitMSAL ship nothing of MSAL, but resolve it (it is in `Package.resolved`).

## 0.8.5 (2026-10-26)
Step 7 for Jamf Deployer: the privileges its preflight and Day 0 calls
need. Additions only.
- `JamfPro.Privilege`: Read JSS URL, Create Device Enrollment Program
  Instances, Read and Create Volume Purchasing Locations, Read and Create
  Self Service Branding Configuration, Read Jamf Protect Settings, Read Jamf
  Protect Deployments and Update Jamf Protect Settings. Each is on Jamf Pro
  11.33.1's privilege list and in its API description for the call Jamf
  Deployer makes (checked by the existing privilege test). Jamf Pro has no
  privilege for App Installers, so those calls name none.

## 0.8.4 (2026-10-26)
The privilege table checked against Jamf Pro's own privilege list. One
correction every app sending Update Inventory gets, and two names removed.
- **Fixed: Update Inventory names "Send Inventory Requests to Mobile
  Devices"**, the privilege Jamf Pro has; "Update Inventory for Mobile
  Devices" doesn't exist, so a refused Update Inventory pointed to a
  privilege nobody could add. `sendInventoryRequestsToMobileDevices` is new;
  `updateInventoryForMobileDevices` is deprecated and now holds the correct
  name.
- **Removed:** `updateLocalAdminPassword` ("Update Local Admin Password") and
  `sendComputerRemoteCommand` ("Send Computer Remote Command"). Neither is a
  Jamf Pro privilege and no app used them (decided by Jordy; removed rather
  than deprecated).
- The privilege test also checks every name in the table (apart from the
  deprecated ones) against the 525 privileges Jamf Pro 11.33.1 offers for an
  API role (`Fixtures/jamf-pro-11.33.1-privilege-names.json`, names only,
  read from a test instance). Every other name, JamfMigrator's Classic-only
  ones included, is on it.

## 0.8.3 (2026-10-26)
Step 7 for JamfMigrator: the privileges its objects need, the "what to
grant" sentence, several privileges on a paged list, and requests recorded
without contents. Additions, plus one fix every app on 0.8.1 or later gets.
- **Fix: a password in a Classic API error page could show in the error
  message** (apps on 0.8.1 or later). Since 0.8.1 an HTML or XML error page
  reads as its message, but the tags were taken out before secrets were
  hidden, so `<password>…</password>` no longer marked the value as one. The
  page is now redacted first, then read. Found by JamfMigrator's own
  redaction test.
- `JamfPro.Privilege`: Read, Create, Update and Delete for every object
  JamfMigrator copies (sites, categories, buildings, departments, network
  segments, extension attributes, scripts, packages, distribution points,
  LDAP servers, accounts, users and user groups, directory bindings, software
  update servers, smart and static groups, advanced searches, configuration
  profiles, Mac and mobile device applications, eBooks, classes, restricted
  and licensed software, printers, Dock items, policies, patch titles and
  policies, enrollment customizations, PreStages, webhooks) and Read and
  Update for its settings (check-in, inventory collection, SMTP server, Self
  Service, re-enrollment, LAPS settings, onboarding, SSO). Those on the Jamf
  Pro API match Jamf Pro 11.33.1's description; the Classic-only ones are
  listed as explained exceptions in the privilege test. Added: Read Patch
  External Source and View License Serial Numbers; `viewLicenseSerial`
  ("View License Serial") is deprecated for the latter.
- `JamfPlatform.PermissionCheck.hint(for:on:signIn:)`: one sentence naming
  what to grant for several missing checks: the permissions in Jamf Account,
  or on a Jamf Pro server the privileges, on the API role for an API client
  and on the user account for a username and password.
- `allPages`, `page` and `json` take `privileges:` for a list that needs
  several; a refusal names them all. The one-privilege forms are unchanged.
- `HTTPRequest.withholdsContents` (and `RequestRecorder.send(withholdsContents:)`):
  the app marks a request to be recorded like JTKit's built-in sensitive
  calls, only method, path, status and duration, also when it fails.
  JamfMigrator uses it for licensed software, whose writes carry licence
  serial numbers.

## 0.8.2 (2026-10-26)
Step 7 for Checkpoint, part two: its remaining Jamf Pro calls, the secret
rules, copying a secret, and the privilege table checked against Jamf Pro's
own API description. Additions, plus three corrections every app gets.
- PreStages (list, scope, add, remove with the version lock), Automated
  Device Enrollment (Apple's server IDs, serial → token), compliance (feature
  switch, per device, recorded), the DDM status report (`ddmStatusItems`,
  recorded) and Jamf Pro's flattened declaration text
  (`JamfPro.flattenedDeclarations`), one declaration (`declaration(id:kind:)`,
  never recorded), sites, site moves (safe to repeat, decided by Jordy),
  department and building names (more than ten pages is an error, never a
  list cut short).
- The four secrets: `fileVaultKey`, `recoveryLockPassword`, `deviceLockPIN`,
  `localAdminAccounts`, `localAdminPassword`, `localAdminRotationTime`.
  Never recorded with contents. **A failed read carries only the status and
  JTKit's hints, never the server's text** (`JamfPlatformError.withoutServerText`,
  decided by Jordy): Checkpoint's tests showed a failed read's Action entry
  could carry the secret in the server's words.
- `JamfPro.Secret`: each secret's title, privilege and Action entry text;
  only the LAPS password `rotatesWhenViewed`, with the question to ask first.
- `SecretPasteboard.copy`: a secret on the clipboard is marked concealed
  (`org.nspasteboard.ConcealedType`), kept on this Mac (not Universal
  Clipboard), and cleared after 60 seconds if the clipboard still holds it.
- Privileges checked against Jamf Pro 11.33.1's API description (a saved
  extract of its `x-required-privileges` in the tests). Corrected:
  **Blank Push** needs "View MDM command information in Jamf Pro API" (there
  is no "Send Blank Push"; `sendBlankPush` is deprecated); **MDM commands**
  (`v2/mdm/commands`) now name both that privilege and the command's own;
  the **LAPS rotation setting** names "Read User-Initiated Enrollment", as the
  description does. Added: Read Computer and Read Mobile Device PreStage
  Enrollments. DDM status and declarations name Read Computers or Read
  Mobile Devices, by device.
- `JamfPlatformError.privileges`: a request can name several; the hint lists
  them ("one of these privileges: …"). `privilege` still reads and sets the first.

## 0.8.1 (2026-10-26)
Step 7 for Checkpoint: the MDM command list, the Platform API device calls
deferred from step 6, the Classic API basics, and Jamf School's commands,
Move to Trash and moving location. Additions, plus three changes every app
gets: more calls never recorded with their contents, Classic error pages
read as their message, and a trailing slash allowed in a request path.
- `MDMCommand`: one list of the commands (Lock and Wipe Computer, Lock,
  Wipe, Restart and Shut Down Device, Clear Passcode, Update Inventory,
  Blank Push, Renew MDM Profile, Redeploy Jamf Framework, Remove MDM
  Profile), each with its title, consequence (per product), whether it can
  be undone, its PIN, whether it works over the Platform API, the kinds of
  device it reaches and its Jamf Pro privilege.
- `MDMCommand.plan(for:on:)`: which devices receive a command before it is
  sent, and why the others don't (wrong kind of device, no management ID, no
  UDID), with the sentence the confirmation shows ("5 selected, 3 will
  receive the command; 2 have no management ID.").
- `MDMCommand.Confirmation`, the rules decided by Jordy: something that can't
  be undone (wipe, Remove MDM Profile, deleting a record) always names the
  connection, also for one device; from two devices the number has to be
  typed; a PIN is typed twice. Another action can name its connection
  without being irreversible (Jamf School's Move to Trash). `problem(…)` says
  what is still missing.
- Sending to Jamf Pro (`JamfPlatform.Client.send(_:to:pin:)`), directly or
  through the Platform API, as Checkpoint routed it; results per device
  (sent, failed with the message, not processed, skipped with the reason).
  Never repeated after a server error, only after a 429. A refusal names the
  command's privilege. `deleteComputer(id:)` (v4) and `deleteMobileDevice(id:)`
  (Classic API).
- `ActivityLog.recordCommand`: one Action entry per command, counting the
  devices it reached and naming every other one with the reason; failed when
  a device failed, a warning when devices were only skipped.
- Never recorded with contents, in every app: `v2/mdm/commands` (PIN, unlock
  token), the mobile device erase, and the Classic computer and mobile device
  commands (they can carry a passcode).
- Platform API devices: `device(serial:)` (refused, `DeviceMismatch`, when no
  returned serial matches exactly), `declarations(deviceID:)` with their
  reasons and Blueprint ID, `restart(deviceID:)` and `shutDown(deviceID:)`
  (a 422 is `DeviceActionRefused`). Refused on a direct Jamf Pro server.
- `JamfClassic`: paths (`…/id/{id}`, create on `/id/0`), the new `<id>`, the
  message of an HTML or XML error page, list unwrapping, and groups and their
  members (asked for as JSON). `JamfPlatformError` shows a Classic error
  page's message instead of its markup, in every app.
- Jamf School: commands (`refresh`, `restart` with `clearPasscode=false`,
  `wipe` with `clearActivationLock=false`, `unenroll`), Move to Trash
  (`DELETE devices/{udid}/`) and moving location (JSON, twenty per request,
  per-device outcome). `recordsDeviceAnswers` records the device list and
  details also when they succeed (Checkpoint's lookups).
- Privileges added: View MDM command information in Jamf Pro API, Unmanage
  Mobile Devices, Send Command to Renew MDM Profile, Send Computer Remote
  Command to Install Package.
- `RequestPath` allows one trailing slash (Jamf School's Move to Trash).

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
