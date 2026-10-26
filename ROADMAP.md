# JTKit roadmap

The order in which shared code moves into JTKit, where each piece comes from, and which apps adopt it. Claude: read this together with CLAUDE.md. Jordy: the prompts are in "How to run a step" below.

Sources were chosen from the code (October 2026): prefer the copy with tests and the most robust handling, and take *coverage* (which calls exist) from wherever it is widest.

## Standards for every app

Decided by Jordy on 2026-10-25. They apply to the eight macOS apps: AppSettings2Blueprint, Blueprint Managed Preferences Editor, Checkpoint, Intune Deployer, Jamf Deployer, JamfMigrator, Profile2Blueprint, Serial Number Reader. IntuneOnboard and Device Assist are out of JTKit entirely.

- **About:** one JTKit About window in every app, opened only from the app menu ("About [App]"). Never a page inside the app, and not listed in the Window menu.
- **Copyright:** JTKit's About window writes the copyright line itself, "© [year] [author]. Released under the [licence].", from what the app passes in (MIT by default). It does not read the app's `NSHumanReadableCopyright`.
- **Settings:** one JTKit Settings window (⌘,) with tabs in the toolbar: General always first, then the app's own tabs, the Updates tab always last, the same width in every app (680 points, room for a list beside an editor). Diagnostics and troubleshooting (support bundles, bundled tool versions) go in an "Advanced" tab just before Updates.
- **Appearance:** JTKit's Appearance picker (System / Light / Dark) always starts the General tab; the app's own general settings go below it. JTKit applies the choice to the whole app (every window, About and Settings included) and saves it under "appearance". Apps keep no appearance setting of their own. Connection settings go in a "Connections" tab.
- **Acknowledgements:** the same JTKit view inside About, in every app with third-party code, with full licence texts.
- **Updates:** "Check for Updates…" in the app menu. The daily-check switch in Settings, using JTKit's Updates section. About shows the version only.
- **Connections:** every app that connects to Jamf, Intune or Apple Business/School Manager uses the same JTKit connections list and editor, with several services in one list. Built in step 4 with saved connections.
- **Connection menu:** every app with a connection picker in its main window (toolbar or sidebar) also has JTKit's "Connection" menu in the menu bar, with the same items as the picker: the saved connections with the one in use checked (one section per role, e.g. Source and Destination), then "Edit Connections…", which opens Settings › Connections. The toolbar picker is JTKit's `ConnectionPicker`, the menu `ConnectionCommands`; both show `ConnectionMenuItems`. Added by Jordy on 2026-10-25, in 0.5.2. JamfMigrator and Profile2Blueprint (step 4 done before it existed) switch to it on their next JTKit update; Profile2Blueprint's own "Tenant" menu then goes. An app's own items go in the picker's slot below the connections, shown in the menu too (from 0.6.0; Profile2Blueprint's "Offline Demo Mode"); no app keeps a picker of its own. **Not in Jamf Deployer, on purpose** (decided by Jordy on 2026-10-25): it manages a fleet, with no single connection in use, so it has no connection picker, no Connection menu and no "Use This Connection"; its sidebar is for moving between tenants and its "Tenant" menu stays.
- **"All" in a connection picker:** a role that can use every connection at once (Checkpoint's "All Organizations" and "All Connections") offers "All" below its connections in the picker and the Connection menu, dimmed until there are two or more. "All" lasts for the current session only and is never saved: the app remembers only the single connection chosen, so at launch it falls back to the last single connection used, and a combined read is never a surprise at launch. Built into JTKit 0.5.3 (`AllConnectionsChoice`) so every app behaves the same. Decided by Jordy on 2026-10-25.
- **Activity log:** every app that connects to those services has the same JTKit activity log window (⌘⇧L), filled automatically by JTKit's networking, with a bug-report export that masks device identifiers (from Checkpoint). It is kept in memory only and Clear wipes it. Export: "Export for Bug Report…" (masked) is the main item, "Export Unmasked…" is clearly labelled; copying one entry is unmasked. Built in step 5. It replaces the request logs in AppSettings2Blueprint and Blueprint Managed Preferences Editor, Checkpoint's log and Profile2Blueprint's Activity section. Profile2Blueprint's migration history stays.
- **Design-review fixes** change only JTKit's shared look, never a single app.

## How to run a step

Always work in `~/Developer/Apps.xcworkspace`. Pick the scheme of the app being changed (or **JTKit** to run the package tests).

1. **Branch.** In the Source Control navigator (⌘2), create a branch named after the step (for example `jtkit-keychain`) in JTKit *and* in the first app of that step.
2. **Dry run.** Prompt:
   > Dry run of step N in JTKit/ROADMAP.md. Change no files. Show what you'd add to JTKit, what changes in [first app], what I could notice in the app, and how you'll test. Wait for my go.
3. **Go.** Prompt:
   > Go with step N for [first app]. Run JTKit's tests and [first app]'s build and tests in the workspace, then stop before committing or tagging so I can check the app.
4. **Check by hand.** Run the app (⌘R) and go through that step's "check by hand" list below.
5. **Approve.** Prompt:
   > Approved. Commit JTKit, tag the next version, push with tags. Update [first app] to that JTKit version, run its tests, and commit it on the branch.

   Then merge both branches into main (Source Control navigator: right-click main, "Merge from branch…").
6. **Adopt in the other apps**, one app per prompt, each on its own branch:
   > Step N, adopt in [app]: replace [app]'s own copy with JTKit's, keep saved settings and Keychain names, build and test, then stop so I can check.

   Approve the same way as 5 (no new JTKit tag needed unless JTKit changed).

**An app's first JTKit step:** before the prompt (dry run or go), Jordy adds the package to that app in Xcode: select the app's project, Package Dependencies, +, enter `https://github.com/JordyThery/JTKit.git`, choose "Up to Next Major Version" from the current JTKit version, and add the JTKit library to the app target. Claude doesn't edit `project.pbxproj` itself.

Rules that apply to every step: everything in CLAUDE.md, especially "preserve stored data" and "nothing app-specific in JTKit".

## Steps

### Step 1: Updater (0.2.0), in progress
- **Source:** AppSettings2Blueprint (newest fixes incl. suffixed tags like `1.2.1-hotfix`; has tests).
- **First app:** AppSettings2Blueprint.
- **Then:** Blueprint Managed Preferences Editor, Checkpoint, Intune Deployer, JamfMigrator, Profile2Blueprint, Serial Number Reader. Jamf Deployer last: its copy lives in DeployerKit (see step 2).
- **Check by hand:** Check for Updates from the menu (and from About, until step 3 removes it there) says "up to date"; the daily-check toggle survives a relaunch.

### Step 2: Fold in DeployerKit (0.3.0)
`Jamf Deployer/DeployerKit` is an earlier shared package (tested, macOS 15, Swift 6.2 with main-actor default isolation). Intune Deployer was meant to use it but doesn't.
- **Move:** ActivityLog + ActivityLogView, GuidedTour, DesignSystem components (StatusBadge etc.), TextExportDocument, JSONFile.
- **Decision (2026-10-25):** JTKit stays at macOS 14 (macOS only since step 3): nothing in the moved code needs macOS 15 or Swift 6.2. It moves up only when all apps move together. JTKit keeps Swift tools 6.0 and marks UI state `@MainActor` explicitly instead of DeployerKit's main-actor default.
- **First app:** Jamf Deployer (switch its DeployerKit imports to JTKit; DeployerKit keeps only what is Jamf Deployer-specific, or goes away).
- **Then:** Intune Deployer (GuidedTour, ActivityLog), JamfMigrator (GuidedTour).
- **Not replaced here:** Checkpoint's activity log (a bug-report log that masks device identifiers on export) stays until step 5, where JTKit's log gains that export and replaces it. Profile2Blueprint's activity (a saved migration history) stays in the app for good; JTKit's in-memory log is not a substitute.
- **Design:** run the apple-design review on the moved components; they become the shared look of all apps.
- **Check by hand:** guided tour runs start to finish; activity log fills, exports and clears.
- **Later (changes the look, so every app at once):** from the step 2 design review: make the yellow warning and green success icons stand out more on light backgrounds (for example the multicolour warning symbol); decide whether the update sheet uses the SheetFrame header like the other sheets. Done in 0.6.0 (step 5): the failure icon next to failed statuses in the activity log, and the activity log's Clear in the menu bar.

### Step 3: App shell (0.4.0)
- **Move:** About window (with the copyright line), acknowledgements, the Settings window with its General tab (Appearance) and its Updates tab (see "Standards for every app"). No logging section: no app has one. The connections list is built in step 4.
- **Source:** AppSettings2Blueprint (About and acknowledgements have unit and UI tests); options from Jamf Deployer's About (disclaimer, credits list) and Profile2Blueprint's About.
- **Also:** JTKit drops iOS and becomes macOS 14 only.
- **First app:** AppSettings2Blueprint: its update controls move from About to Settings.
- **Then:** Blueprint Managed Preferences Editor, Checkpoint, Intune Deployer, Jamf Deployer, JamfMigrator, Profile2Blueprint, Serial Number Reader. Apps that use the standard macOS About panel switch to JTKit's About window. Profile2Blueprint drops its sidebar About page and its standard panel, and gets a Settings window for the Updates section.
- **Licences, added as each app adopts step 3** (full texts in About, and next to bundled copies):
  - Jamf Deployer: jamformer (MIT, Copyright (c) 2026 Jamf Software LLC, github.com/Jamf-Concepts/jamformer), whose licence is missing next to the bundled copy and in the app; check jamformer's own credits for components that need their own notice. The Terraform providers' licence texts (jamfpro, jamfplatform, jamfprotect; MPL-2.0) are missing too. OpenTofu and terraform-backend-git are already copied into the bundle.
    - Done in Jamf Deployer (2026-10-25): About also credits Go, HCL, terraform-exec and go-api-sdk-jamfpro, the libraries jamformer's own credits name as compiled in. **To raise with Jamf Concepts:** jamformer's download ships no notices for its other compiled-in libraries (about 100, among them Jamf's jamfplatform and jamfprotect Go SDKs, gitleaks and parts of the AWS SDK).
  - Intune Deployer: MSAL (MIT, Microsoft Corporation).
  - JamfMigrator: Replicator (MIT, Jamf Professional Services).
  - AppSettings2Blueprint: App Settings Utility (MIT, Anthony Darlow), already complete.
- **Check by hand:** About opens only from the app menu and shows the right name, version, links and acknowledgements; it is not in the Window menu. Settings opens on General with the Appearance picker first, and the chosen appearance applies to every window, About included, and survives a relaunch. The daily-check switch is in Settings and survives a relaunch; "Check for Updates…" in the app menu says "up to date".

### Step 4: Keychain and saved connections (0.5.0), done
- **Done (2026-10-25):** in all eight apps, Intune Deployer last, with JTKit 0.5.0 to 0.5.5. Still open: JamfMigrator and Profile2Blueprint switch to the shared picker and Connection menu on their next JTKit update (see "Standards for every app").
- **Also builds** the shared connections list and editor for Settings: one list holding several services (Jamf Pro, Jamf Platform, Jamf School, Intune, Apple Business/School Manager), with add, delete, edit, test and "use this connection". It replaces each app's own connections screen; Profile2Blueprint's sidebar tenants move to it too. Start from AppSettings2Blueprint's and Blueprint Managed Preferences Editor's list (same shape); take services from Checkpoint (ABM/ASM and MDM lists) and Serial Number Reader. It lives in the shared Settings window's "Connections" tab.
- **Labels:** some apps show field labels such as "Environment ID" and "Network ID" in a code-style (monospaced) font, for example Serial Number Reader. The shared connections screen uses normal labels.
- **Source:** JamfMigrator `SecretStore` (protocol with an in-memory fake for tests) and `Tenant`/`TenantStore` (tested). Fold in fields from Jamf Deployer's `Tenant` (Platform API, Protect) and Intune Deployer's `TenantStore`.
- **Critical:** every app keeps its own Keychain service and account names and its saved-connections file/keys. Losing them logs users out.
- **First app:** JamfMigrator. **Then:** Profile2Blueprint, AppSettings2Blueprint, Blueprint Managed Preferences Editor, Serial Number Reader, Checkpoint, Jamf Deployer, Intune Deployer.
- **Check by hand:** before switching, save a connection with the old build; after switching, it is still there and still connects. Settings shows the shared connections list.

#### Design (decided by Jordy on 2026-10-25)

**What JTKit adds**
- **Connection:** one record type with an id, a name, a service and a sign-in method, plus the fields services need: server URL, region, Environment ID, host override, Jamf Pro web address (for links), client ID, username, Entra tenant ID, Apple key ID, and an optional Jamf Protect add-on (URL, client ID). No secrets in the record. App-specific per-connection settings (Profile2Blueprint's naming, Jamf Deployer's deployment data, Intune Deployer's baseline) stay in the app.
- **Services:** Jamf Platform API (its own service, not a Jamf Pro sign-in method), Jamf Pro (server URL), Jamf School, Intune, Apple Business Manager, Apple School Manager. Each app passes in the services it supports; the + menu offers only those.
- **Sign-in methods:** API client (OAuth client credentials), username and password, Jamf School Network ID + API key, Entra app with client secret, interactive Microsoft sign-in (no stored secret; the app does the sign-in until step 8), Apple private key (client ID, key ID, .pem).
- **Jamf Protect:** an optional part of a Jamf connection. Only apps that turn it on (Jamf Deployer) show it.
- **SecretStore:** protocol plus an in-memory fake for tests (from JamfMigrator), and a Keychain store. The app passes in, for each kind of secret (main secret, Protect secret, Apple private key), the exact Keychain service and account name, and its current accessibility setting. JamfMigrator's move from the data-protection keychain stays an option.
- **Storage adapters:** JTKit reads and writes each app's list **where it is today**, in its current format and field names. Built in: a JSON file and a UserDefaults key, with field names passed in. Apps with an unusual layout supply a small adapter of their own (Checkpoint: two lists; Jamf Deployer: one folder per tenant; Serial Number Reader: single settings). Adapters change only the connection fields and keep every other field of the app's record.
- **Connections store** (`@MainActor`): add, edit, delete (also deletes the connection's secrets), secrets read and write, and "in use" roles named by the app: one "Active" role in most apps, "Source" and "Destination" in JamfMigrator, one for Apple and one for MDM in Checkpoint (including "All").
- **Safety rule, built first in 0.5.0:** if the saved list can't be read, JTKit sets it aside as a copy, shows an error and refuses to save over it. It never turns an unreadable list into an empty one.
- **One-time backup:** the first time an app saves connections through JTKit, JTKit makes a backup copy of the app's existing data next to the original (file: a copy beside it; UserDefaults: a copy under a backup key), once.
- **Connections tab:** list beside an editor in the 680-point Settings window, from AppSettings2Blueprint's layout. Rows show a service icon, the name and the service with region or host. Editing works on a draft with Save and Revert in every app (no save on every keystroke). Buttons: Test Connection (the app supplies the test until steps 5–9 bring JTKit's networking), "Use This Connection" for each role, Revert, Save; deleting asks first. Apps can add their own section below the shared fields and replace what + does. Normal-font labels. Run the apple-design review on the new views.

**Per app**
- **Pickers stay:** every app keeps its connection pickers in the main window (toolbar or sidebar); Settings adds "Use This Connection", including JamfMigrator's Source/Destination and Checkpoint's "All". Each picker gets the shared Connection menu in the menu bar (see "Standards for every app").
- **JamfMigrator:** `tenants.json` in Application Support/JamfMigrator (keys `id, name, region, environmentId, clientId, serverURL, username, isProtected`); selections `sourceTenantID`, `destTenantID`; Keychain service `JamfMigrator-tenant`, account = tenant UUID. `isProtected` becomes an app section in the editor. The editor moves from save-on-every-keystroke to Save/Revert.
- **Profile2Blueprint:** `tenants.json` in Application Support/Profile2Blueprint with `currentTenantID`; Keychain `be.jordythery.profile2blueprint.oauth-client-secret`, account = tenant UUID. Naming, description and classic-cleanup become an app section in the shared editor. Tenants leave the sidebar; a toolbar picker chooses the current tenant.
- **AppSettings2Blueprint:** UserDefaults `connectionProfiles`, `selectedConnectionProfileID`; Keychain `AppSettings2Blueprint.client-secret`, account = profile UUID.
- **Blueprint Managed Preferences Editor:** the same keys; Keychain `Blueprint Managed Preferences Editor.client-secret`, account = profile UUID.
- **Serial Number Reader:** becomes a list with an active connection. One-time conversion: each filled-in sign-in method in the old keys (`jamfServerURL`, `jamfAuthMethod`, `jamfClientID`, `jamfUsername`, `jamfPlatformRegion`, `jamfPlatformClientID`, `jamfPlatformEnvironmentID`, `jamfSchoolURL`, `jamfSchoolNetworkID`) becomes a connection, and the current `jamfAuthMethod` becomes the active one. Secrets are copied from service `be.jordythery.SerialNumberReader.jamf` (accounts `clientSecret`, `jamfPassword`, `jamfPlatformClientSecret`, `jamfSchoolAPIKey`) to per-connection items. Old keys and Keychain items stay untouched, so an older build keeps working.
- **Checkpoint:** `jamfServers` and `abmOrgs` (UserDefaults) shown as one list in one Connections tab (the "Apple" and "MDM" tabs go). Keychain `DeviceStatus.secrets`, accounts `jamf.<UUID>` and `abm.<UUID>`. Roles "Apple" and "MDM", each with "All" (session only, see "Standards for every app"); the single connections chosen are saved under `appleConnectionChoice` and `mdmConnectionChoice`. The one-time move of the legacy `abmConfig` and Keychain item `abm.privateKey` stays as it was, except that it never runs over an `abmOrgs` that can't be read. The Apple private key is imported from its .pem file and never shown.
- **Jamf Deployer:** tenants stay in `store/tenants/<UUID>/tenant.json` (a Git repository shared with the team). The adapter writes these files **byte-for-byte as today** (same key order and formatting) and changes only the connection fields. Settings › Connections lists the tenants for editing, testing and deleting; its + opens the "Connect a Tenant" wizard; the sidebar stays for deployments. URL, region, scope and connection kind stay read-only after connecting. Keychain services `be.jordythery.jamf-deployer.platform-client-secret` and `.protect-client-secret`, account = tenant UUID; its other Keychain items stay app-only. No connection picker or Connection menu, because it manages a fleet (see "Standards for every app"). In Team Mode the client ID is read-only in Settings: each engineer's own one stays in "Update Client Secret…". The one-time backup goes to `Application Support/Jamf Deployer/connection-backup`, outside the shared repository, and unreadable files are left in place, not copied aside.
- **Intune Deployer:** `tenants.json` in Application Support/Intune Deployer, `selectedTenantProfileID`. Connection fields, import and export move to Settings › Connections; the baseline settings stay in the app; Sign In stays in the toolbar (MSAL keeps its own token cache; nothing to carry over).

**Check by hand (each app, in addition to the above):** a backup copy of the old data appears next to the original after the first save; Save and Revert work; "Use This Connection" matches the main-window picker. Jamf Deployer: after editing a tenant's name, `git diff` of its `tenant.json` shows only that line.

### Step 5: Jamf login and HTTP basics (0.6.0)
- **Move:** token providers (OAuth client credentials and username/password, token renewal), HTTP client with retry and `Retry-After`/429 handling, secret redaction in logs.
- **Activity log standard:** JTKit's networking fills JTKit's `ActivityLog` automatically. Every app that connects to Jamf, Intune or ABM/ASM gets the same activity log window (⌘⇧L) with a bug-report export that masks device identifiers. It replaces AppSettings2Blueprint's and Blueprint Managed Preferences Editor's request logs and Checkpoint's activity log. Profile2Blueprint's migration history stays.
- **Source:** Profile2Blueprint `TokenProvider` + `HTTPClient` and JamfMigrator `TokenProvider` (both tested); AppSettings2Blueprint `RequestLog` + `LogRedactor` (tested; what a request entry records); Checkpoint `ActivityRedaction` + `IdentifierMasker` for the masked bug-report export.
- **First app:** Profile2Blueprint. **Then:** JamfMigrator, AppSettings2Blueprint, Blueprint Managed Preferences Editor, Serial Number Reader, Checkpoint, Jamf Deployer, Intune Deployer.
- **Check by hand:** connect with an API client and with a user account; the activity log (⌘⇧L) fills by itself and shows no secrets; the bug-report export masks serial numbers and other device identifiers.

#### What the apps do today (surveyed 2026-10-26)

**Profile2Blueprint**
- **Sign-in:** API client on the Platform API only. `Services/Auth/TokenProvider.swift` (actor, 143 lines): renews with 60 s to spare, one shared sign-in for simultaneous requests, secret read from the Keychain at each sign-in, `invalidate()`. `Services/API/HTTPClient.swift` (262 lines): bearer + `X-Environment-Id`, an allow-list of permitted writes.
- **Retries:** at most 3, 1 s doubling to 30 s; 429 for every method, 502/503/504 for GET only; network errors not retried; 401 → new token, one more try. `Retry-After` in seconds only. Waits injectable for tests.
- **Logging:** own `ActivityLog` with `ActivityEvent` (method, path, status, duration, category, message; no bodies or headers), saved to `activity.json` (10,000 events), shown in the sidebar's Activity section, exported as Markdown or JSON. Migration history separately in `history.json`. `os.Logger` (auth, network, app).
- **Redaction:** `Redactor` (`Services/API/Redactor.swift`): `access_token`, `client_secret`, `refresh_token`, `id_token` in JSON and forms, `Bearer …` in free text; no passwords. Tests: `NetworkingTests` (11), `ModelTests`, `ActivityAndCleanupTests`; own `MockURLProtocol`.

**JamfMigrator**
- **Sign-in:** API client and username/password, via the Platform API gateway or straight to Jamf Pro. `Platform/TokenProvider.swift` (actor, 167 lines): both token formats, renews after 80 % of the lifetime, shared sign-in. `Platform/PlatformClient.swift` (actor, 253 lines): gateway/direct mapping (`pro/` → `api/`, `proclassic/` → `JSSResource/`), XML, redirects refused, writes spaced 200 ms.
- **Retries:** 4 attempts, linear 1 s, 2 s, 3 s; 429 for every method, 5xx for GET/PUT/DELETE; 401 → one retry; `Retry-After` in seconds, no cap. Tests: `TokenProviderTests` (6), `PlatformClientTests` (8), `DirectConnectionTests` (6) and more, with its own `MockHTTP`.
- **Logging:** no request log. Free-text file `~/Library/Logs/JamfMigrator/jamfmigrator.log` (`WriteToLog`, `Support/Support.swift`): update checks, Keychain and tenant-store failures, per-type migration failures, export and journal write failures. Run progress list in memory only.
- **Redaction:** none. A failed sign-in shows up to 300 characters of the server's answer (`TokenProvider.swift:130`).

**AppSettings2Blueprint**
- **Sign-in:** API client on the Platform API, in `API/PlatformAPIClient.swift` (actor, 284 lines): renews with 60 s to spare, shared sign-in, `RequestAllowList` (also refuses `..` and encoded slashes).
- **Retries:** 4 attempts, doubling plus up to 0.5 s randomness, at most 30 s; 429 always; 5xx and short network drops for reads and patches, never for create or deploy; `Retry-After` in seconds, at most 30; 401 → one retry. Waits injectable.
- **Logging:** `RequestLog` (500 entries, in memory): full URL, request and response headers and bodies, error, duration, attempt. Window "Request Log" (⇧⌘L) with a list and a detail pane; Clear only, no export. App Store lookups (`Lookup/AppStoreClient.swift`) are not logged and not retried.
- **Redaction:** `LogRedactor`: Authorization keeps its scheme, cookies hidden whole; `client_secret` in forms; token keys and `client_secret` in JSON at any depth; query strings and non-JSON text not redacted. Tests: `NetworkingTests` (12), `BlueprintWriteTests`, `JSONValueTests`.

**Blueprint Managed Preferences Editor**
- An older copy of AppSettings2Blueprint's client, log and redactor: same sign-in, retries and Request Log window. Missing: the allow-list, injectable waits and the cookie fix (a `Cookie:` header still shows the session value). No client tests.

**Checkpoint**
- **Sign-in:** `API/JamfClient.swift`: API client, username/password (Jamf Pro) and the Platform API; 60 s margin, shared sign-in, no retry after a 401. `Model/LookupModel.swift` caches clients under a key containing the plain-text secret and never drops old ones. Jamf School (`JamfSchoolClient`: Network ID + API key), Intune (`IntuneClient`: app sign-in) and Apple Business/School Manager (`ABMClient`: signed key) each send with their own `URLSession.shared` code.
- **Retries:** Jamf Pro and Jamf School none. Intune: 429 only, 3 times, at most 30 s. Apple: at most 18 requests a minute, 429/503 retried after 5, 15, 45 s, network errors for GET only.
- **Logging:** own `ActivityLog` (`Support/ActivityLog.swift`, 1,000 entries, in memory, ⌥⌘L): every request from all four clients with redacted bodies; sign-ins without bodies; actions from `LookupModel`. Bodies withheld for the sensitive Jamf calls. Copy / Copy masked / Export / Export masked; the export has no app or macOS version.
- **Redaction:** `ActivityRedaction`: 16 secret keys (passwords, PINs, unlock and escrow tokens, recovery keys, client assertions), personal blocks (owner, location, notes, actor and subject names); non-JSON text not scrubbed; bodies over 256 KB not recorded, text cut at 20,000 characters. `IdentifierMasker`: serials, UDIDs, IMEI/MEID/EID, MAC addresses, by key and in paths; `<device N>` at export only; connection name and notes not masked. No tests.

**Serial Number Reader**
- **Sign-in:** `JamfClient.swift` (actor): API client, username/password, the Platform API; 30 s margin; simultaneous sign-ins not shared; 401 → one retry. `JamfSchoolClient.swift`: Network ID + API key.
- **Retries:** none beyond the 401 retry; a 429 is an error.
- **Logging:** `os.Logger` only. `USBDeviceMonitor.swift:288-291` logs the USB serial descriptor as public.
- **Redaction:** none. No fake network for tests; the clients build their own sessions.

**Jamf Deployer**
- **Sign-in:** `App/API/JamfPlatformClient.swift` (actor): Platform API, Jamf Pro API client and username/password; strict form encoding (a `+` in a secret survives); only same-host HTTPS redirects; `X-Environment-Id` or `X-Tenant-Id`. Ten places each make a new client, so a new sign-in each time, and simultaneous sign-ins aren't shared. OpenTofu and jamformer sign in themselves with secrets in environment variables.
- **Retries:** 4 attempts; 429 for every method, 503/504 and network drops for GET only; `Retry-After` in seconds, at most 300; otherwise doubling plus randomness, at most 60 s.
- **Logging:** JTKit's `ActivityLog`: "API" (method, path, status, duration, attempt; no bodies), "Engine", "Export", "Adopt", "Team". Exported in the Support Bundle. Engine output in `history/<id>/log.jsonl`; `PlanRedactor` cleans plan files (a different job, stays).
- **Keychain:** six items, all through DeployerKit's `KeychainItem` ("when unlocked", no label): `platform-client-secret`, `protect-client-secret` (also read by Settings › Connections through `KeychainSecretStore`), `engineer-client-id`, `state-passphrase`, `block-setting` (account `<UUID>.<block>.<key>`, deleted by prefix) and `team` / `state-passphrase`, all under `be.jordythery.jamf-deployer.`.

**Intune Deployer**
- **Sign-in:** no Jamf. MSAL interactive sign-in (`Auth/AuthManager.swift`), no stored Entra secret. `Graph/GraphClient.swift` (actor): at most 4 requests at a time.
- **Retries:** 5 attempts; 429, 503, 504 and network drops; `Retry-After` in seconds, at most 300.
- **Logging:** JTKit's `ActivityLog`, one "Graph" entry per attempt written by `GraphClient` (path, status, duration; no bodies or tokens). GitHub (`Sources/GitHubClient.swift`) and Azure blob uploads are not logged.
- **Keychain:** GitHub token in `Sources/GitHubTokenStore.swift` with its own Keychain calls: service `be.jordythery.intune-deployer.github`, account `personal-access-token`, "when unlocked"; trimmed, empty deletes. MSAL keeps its own cache.

#### Design (decided by Jordy on 2026-10-26)

**What JTKit adds**
- **Request recorder** (`Core/`): sends one request, times it, redacts it and adds an entry to the activity log. No retries. It is the layer under the HTTP client, and the one apps' own Intune, Apple, Jamf School and GitHub code switch to until steps 7–9: only the line that sends the request changes.
- **HTTP client** (`Core/`), on top of the recorder: token, retries, `Retry-After`/429, one retry after a 401. Options: allow-list of permitted requests (paths with `..` or encoded slashes always refused), redirects (follow, same-host HTTPS only, refuse), spacing between writes, extra headers (`X-Environment-Id`, `X-Tenant-Id`), Jamf Pro direct mapping. Injectable session and waits for tests. Source: Profile2Blueprint `HTTPClient` and JamfMigrator `PlatformClient`, with AppSettings2Blueprint's network-drop retries and path check and Jamf Deployer's redirect rule.
- **One retry rule set for every app:** at most 4 attempts. 429 is retried for every method. 5xx and short network drops only for reads and for edits an app marks as safe to repeat. A 401 gets a new token and one more try. `Retry-After` read as seconds and as an HTTP date (new), otherwise doubling with randomness; every wait at most 120 s. Each wait is written to the activity log ("waiting 12 s, attempt 2 of 4") and Cancel in the app stops it at once. Apple Business/School Manager's own 18-a-minute throttling and Intune Deployer's 4-at-a-time limit stay in the apps until steps 8 and 9.
- **Jamf token provider** (`Jamf/`): API client (Jamf Pro `/api/oauth/token`, Platform API `/auth/token`) and username/password (`/api/v1/auth/token`); both token formats; renews with 60 s to spare; one shared sign-in for simultaneous requests; secret read when needed; forget token. Made from a JTKit `Connection` and its secret. Source: JamfMigrator `TokenProvider` and Profile2Blueprint `TokenProvider`, with Jamf Deployer's strict form encoding. Jamf School's fixed header stays in the apps until step 7.
- **Redaction** (`Core/`): headers (Authorization keeps its scheme, cookies whole), form fields, JSON at any depth, XML elements (Classic API), free-text tokens, secret query parameters. Keys: AppSettings2Blueprint's and Checkpoint's lists together. Error messages shown to the user go through it too. Source: AppSettings2Blueprint `LogRedactor` (with the cookie fix), Checkpoint `ActivityRedaction`, Profile2Blueprint `Redactor`.
- **Never recorded, in every app:** the contents of Checkpoint's sensitive calls (mobile device detail with unlock token, erase, FileVault recovery key, lock PIN, Recovery Lock password, LAPS password), built into JTKit, not chosen per app. Only method, path, status and duration are logged for them.
- **What an entry records:** JTKit's `ActivityLogEntry` gains optional request details: full URL, attempt, redacted request and response headers and bodies, error, service, connection, a "contents withheld" mark and the identifiers found. Additions only. Bodies over 256 KB are not recorded; recorded text is cut at 20,000 characters. In memory only; Clear wipes it.
- **Identifier masker** (`Core/`): collects identifiers when an entry is recorded and replaces each with a stable placeholder (`<device 1>`, `<user 1>`, …) at export. Masks serial numbers, UDIDs, IMEI/MEID/EID, MAC addresses (Checkpoint), plus email addresses, usernames and full names (`username`, `realName`, `email`, `userPrincipalName`), IP addresses, and device names only in fields that clearly hold one (`deviceName`, `computerName`, a device record's `name`), never a generic `name`. Applies to the detail, URL, connection name, notes and bodies. Source: Checkpoint `IdentifierMasker`, with tests written as it moves.
- **Activity log window:** a shared window scene and menu item (⇧⌘L), the table with a detail pane (from AppSettings2Blueprint's), Clear, "Export for Bug Report…" (masked, main item) and "Export Unmasked…"; copying one entry stays unmasked. The export header has the app name, app version and macOS version. Run the apple-design review on it.
- **Keychain:** `KeychainSecretStore` (and the in-memory fake) can delete every item whose account starts with a prefix, for Jamf Deployer's block settings.

**Decided by Jordy on 2026-10-26, at the start of step 5 (built in 0.6.0)**
- **Bodies in the log, the same in every app:** request bodies are never recorded, and response bodies only for errors (status 400 and up). An app can record both bodies of specific requests it marks as safe (`HTTPRequest.recordsBodies`). Reason: bodies can carry secrets no key list finds, such as a Wi-Fi password, VPN secret or SCEP challenge inside a configuration profile. Profile2Blueprint keeps the default.
- **Activity log window:** a search field and "Problems Only" (failures and warnings), no category filter. Search matches every column, the source (category) included, plus the service, the connection and the address.
- **Warnings:** an entry can carry an optional warning mark (`isWarning`), shown with a yellow warning symbol, e.g. a wait before a retry or a refused request.
- **Toolbar picker, no exception:** JTKit's `ConnectionPicker`, `ConnectionMenuItems` and `ConnectionCommands` have an optional slot for the app's own items below the connections, and the picker an optional label shown instead of the connection in use. Profile2Blueprint uses the shared picker and Connection menu with "Offline Demo Mode" in that slot; its own picker goes.
- **From the design review of the window:** its actions are in the menu bar too (File › Export Activity Log for Bug Report… / Export Activity Log Unmasked…, Edit › Clear Activity Log…, View › Show Problems Only), ⌘C copies the selected entry unmasked, and a failed status shows a failure symbol beside its red number.

**Per app (fixes made when the app adopts)**
- **Profile2Blueprint:** JTKit token provider and client; its Activity sidebar section and `activity.json` give way to the shared window. The old `activity.json` stays on disk untouched. The migration history stays.
- **JamfMigrator:** JTKit token provider and client, one per tenant (Source and Destination each have their own sign-in and token; rebuilt after an edit, dropped on delete); gets the activity log. The failed sign-in message goes through redaction. **Text log (decided by Jordy on 2026-10-26):** first save each run's report to disk, then retire the text log. Every run, also a stopped one, saves a redacted report to `Application Support/JamfMigrator/Run Reports/` (what was created, changed, deleted, skipped and failed, plus warnings), so a record of each run survives quitting. `jamfmigrator.log` is retired: its lines go to the activity log, and the existing file is left on disk. Done 2026-10-26 with JTKit 0.6.0.
- **AppSettings2Blueprint, Blueprint Managed Preferences Editor:** JTKit client; the Request Log becomes the Activity Log. Blueprint Managed Preferences Editor gains the allow-list and the cookie fix. App Store lookups go through the recorder.
- **Serial Number Reader:** JTKit token provider and client; gets the activity log; Jamf School through the recorder. The USB debug message stops logging the serial number publicly.
- **Checkpoint:** Jamf Pro sign-in and sending on JTKit (its endpoints stay until step 7); Intune, Apple and Jamf School through the recorder; its own log goes; the shortcut moves from ⌥⌘L to ⇧⌘L. Clients are no longer stored under a key containing the secret: one JTKit client per connection ID, dropped when the connection is edited or deleted.
- **Jamf Deployer:** one JTKit client per tenant instead of a new one in each of ten places. All six Keychain items move to `KeychainSecretStore` with the same service and account names and "when unlocked"; the app keeps "empty deletes". DeployerKit then holds only the version comparison, which moves into the app; Jordy removes the DeployerKit package when asked.
- **Intune Deployer:** `GraphClient` and the GitHub client log through the recorder; Graph retries stay until step 8. The GitHub token moves to `KeychainSecretStore` (same service and account, "when unlocked"); trimming and "empty deletes" stay in the app. MSAL's cache is untouched.

**Check by hand (each app, in addition to the above):** a wait after a 429 shows in the log and Cancel stops it; "Export for Bug Report…" masks serials, emails and device names but not Blueprint or group names; Clear empties the log. Jamf Deployer and Intune Deployer: saved Keychain items are still there after switching.

### Step 6: Jamf Platform API (0.7.0)
- **Source:** JamfMigrator `PlatformClient` (regions, polling, permission probe, gateway errors; tested). Add Blueprint and device-group calls from AppSettings2Blueprint, Blueprint Managed Preferences Editor, Profile2Blueprint and Jamf Deployer.
- **First app:** JamfMigrator. **Then:** AppSettings2Blueprint, Blueprint Managed Preferences Editor, Profile2Blueprint, Jamf Deployer.
- **Check by hand:** list Blueprints and device groups; one harmless write on a test tenant.

### Step 7: Jamf Pro, Jamf School and device actions (0.8.0)
- **Source for coverage:** Checkpoint `JamfClient` (widest) and `JamfSchoolClient`. **Source for tested code:** Serial Number Reader (Jamf School tests).
- **Rule:** every call taken from Checkpoint gets a fake-network test as it moves (Checkpoint has none).
- **First app:** Serial Number Reader. **Then:** Checkpoint.
- **Check by hand:** look up a device in Jamf Pro and Jamf School; send one harmless command to a test device.

### Step 8: Intune / Microsoft Graph (0.9.0)
- **Source:** Intune Deployer `GraphClient` (tested) for Graph calls; Checkpoint `IntuneClient` for app-only login (no extra library).
- **Microsoft's sign-in library (MSAL)** goes in a separate optional product (for example `JTKitMSAL`) so apps without interactive Microsoft sign-in don't include it. Ask Jordy before adding it.
- **First app:** Intune Deployer. **Then:** Checkpoint.
- **Check by hand:** sign in, list devices, one baseline action on a test tenant.

### Step 9: Apple Business / School Manager (0.10.0)
- **Source:** Checkpoint `ABMClient`, the only copy.
- **Rule:** write tests for its current behaviour first, then move it.
- **First app:** Checkpoint.
- **Check by hand:** look up devices in ABM and ASM.

### Step 10: Demo mode (0.11.0)
- **Move:** demo mode with a fake server from Profile2Blueprint (`DemoFixtures`, `DemoBlueprintServer`), so every app can be tried and checked by hand without a tenant.
- **Not planned (decided 2026-10-25):** the full UI test suites and `run-*-ui-tests.sh` scripts of Jamf Deployer and AppSettings2Blueprint are not moved, copied as a template or used as a check (see "Testing" in CLAUDE.md). Jamf Deployer's UI-test helpers (`UITestSupport.swift`) move into a `JTKitUITestSupport` product only if Jordy asks for a specific UI test that needs them.
- **First app:** AppSettings2Blueprint. **Then:** the other apps, starting with Checkpoint.
- **Check by hand:** the app runs in demo mode without a tenant and shows believable sample data; switching back to a real connection works.

### 1.0.0
When every app has adopted steps 1–9 and the public API has stopped changing.

## Not shared

Each app's own engine (migration, deployment, rule building) and whole Settings screens; only the sections above are shared. Out of scope entirely: IntuneOnboard (with OnboardCore), Device Assist and its customer variants (DeviceAssist-Rituals, DeviceAssist-UMCUtrecht), and Replicator (fork).

## Versions

Each step gets the next 0.x tag. Apps only move to a new JTKit version when you update them deliberately, so an app keeps working on its old version until its turn.
