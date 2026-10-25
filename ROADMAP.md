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
- **Connection menu:** every app with a connection picker in its main window (toolbar or sidebar) also has JTKit's "Connection" menu in the menu bar, with the same items as the picker: the saved connections with the one in use checked (one section per role, e.g. Source and Destination), then "Edit Connections…", which opens Settings › Connections. The toolbar picker is JTKit's `ConnectionPicker`, the menu `ConnectionCommands`; both show `ConnectionMenuItems`. Added by Jordy on 2026-10-25, in 0.5.2. JamfMigrator and Profile2Blueprint (step 4 done before it existed) switch to it on their next JTKit update; Profile2Blueprint's own "Tenant" menu then goes.
- **Activity log:** every app that connects to those services has the same JTKit activity log window (⌘⇧L), filled automatically by JTKit's networking, with a bug-report export that masks device identifiers (from Checkpoint). Built in step 5. It replaces the request logs in AppSettings2Blueprint and Blueprint Managed Preferences Editor, and Checkpoint's log. Profile2Blueprint's migration history stays.
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
- **Later (changes the look, so every app at once):** from the step 2 design review: show the failure icon next to failed statuses in the activity log, not only red text; make the yellow warning and green success icons stand out more on light backgrounds (for example the multicolour warning symbol); put the activity log's Clear in the menu bar as well as the toolbar; decide whether the update sheet uses the SheetFrame header like the other sheets.

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

### Step 4: Keychain and saved connections (0.5.0)
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
- **Checkpoint:** `jamfServers` and `abmOrgs` (UserDefaults) shown as one list in one Connections tab (the "Apple" and "MDM" tabs go). Keychain `DeviceStatus.secrets`, accounts `jamf.<UUID>` and `abm.<UUID>`.
- **Jamf Deployer:** tenants stay in `store/tenants/<UUID>/tenant.json` (a Git repository shared with the team). The adapter writes these files **byte-for-byte as today** (same key order and formatting) and changes only the connection fields. Settings › Connections lists the tenants for editing, testing and deleting; its + opens the "Connect a Tenant" wizard; the sidebar stays for deployments. URL, region, scope and connection kind stay read-only after connecting. Keychain services `be.jordythery.jamf-deployer.platform-client-secret` and `.protect-client-secret`, account = tenant UUID; its other Keychain items stay app-only.
- **Intune Deployer:** `tenants.json` in Application Support/Intune Deployer, `selectedTenantProfileID`. Connection fields, import and export move to Settings › Connections; the baseline settings stay in the app; Sign In stays in the toolbar (MSAL keeps its own token cache; nothing to carry over).

**Check by hand (each app, in addition to the above):** a backup copy of the old data appears next to the original after the first save; Save and Revert work; "Use This Connection" matches the main-window picker. Jamf Deployer: after editing a tenant's name, `git diff` of its `tenant.json` shows only that line.

### Step 5: Jamf login and HTTP basics (0.6.0)
- **Move:** token providers (OAuth client credentials and username/password, token renewal), HTTP client with retry and `Retry-After`/429 handling, secret redaction in logs.
- **Activity log standard:** JTKit's networking fills JTKit's `ActivityLog` automatically. Every app that connects to Jamf, Intune or ABM/ASM gets the same activity log window (⌘⇧L) with a bug-report export that masks device identifiers. It replaces AppSettings2Blueprint's and Blueprint Managed Preferences Editor's request logs and Checkpoint's activity log. Profile2Blueprint's migration history stays.
- **Source:** Profile2Blueprint `TokenProvider` + `HTTPClient` and JamfMigrator `TokenProvider` (both tested); AppSettings2Blueprint `RequestLog` + `LogRedactor` (tested; what a request entry records); Checkpoint `ActivityRedaction` + `IdentifierMasker` for the masked bug-report export.
- **First app:** Profile2Blueprint. **Then:** JamfMigrator, AppSettings2Blueprint, Blueprint Managed Preferences Editor, Serial Number Reader, Checkpoint, Jamf Deployer.
- **Check by hand:** connect with an API client and with a user account; the activity log (⌘⇧L) fills by itself and shows no secrets; the bug-report export masks serial numbers and other device identifiers.

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
