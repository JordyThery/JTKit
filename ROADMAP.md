# JTKit roadmap

The order in which shared code moves into JTKit, where each piece comes from, and which apps adopt it. Claude: read this together with CLAUDE.md. Jordy: the prompts are in "How to run a step" below.

Sources were chosen from the code (October 2026): prefer the copy with tests and the most robust handling, and take *coverage* (which calls exist) from wherever it is widest.

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
- **Check by hand:** Check for Updates from the menu and from About says "up to date"; the daily-check toggle survives a relaunch.

### Step 2: Fold in DeployerKit (0.3.0)
`Jamf Deployer/DeployerKit` is an earlier shared package (tested, macOS 15, Swift 6.2 with main-actor default isolation). Intune Deployer was meant to use it but doesn't.
- **Move:** ActivityLog + ActivityLogView, GuidedTour, DesignSystem components (StatusBadge etc.), TextExportDocument, JSONFile.
- **Decision (2026-10-25):** JTKit stays at macOS 14 (and iOS 17): nothing in the moved code needs macOS 15 or Swift 6.2. It moves up only when all apps move together. JTKit keeps Swift tools 6.0 and marks UI state `@MainActor` explicitly instead of DeployerKit's main-actor default.
- **First app:** Jamf Deployer (switch its DeployerKit imports to JTKit; DeployerKit keeps only what is Jamf Deployer-specific, or goes away).
- **Then:** Intune Deployer (GuidedTour, ActivityLog), JamfMigrator (GuidedTour).
- **Not replaced:** Checkpoint's activity log (a bug-report log that masks device identifiers on export) and Profile2Blueprint's activity (a saved migration history) stay in their apps; JTKit's in-memory log is not a substitute.
- **Design:** run the apple-design review on the moved components; they become the shared look of all apps.
- **Check by hand:** guided tour runs start to finish; activity log fills, exports and clears.
- **Later (changes the look, so every app at once):** from the step 2 design review: show the failure icon next to failed statuses in the activity log, not only red text; make the yellow warning and green success icons stand out more on light backgrounds (for example the multicolour warning symbol); put the activity log's Clear in the menu bar as well as the toolbar; decide whether the update sheet uses the SheetFrame header like the other sheets.

### Step 3: App shell (0.4.0)
- **Move:** About window and acknowledgements, reusable Settings sections (updates, logging, connections list).
- **Source:** AppSettings2Blueprint (About and acknowledgements have unit and UI tests); compare Jamf Deployer and Profile2Blueprint's About.
- **First app:** AppSettings2Blueprint. **Then:** every macOS app.
- **Check by hand:** About shows the right name, version, links and acknowledgements.

### Step 4: Keychain and saved connections (0.5.0)
- **Source:** JamfMigrator `SecretStore` (protocol with an in-memory fake for tests) and `Tenant`/`TenantStore` (tested). Fold in fields from Jamf Deployer's `Tenant` (Platform API, Protect) and Intune Deployer's `TenantStore`.
- **Critical:** every app keeps its own Keychain service and account names and its saved-connections file/keys. Losing them logs users out.
- **First app:** JamfMigrator. **Then:** Profile2Blueprint, AppSettings2Blueprint, Blueprint Managed Preferences Editor, Serial Number Reader, Checkpoint, Jamf Deployer, Intune Deployer.
- **Check by hand:** before switching, save a connection with the old build; after switching, it is still there and still connects.

### Step 5: Jamf login and HTTP basics (0.6.0)
- **Move:** token providers (OAuth client credentials and username/password, token renewal), HTTP client with retry and `Retry-After`/429 handling, request log, secret redaction in logs.
- **Source:** Profile2Blueprint `TokenProvider` + `HTTPClient` and JamfMigrator `TokenProvider` (both tested); AppSettings2Blueprint `RequestLog` + `LogRedactor` (tested); Checkpoint `ActivityRedaction` + `IdentifierMasker` for masking device identifiers in exported logs.
- **First app:** Profile2Blueprint. **Then:** JamfMigrator, AppSettings2Blueprint, Blueprint Managed Preferences Editor, Serial Number Reader, Device Assist (iOS: also proves JTKit builds for iOS), Checkpoint, Jamf Deployer.
- **Check by hand:** connect with an API client and with a user account; the request log shows no secrets.

### Step 6: Jamf Platform API (0.7.0)
- **Source:** JamfMigrator `PlatformClient` (regions, polling, permission probe, gateway errors; tested). Add Blueprint and device-group calls from AppSettings2Blueprint, Blueprint Managed Preferences Editor, Profile2Blueprint and Jamf Deployer.
- **First app:** JamfMigrator. **Then:** AppSettings2Blueprint, Blueprint Managed Preferences Editor, Profile2Blueprint, Jamf Deployer.
- **Check by hand:** list Blueprints and device groups; one harmless write on a test tenant.

### Step 7: Jamf Pro, Jamf School and device actions (0.8.0)
- **Source for coverage:** Checkpoint `JamfClient` (widest) and `JamfSchoolClient`. **Source for tested code:** Serial Number Reader (Jamf School tests). **iOS side:** Device Assist (restart, erase, return to service, clear passcode).
- **Rule:** every call taken from Checkpoint gets a fake-network test as it moves (Checkpoint has none).
- **First app:** Serial Number Reader. **Then:** Device Assist, Checkpoint.
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

### Step 10: Testing toolkit and demo mode (0.11.0)
- **Move:** UI-test helpers from Jamf Deployer `UITestSupport.swift` into a `JTKitUITestSupport` product; a run-script template from Jamf Deployer's `Scripts/run-*-ui-tests.sh` (credentials from Keychain into environment variables, cleanup on exit); demo mode with a fake server from Profile2Blueprint (`DemoFixtures`, `DemoBlueprintServer`).
- **First app:** AppSettings2Blueprint (has UI tests). **Then:** apps without UI tests, starting with Checkpoint.
- **Check by hand:** UI tests run unattended; the app runs in demo mode without a tenant.

### 1.0.0
When every app has adopted steps 1–9 and the public API has stopped changing.

## Not shared

Each app's own engine (migration, deployment, onboarding, rule building) and whole Settings screens. The customer variants (DeviceAssist-Rituals, DeviceAssist-UMCUtrecht), Replicator (fork) and IntuneOnboard's OnboardCore stay out of scope.

## Versions

Each step gets the next 0.x tag. Apps only move to a new JTKit version when you update them deliberately, so an app keeps working on its old version until its turn.
