import Foundation

/// What a Blueprint’s software update means for each device it reaches, and
/// why a device isn’t on target: the rules Software Update Dashboard reports
/// with, shared since 1.9.0 so every app that reports on updates measures
/// the same way. iPhones, iPads and Macs.
///
/// - `TargetRules` gives a device its target and deadline from the
///   Blueprint’s rule and Apple’s release data (`AppleReleases.Catalog`),
///   and reads what Jamf actually sent it from its status report.
/// - `Classifier` sorts each device into a `StatusCategory` with a plain
///   diagnosis (`DeviceStatus`); `ReadinessCheck` says why the update can’t
///   reach it; `BlueprintHealth` how the Blueprint’s declarations stand.
/// - `InspectFindings` lists every reason one device may not update.
/// - `Reader` does a refresh’s requests (GET only) within the app’s request
///   limits and measures every device; `InspectWorkflow` reads Inspect’s.
///
/// Nothing here is saved: what earlier refreshes remembered
/// (`ReportedDeadlines`, the first public postings) comes in from the app,
/// and what to remember goes back to it.
public enum SoftwareUpdateRules {}
