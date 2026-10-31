import Foundation

/// What an app tells the update checker about itself: where its GitHub releases
/// live and what the app is called in the update sheet.
///
/// The `UserDefaults` keys default to the names every app already uses, so saved
/// preferences keep working when an app moves to JTKit. Override them only for an
/// app that historically used different names.
public nonisolated struct UpdateConfiguration: Sendable {
    /// GitHub account, e.g. `"JordyThery"`.
    public var owner: String
    /// Repository name as it appears in the GitHub URL, e.g. `"AppSettings2Blueprint"`.
    public var repository: String
    /// The app’s display name, used in the update sheet’s text.
    public var appName: String

    /// `UserDefaults` key for the automatic check. Absent means on.
    public var automaticCheckKey: String
    /// `UserDefaults` key for when the last automatic check ran.
    public var lastCheckKey: String
    /// `UserDefaults` key for the last release version offered automatically.
    public var lastOfferedKey: String
    /// At most one automatic check per this interval.
    public var automaticCheckInterval: TimeInterval

    public init(
        owner: String,
        repository: String,
        appName: String,
        automaticCheckKey: String = UpdateChecker.automaticCheckKey,
        lastCheckKey: String = "lastUpdateCheck",
        lastOfferedKey: String = "lastOfferedUpdate",
        automaticCheckInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.owner = owner
        self.repository = repository
        self.appName = appName
        self.automaticCheckKey = automaticCheckKey
        self.lastCheckKey = lastCheckKey
        self.lastOfferedKey = lastOfferedKey
        self.automaticCheckInterval = automaticCheckInterval
    }

    /// GitHub’s "latest release" endpoint for the repository.
    public var latestReleaseURL: URL? {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")
    }
}
