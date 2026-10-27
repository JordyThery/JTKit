import AppKit
import CryptoKit
import Foundation
import Observation

/// Demo mode: the app runs against fake services inside the app, with sample
/// data, and never against a tenant. It never reads or writes saved
/// connections or Keychain items, and sends nothing to a real service.
///
/// The app keeps one `DemoMode`, shows `DemoModeToggle` in its connection
/// picker and Connection menu, and where it builds its clients asks for a
/// demo source (`jamfPlatform()`) instead of the saved connection:
///
/// ```swift
/// let source = demo.jamfPlatform()
/// let client = try JamfPlatform.Client(connection: source.connection, secret: source.secret,
///                                      recorder: RequestRecorder(session: source.session, log: log))
/// ```
///
/// Launch arguments (for UI tests, step 11):
/// - `-JTKitDemo YES` turns demo mode on for this run only; nothing is saved.
/// - `-JTKitSandbox YES` gives this run in-memory connections and secrets
///   (`sandboxSecrets`, `sandboxDefaults`) and blocks public lookups; it
///   saves no demo setting either.
/// - `-JTKitDemoScenario <name>` picks a `DemoScenario`, e.g. `jamfSchool`.
@MainActor
@Observable
public final class DemoMode {
    nonisolated public static let launchArgument = "-JTKitDemo"
    nonisolated public static let sandboxArgument = "-JTKitSandbox"
    nonisolated public static let scenarioArgument = "-JTKitDemoScenario"

    /// The switch's name, the same in every app.
    nonisolated public static let title = "Demo Mode"
    /// The connection picker's tooltip while demo mode is on.
    nonisolated public static let helpText = "Sample data. Nothing is sent to a tenant."
    /// Added to every window's title while demo mode is on.
    nonisolated public static let titleSuffix = " — Demo"

    /// On or off. Saved under the app's key, unless the run was started with
    /// `-JTKitDemo` or `-JTKitSandbox`.
    public var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            if savesChoice { defaults.set(isOn, forKey: key) }
            DemoWindowTitles.shared.update(isOn: isOn)
        }
    }

    /// Asked before the shared switch (`DemoModeToggle`) turns demo mode on
    /// or off: true when the app has unsaved work that switching would
    /// discard, so it asks first (`confirmsDemoModeSwitch`). Nil never asks.
    @ObservationIgnored public var asksBeforeSwitching: (@MainActor () -> Bool)?

    /// A switch waiting for the app's question: the value it would set.
    public private(set) var pendingSwitch: Bool?

    /// Turns demo mode on or off, or, when `asksBeforeSwitching` says so,
    /// keeps the switch waiting in `pendingSwitch` for `confirmSwitch()` or
    /// `cancelSwitch()`. Returns true when it waits.
    @discardableResult
    public func requestSwitch(to newValue: Bool) -> Bool {
        guard newValue != isOn else { return false }
        if asksBeforeSwitching?() == true {
            pendingSwitch = newValue
            return true
        }
        pendingSwitch = nil
        isOn = newValue
        return false
    }

    /// The question was answered "Discard": makes the waiting switch.
    public func confirmSwitch() {
        guard let pending = pendingSwitch else { return }
        pendingSwitch = nil
        isOn = pending
    }

    /// The question was cancelled: demo mode stays as it is.
    public func cancelSwitch() {
        pendingSwitch = nil
    }

    /// Started with `-JTKitSandbox YES`: in-memory connections and secrets, no public lookups.
    public let isSandbox: Bool
    /// Started with `-JTKitDemoScenario <name>`.
    public let scenario: DemoScenario?

    @ObservationIgnored private let key: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let savesChoice: Bool
    @ObservationIgnored private var servicesValue: DemoServices?
    @ObservationIgnored private var scratch: URL?

    /// - Parameters:
    ///   - key: where the choice is saved, e.g. `"demoMode"`.
    ///   - arguments: the launch arguments; the running app's by default.
    public init(key: String, defaults: UserDefaults = .standard,
                arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.key = key
        self.defaults = defaults
        let launchChoice = Self.bool(after: Self.launchArgument, in: arguments)
        isSandbox = Self.bool(after: Self.sandboxArgument, in: arguments) ?? false
        scenario = Self.value(after: Self.scenarioArgument, in: arguments).flatMap(DemoScenario.init(rawValue:))
        savesChoice = launchChoice == nil && !isSandbox
        isOn = launchChoice ?? (isSandbox ? false : defaults.bool(forKey: key))
        DemoWindowTitles.shared.update(isOn: isOn)
    }

    // MARK: Fake services

    /// The demo's Jamf Platform API: "Contoso (Demo)", answered by
    /// `jamfPlatformServer` inside the app. The same server for the whole
    /// launch, so what's done in demo mode stays until the app quits.
    public func jamfPlatform() -> DemoSource {
        source(for: .demoJamfPlatform) ?? DemoSource(connection: .demoJamfPlatform, session: services().network.session)
    }

    /// What a client needs for one of the demo connections
    /// (`Connection.demoConnections`): the connection, its fake secret and the
    /// demo network's session. Nil for any other connection, so a real one
    /// can never be sent to the demo network, nor a demo one to a tenant.
    ///
    /// Apple Business and School Manager sign in with a private key made for
    /// this launch: it lives only in memory, in this `DemoMode`, and is never
    /// written anywhere, the Keychain included.
    public func source(for connection: Connection) -> DemoSource? {
        guard let demo = Connection.demoConnections.first(where: { $0.id == connection.id }) else { return nil }
        let services = services()
        switch demo.service {
        case .appleBusinessManager, .appleSchoolManager:
            let pem = services.applePrivateKeyPEM
            return DemoSource(connection: demo, session: services.network.session, secret: { pem })
        default:
            return DemoSource(connection: demo, session: services.network.session)
        }
    }

    /// Microsoft's interactive sign-in for "Contoso Intune (Demo)", for an app
    /// that signs in with MSAL (Intune Deployer): a fixed token the demo
    /// tenant accepts, its account and the demo network's session. No
    /// sign-in window, and MSAL, its Keychain cache and the real signed-in
    /// accounts are never used.
    public func microsoftSignIn() -> DemoMicrosoftSignIn {
        DemoMicrosoftSignIn(session: services().network.session)
    }

    /// The server behind `jamfPlatform()`, e.g. to add sample data.
    public var jamfPlatformServer: DemoJamfPlatformServer { services().platform }
    /// The servers behind the other demo connections; they hold `DemoWorld`.
    public var jamfProServer: DemoJamfProServer { services().jamfPro }
    public var jamfSchoolServer: DemoJamfSchoolServer { services().jamfSchool }
    public var intuneServer: DemoIntuneServer { services().intune }
    public var appleBusinessServer: DemoAppleBusinessServer { services().appleBusiness }
    public var appleSchoolServer: DemoAppleBusinessServer { services().appleSchool }

    private func services() -> DemoServices {
        if let services = servicesValue { return services }
        let created = DemoServices(scenario: scenario)
        servicesValue = created
        return created
    }

    // MARK: Files and sandbox

    /// A folder of its own in the temporary directory, new for each launch,
    /// for what the app saves while in demo mode (history, backups) instead
    /// of its real files.
    public var scratchDirectory: URL {
        if let scratch { return scratch }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "JTKitDemo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scratch = folder
        return folder
    }

    /// Settings for a sandbox run: emptied when it starts, so the app's real
    /// settings (saved connections, the one in use) are never read or written.
    public static func sandboxDefaults() -> UserDefaults {
        let name = "JTKitSandbox"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Titles

    /// `title` with "— Demo" added while demo mode is on, removed while it's off.
    nonisolated public static func windowTitle(_ title: String, isOn: Bool) -> String {
        let base = title.hasSuffix(titleSuffix) ? String(title.dropLast(titleSuffix.count)) : title
        return isOn && !base.isEmpty ? base + titleSuffix : base
    }

    // MARK: Launch arguments

    private static func value(after name: String, in arguments: [String]) -> String? {
        guard let index = arguments.lastIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func bool(after name: String, in arguments: [String]) -> Bool? {
        switch value(after: name, in: arguments)?.lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: nil
        }
    }
}

/// What a client needs to reach a demo service, in place of a saved
/// connection, its Keychain secret and the real network.
public nonisolated struct DemoSource: Sendable {
    public let connection: Connection
    /// Answered by the demo service's fake sign-in; never a Keychain read.
    public let secret: @Sendable () throws -> String
    /// The demo network's session: nothing it sends leaves the app.
    public let session: URLSession

    init(connection: Connection, session: URLSession, secret: (@Sendable () throws -> String)? = nil) {
        self.connection = connection
        self.session = session
        let account = connection.id.uuidString
        self.secret = secret ?? { DemoSecretStore().secret(for: account) ?? "" }
    }
}

/// Demo mode's stand-in for Microsoft's interactive sign-in (MSAL): the demo
/// tenant's account and a fixed token, used in place of a signed-in account.
public nonisolated struct DemoMicrosoftSignIn: Sendable {
    /// The demo tenant, "Contoso Intune (Demo)".
    public let connection = Connection.demoIntune
    /// Fixed and obviously fake; only the demo tenant accepts it.
    public let accessToken = DemoIntuneServer.delegatedToken
    /// The demo tenant's signed-in person, e.g. for "Signed in as …".
    public let username = DemoGraphStore.username
    public let displayName = DemoGraphStore.userDisplayName
    /// The demo network's session: nothing it sends leaves the app.
    public let session: URLSession
}

extension Connection {
    /// Demo mode's Jamf Platform API connection. Never saved.
    public static let demoJamfPlatform = Connection(
        id: UUID(uuidString: DemoSamples.uuid(0xde01)) ?? UUID(),
        name: "\(DemoSamples.organization) (Demo)",
        service: .jamfPlatform,
        region: .us,
        environmentID: DemoSamples.platformEnvironmentID,
        hostOverride: DemoSamples.platformHost,
        clientID: "contoso-demo-client"
    )

    /// A demo connection: an ID, a tenant ID or a client ID in the reserved
    /// fake range, or an address on `.demo.invalid`. `ConnectionStore`
    /// refuses to save one. The tenant and client IDs count too, so an
    /// exported demo profile imported under a new ID is still a demo one.
    public var isDemo: Bool {
        let ids = [id.uuidString, tenantID, clientID].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if ids.contains(where: DemoSamples.isDemoID) { return true }
        let suffix = "." + DemoNetwork.reservedDomain
        let hosts = [hostOverride, serverURL].map { text -> String in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return URL(string: trimmed)?.host() ?? trimmed.split(separator: "/").first.map(String.init) ?? ""
        }
        return hosts.contains { $0.hasSuffix(suffix) || $0 == DemoNetwork.reservedDomain }
    }
}

/// Every demo server of a launch, on one private network.
nonisolated final class DemoServices: Sendable {
    let platform: DemoJamfPlatformServer
    let jamfPro: DemoJamfProServer
    let jamfSchool: DemoJamfSchoolServer
    let intune: DemoIntuneServer
    let appleBusiness: DemoAppleBusinessServer
    let appleSchool: DemoAppleBusinessServer
    let network: DemoNetwork
    /// Apple's sign-in key for the demo organizations: made for this launch,
    /// kept in memory only, never saved.
    let applePrivateKeyPEM: String

    init(scenario: DemoScenario?) {
        let key = P256.Signing.PrivateKey()
        applePrivateKeyPEM = key.pemRepresentation
        platform = DemoJamfPlatformServer(scenario: scenario == .jamfSchool ? .jamfSchool : nil)
        jamfPro = DemoJamfProServer(scenario: scenario)
        jamfSchool = DemoJamfSchoolServer(scenario: scenario)
        intune = DemoIntuneServer(scenario: scenario)
        appleBusiness = DemoAppleBusinessServer(organization: .contoso, scenario: scenario)
        appleSchool = DemoAppleBusinessServer(organization: .academy, scenario: scenario)
        let signIn = DemoAppleSignInServer(keys: [Connection.demoAppleBusiness.clientID: key.publicKey,
                                                  Connection.demoAppleSchool.clientID: key.publicKey])
        var servers: [String: any DemoServer] = [
            DemoSamples.platformHost: platform,
            DemoWorld.jamfProHost: jamfPro,
            DemoWorld.jamfSchoolHost: jamfSchool,
            DemoAppleSignInServer.host: signIn,
            ABM.Service.business.host: appleBusiness,
            ABM.Service.school.host: appleSchool,
        ]
        for host in DemoIntuneServer.hosts { servers[host] = intune }
        network = DemoNetwork(servers: servers)
    }
}

/// Demo connections' secrets: a fixed fake secret, and every write refused,
/// so demo mode can never put anything in the Keychain.
public nonisolated struct DemoSecretStore: SecretStore {
    public init() {}

    public func secret(for account: String) -> String? { "demo-secret" }

    @discardableResult
    public func setSecret(_ secret: String?, for account: String) -> Bool { false }
}

/// Secrets kept in memory only, for a sandbox run (`-JTKitSandbox YES`).
public nonisolated final class SandboxSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    public init() {}

    public func secret(for account: String) -> String? {
        lock.withLock { secrets[account] }
    }

    @discardableResult
    public func setSecret(_ secret: String?, for account: String) -> Bool {
        lock.withLock { secrets[account] = secret }
        return true
    }
}

/// Saved connections kept in memory only, for a sandbox run.
@MainActor
public final class InMemoryConnectionStorage<Record>: ConnectionStorage {
    private var records: [Record]

    public init(_ records: [Record] = []) {
        self.records = records
    }

    public func load() throws -> [Record] { records }
    public func save(_ records: [Record]) throws { self.records = records }
    public func backUpOnce() throws {}
    public func keepUnreadableCopy() -> String? { nil }
}

/// Adds "— Demo" to the title of every window while demo mode is on, and
/// takes it off again when it's turned off, so a screenshot can't be taken
/// for real data. Windows whose title changes (a Settings tab) get it back on
/// the next update.
@MainActor
final class DemoWindowTitles {
    static let shared = DemoWindowTitles()

    private var observer: (any NSObjectProtocol)?
    private var isOn = false

    func update(isOn: Bool) {
        self.isOn = isOn
        if isOn, observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: nil, queue: .main
            ) { notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated { DemoWindowTitles.shared.apply(to: window) }
            }
        } else if !isOn, let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let app = NSApp else { return }
        for window in app.windows { apply(to: window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window, !(window is NSPanel) else { return }
        let title = DemoMode.windowTitle(window.title, isOn: isOn)
        if title != window.title { window.title = title }
    }
}
