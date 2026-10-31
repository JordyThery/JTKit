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
/// Launch arguments (for UI tests):
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

    /// The switch’s name, the same in every app.
    nonisolated public static let title = "Demo Mode"
    /// The connection picker’s tooltip while demo mode is on.
    nonisolated public static let helpText = "Sample data. Nothing is sent to a tenant."
    /// Added to every window’s title while demo mode is on.
    nonisolated public static let titleSuffix = " — Demo"

    /// On or off. Saved under the app’s key, unless the run was started with
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

    /// A switch waiting for the app’s question: the value it would set.
    public private(set) var pendingSwitch: Bool?
    /// What else the waiting switch does once confirmed, e.g. choosing the
    /// saved connection that ends demo mode.
    @ObservationIgnored private var pendingAction: (@MainActor () -> Void)?

    /// Turns demo mode on or off, or, when `asksBeforeSwitching` says so,
    /// keeps the switch waiting in `pendingSwitch` for `confirmSwitch()` or
    /// `cancelSwitch()`. Returns true when it waits.
    @discardableResult
    public func requestSwitch(to newValue: Bool) -> Bool {
        requestSwitch(to: newValue, then: nil)
    }

    /// As `requestSwitch(to:)`, and runs `action` once the switch is made:
    /// straight away, after `confirmSwitch()`, or never after `cancelSwitch()`.
    @discardableResult
    func requestSwitch(to newValue: Bool, then action: (@MainActor () -> Void)?) -> Bool {
        guard newValue != isOn else {
            action?()
            return false
        }
        if asksBeforeSwitching?() == true {
            pendingSwitch = newValue
            pendingAction = action
            return true
        }
        pendingSwitch = nil
        pendingAction = nil
        action?()
        isOn = newValue
        return false
    }

    /// The question was answered "Discard": makes the waiting switch.
    public func confirmSwitch() {
        guard let pending = pendingSwitch else { return }
        let action = pendingAction
        pendingSwitch = nil
        pendingAction = nil
        action?()
        isOn = pending
    }

    /// The question was canceled: demo mode stays as it is.
    public func cancelSwitch() {
        pendingSwitch = nil
        pendingAction = nil
    }

    /// Started with `-JTKitSandbox YES`: in-memory connections and secrets, no public lookups.
    public let isSandbox: Bool
    /// Started with `-JTKitDemoScenario <name>`.
    public let scenario: DemoScenario?

    @ObservationIgnored private let key: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let savesChoice: Bool
    @ObservationIgnored private var servicesValue: DemoServices?
    @ObservationIgnored private var scratch: ScratchFolder?

    /// - Parameters:
    ///   - key: where the choice is saved, e.g. `"demoMode"`.
    ///   - arguments: the launch arguments; the running app’s by default.
    public init(key: String, defaults: UserDefaults = .standard,
                arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.key = key
        self.defaults = defaults
        let launchChoice = Self.bool(after: Self.launchArgument, in: arguments)
        isSandbox = Self.isSandbox(arguments: arguments)
        scenario = Self.value(after: Self.scenarioArgument, in: arguments).flatMap(DemoScenario.init(rawValue:))
        savesChoice = launchChoice == nil && !isSandbox
        isOn = launchChoice ?? (isSandbox ? false : defaults.bool(forKey: key))
        DemoWindowTitles.shared.update(isOn: isOn)
    }

    // MARK: Fake services

    /// The demo’s Jamf Platform API: "Contoso (Demo)", answered by
    /// `jamfPlatformServer` inside the app. The same server for the whole
    /// launch, so what’s done in demo mode stays until the app quits.
    public func jamfPlatform() -> DemoSource {
        source(of: .demoJamfPlatform)
    }

    /// What a client needs for one of the demo connections
    /// (`Connection.demoConnections`): the connection, its fake secret and the
    /// demo network’s session. Nil for any other connection, so a real one
    /// can never be sent to the demo network, nor a demo one to a tenant.
    ///
    /// Apple Business and School Manager sign in with a private key made for
    /// this launch: it lives only in memory, in this `DemoMode`, and is never
    /// written anywhere, the Keychain included.
    public func source(for connection: Connection) -> DemoSource? {
        guard let demo = Connection.demoConnections.first(where: { $0.id == connection.id }) else { return nil }
        return source(of: demo)
    }

    /// The source of one of `Connection.demoConnections`.
    private func source(of demo: Connection) -> DemoSource {
        let services = services()
        switch demo.service {
        case .appleBusinessManager, .appleSchoolManager:
            let pem = services.applePrivateKeyPEM
            return DemoSource(connection: demo, session: services.network.session, secret: { pem })
        default:
            return DemoSource(connection: demo, session: services.network.session)
        }
    }

    /// Microsoft’s interactive sign-in for "Contoso Intune (Demo)", for an app
    /// that signs in with MSAL (Intune Deployer): a fixed token the demo
    /// tenant accepts, its account and the demo network’s session. No
    /// sign-in window, and MSAL, its Keychain cache and the real signed-in
    /// accounts are never used.
    public func microsoftSignIn() -> DemoMicrosoftSignIn {
        DemoMicrosoftSignIn(session: services().network.session)
    }

    /// The server behind `jamfPlatform()`, e.g. to add sample data.
    public var jamfPlatformServer: DemoJamfPlatformServer { services().platform }
    /// The servers behind the other demo connections; they hold `DemoWorld`.
    public var jamfProServer: DemoJamfProServer { services().jamfPro }
    /// The servers behind "Contoso Source (Demo)" and "Contoso Destination
    /// (Demo)"; their objects are in `objects`.
    public var jamfProSourceServer: DemoJamfProServer { services().jamfProSource }
    public var jamfProDestinationServer: DemoJamfProServer { services().jamfProDestination }
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
    /// of its real files. Removed when the app quits.
    public var scratchDirectory: URL {
        if let scratch { return scratch.url }
        let folder = ScratchFolder()
        scratch = folder
        return folder.url
    }

    /// Settings for a sandbox run, kept apart from the app’s real settings
    /// (saved connections, the one in use), which are never read or written:
    /// a suite of this run’s own, empty when it starts and removed when the
    /// app quits. The same suite for the whole run.
    public static func sandboxDefaults() -> UserDefaults {
        if let sandboxDefaultsValue { return sandboxDefaultsValue }
        SandboxSuite.removeLeftovers()
        let name = SandboxSuite.name(processID: ProcessInfo.processInfo.processIdentifier)
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("A sandbox run never falls back to the app’s real settings.")
        }
        defaults.removePersistentDomain(forName: name)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: nil) { _ in
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        sandboxDefaultsValue = defaults
        return defaults
    }

    private static var sandboxDefaultsValue: UserDefaults?

    // MARK: Titles

    /// `title` with "— Demo" added while demo mode is on, removed while it’s off.
    nonisolated public static func windowTitle(_ title: String, isOn: Bool) -> String {
        let base = title.hasSuffix(titleSuffix) ? String(title.dropLast(titleSuffix.count)) : title
        return isOn && !base.isEmpty ? base + titleSuffix : base
    }

    // MARK: Launch arguments

    /// Whether the arguments start a sandbox run (`-JTKitSandbox YES`).
    nonisolated static func isSandbox(arguments: [String]) -> Bool {
        bool(after: sandboxArgument, in: arguments) ?? false
    }

    nonisolated private static func value(after name: String, in arguments: [String]) -> String? {
        guard let index = arguments.lastIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    nonisolated private static func bool(after name: String, in arguments: [String]) -> Bool? {
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
    /// Answered by the demo service’s fake sign-in; never a Keychain read.
    public let secret: @Sendable () throws -> String
    /// The demo network’s session: nothing it sends leaves the app.
    public let session: URLSession

    init(connection: Connection, session: URLSession, secret: (@Sendable () throws -> String)? = nil) {
        self.connection = connection
        self.session = session
        let account = connection.id.uuidString
        self.secret = secret ?? { DemoSecretStore().secret(for: account) ?? "" }
    }
}

/// Demo mode’s stand-in for Microsoft’s interactive sign-in (MSAL): the demo
/// tenant’s account and a fixed token, used in place of a signed-in account.
public nonisolated struct DemoMicrosoftSignIn: Sendable {
    /// The demo tenant, "Contoso Intune (Demo)".
    public let connection = Connection.demoIntune
    /// Fixed and obviously fake; only the demo tenant accepts it.
    public let accessToken = DemoIntuneServer.delegatedToken
    /// The demo tenant’s signed-in person, e.g. for "Signed in as …".
    public let username = DemoGraphStore.username
    public let displayName = DemoGraphStore.userDisplayName
    /// The demo network’s session: nothing it sends leaves the app.
    public let session: URLSession
}

extension Connection {
    /// Demo mode’s Jamf Platform API connection. Never saved.
    public static let demoJamfPlatform = Connection(
        id: UUID(uuidString: DemoSamples.uuid(0xde01)) ?? UUID(),
        name: "\(DemoSamples.organization) (Demo)",
        service: .jamfPlatform,
        region: .us,
        environmentID: DemoSamples.platformEnvironmentID,
        hostOverride: DemoSamples.platformHost,
        clientID: "contoso-demo-client"
    )

    /// A demo connection: an ID, a tenant ID, a client ID, an environment
    /// ID or a key ID in the reserved fake range (a client ID also after
    /// Apple’s `BUSINESSAPI.` or `SCHOOLAPI.`), or an address on
    /// `.demo.invalid`. `ConnectionStore` refuses to save one. The other IDs
    /// count too, so an exported demo profile imported under a new ID is
    /// still a demo one.
    public var isDemo: Bool {
        let ids = [id.uuidString, tenantID, clientID, environmentID, keyID]
        if ids.contains(where: DemoSamples.isDemoIdentifier) { return true }
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
    let jamfProSource: DemoJamfProServer
    let jamfProDestination: DemoJamfProServer
    let jamfSchool: DemoJamfSchoolServer
    let intune: DemoIntuneServer
    let appleBusiness: DemoAppleBusinessServer
    let appleSchool: DemoAppleBusinessServer
    let network: DemoNetwork
    /// Apple’s sign-in key for the demo organizations: made for this launch,
    /// kept in memory only, never saved.
    let applePrivateKeyPEM: String

    init(scenario: DemoScenario?) {
        let key = P256.Signing.PrivateKey()
        applePrivateKeyPEM = key.pemRepresentation
        platform = DemoJamfPlatformServer(scenario: scenario == .jamfSchool ? .jamfSchool : nil,
                                          jamfPro: .contosoPlatform())
        jamfPro = DemoJamfProServer(scenario: scenario)
        jamfProSource = DemoJamfProServer(objects: .contosoSource())
        jamfProDestination = DemoJamfProServer(objects: .contosoDestination(scenario: scenario))
        jamfSchool = DemoJamfSchoolServer(scenario: scenario)
        intune = DemoIntuneServer(scenario: scenario)
        appleBusiness = DemoAppleBusinessServer(organization: .contoso, scenario: scenario)
        appleSchool = DemoAppleBusinessServer(organization: .academy, scenario: scenario)
        let signIn = DemoAppleSignInServer(keys: [Connection.demoAppleBusiness.clientID: key.publicKey,
                                                  Connection.demoAppleSchool.clientID: key.publicKey])
        var servers: [String: any DemoServer] = [
            DemoSamples.platformHost: platform,
            DemoWorld.jamfProHost: jamfPro,
            DemoJamfProObjectSamples.sourceHost: jamfProSource,
            DemoJamfProObjectSamples.destinationHost: jamfProDestination,
            DemoWorld.jamfSchoolHost: jamfSchool,
            DemoAppleSignInServer.host: signIn,
            ABM.Service.business.host: appleBusiness,
            ABM.Service.school.host: appleSchool,
        ]
        for host in DemoIntuneServer.hosts { servers[host] = intune }
        network = DemoNetwork(servers: servers)
    }
}

/// Demo connections’ secrets: a fixed fake secret, and every write refused,
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
/// takes it off again when it’s turned off, so a screenshot can’t be taken
/// for real data. A window whose title changes later (a Settings tab) gets it
/// back straight away.
@MainActor
final class DemoWindowTitles {
    static let shared = DemoWindowTitles()

    private var observer: (any NSObjectProtocol)?
    /// One title watch per window seen: SwiftUI can set a title after the
    /// window’s last update (the Settings window names its tab), so the
    /// suffix is put back whenever a title changes.
    private var titleWatches: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// The close watch of each window in `titleWatches`, removed with it.
    private var closeWatches: [ObjectIdentifier: any NSObjectProtocol] = [:]
    private(set) var isOn = false

    /// Windows watched now; for tests.
    var watchedWindowCount: Int { titleWatches.count }

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

    func apply(to window: NSWindow?) {
        guard let window, !(window is NSPanel) else { return }
        let id = ObjectIdentifier(window)
        if titleWatches[id] == nil {
            titleWatches[id] = window.observe(\.title, options: [.new]) { window, _ in
                MainActor.assumeIsolated { DemoWindowTitles.shared.retitle(window) }
            }
            closeWatches[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { DemoWindowTitles.shared.stopWatching(id) }
            }
        }
        retitle(window)
    }

    func stopWatching(_ id: ObjectIdentifier) {
        titleWatches[id] = nil
        if let watch = closeWatches.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(watch)
        }
    }

    private func retitle(_ window: NSWindow) {
        let title = DemoMode.windowTitle(window.title, isOn: isOn)
        if title != window.title { window.title = title }
    }
}

/// Demo mode’s scratch folder in the temporary directory: removed when the
/// app quits, or when its `DemoMode` goes.
nonisolated final class ScratchFolder {
    let url: URL
    private let quitWatch: any NSObjectProtocol

    init() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "JTKitDemo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.url = url
        quitWatch = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                           object: nil, queue: nil) { _ in
            try? FileManager.default.removeItem(at: url)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(quitWatch)
        try? FileManager.default.removeItem(at: url)
    }
}

/// The settings suites of sandbox runs: one per run, named after its process.
nonisolated enum SandboxSuite {
    static let prefix = "JTKitSandbox-"

    static func name(processID: Int32) -> String {
        "\(prefix)\(processID)"
    }

    /// Suites left behind by runs that ended without quitting (a UI test
    /// that was stopped), and the one suite every run shared before.
    static func removeLeftovers(in folder: URL? = preferencesFolder,
                                isRunning: (Int32) -> Bool = isProcessRunning) {
        UserDefaults.standard.removePersistentDomain(forName: "JTKitSandbox")
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for file in files where file.hasPrefix(prefix) && file.hasSuffix(".plist") {
            let suite = String(file.dropLast(".plist".count))
            guard let processID = Int32(suite.dropFirst(prefix.count)), !isRunning(processID) else { continue }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder.appending(path: file))
        }
    }

    static var preferencesFolder: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appending(path: "Preferences")
    }

    static func isProcessRunning(_ processID: Int32) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }
}
