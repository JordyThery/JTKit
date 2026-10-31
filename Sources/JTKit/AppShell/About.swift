import AppKit
import SwiftUI

/// What an app tells the About window about itself. The icon and version are
/// read from the app bundle.
public nonisolated struct AboutConfiguration: Sendable {
    /// The app’s display name, e.g. `"AppSettings2Blueprint"`.
    public var appName: String
    /// The copyright line under the version. JTKit writes it; the app’s
    /// `NSHumanReadableCopyright` isn’t used.
    public var copyright: AboutCopyright?
    /// A line under the copyright, e.g. `"Created by Jordy Thery"`.
    public var author: String?
    /// One or two sentences on what the app does.
    public var summary: String?
    /// Links under the summary, e.g. the GitHub repository.
    public var links: [AboutLink]
    /// Third-party code the app includes or is based on. Leave empty when there is none.
    public var acknowledgements: [Acknowledgement]
    /// A closing note, e.g. that the app isn’t affiliated with a vendor.
    public var disclaimer: String?

    public init(
        appName: String,
        copyright: AboutCopyright? = nil,
        author: String? = nil,
        summary: String? = nil,
        links: [AboutLink] = [],
        acknowledgements: [Acknowledgement] = [],
        disclaimer: String? = nil
    ) {
        self.appName = appName
        self.copyright = copyright
        self.author = author
        self.summary = summary
        self.links = links
        self.acknowledgements = acknowledgements
        self.disclaimer = disclaimer
    }

    /// "About AppSettings2Blueprint": the window title and the app menu item.
    public var windowTitle: String { "About \(appName)" }
}

/// Who holds the app’s copyright and the license it is released under. The
/// About window shows it as "© 2026 Jordy Thery. Released under the MIT License."
public nonisolated struct AboutCopyright: Sendable, Hashable {
    /// The year, or a range such as `"2024–2026"`.
    public var year: String
    /// e.g. `"Jordy Thery"`.
    public var holder: String
    /// The license’s name as it is usually written, e.g. `"MIT License"`.
    public var license: String

    public init(year: String, holder: String, license: String = "MIT License") {
        self.year = year
        self.holder = holder
        self.license = license
    }

    @available(*, deprecated, renamed: "init(year:holder:license:)")
    public init(year: String, holder: String, licence: String) {
        self.init(year: year, holder: holder, license: licence)
    }

    @available(*, deprecated, renamed: "license")
    public var licence: String {
        get { license }
        set { license = newValue }
    }

    /// "© 2026 Jordy Thery. Released under the MIT License."
    public var text: String {
        "© \(year) \(holder). Released under the \(license)."
    }
}

/// A link with a visible title.
public nonisolated struct AboutLink: Sendable, Hashable, Identifiable {
    public var title: String
    public var url: URL

    public var id: URL { url }

    public init(_ title: String, url: URL) {
        self.title = title
        self.url = url
    }

    /// Nil when `address` isn’t a valid URL, so a typo drops the link instead of crashing.
    public init?(_ title: String, address: String) {
        guard let url = URL(string: address) else { return nil }
        self.init(title, url: url)
    }
}

/// Credit for one piece of third-party code, with its license as published.
public nonisolated struct Acknowledgement: Sendable, Hashable, Identifiable {
    /// The project’s name, e.g. `"App Settings Utility"`.
    public var name: String
    /// Who made it, e.g. `"Anthony Darlow"`.
    public var author: String?
    /// What the app uses it for.
    public var summary: String?
    public var links: [AboutLink]
    /// The full license text, unchanged from the project.
    public var license: String?
    /// The label the app gave for the license, e.g. `"MPL-2.0"`.
    private var givenLicenseName: String?

    public var id: String { name }

    /// - Parameter licenseName: the license’s label in the About window. Give it
    ///   when the text doesn’t start with the license’s name, e.g. when it opens
    ///   with a copyright line. Without it the label is the text’s first line.
    public init(
        name: String,
        author: String? = nil,
        summary: String? = nil,
        links: [AboutLink] = [],
        license: String? = nil,
        licenseName: String? = nil
    ) {
        self.name = name
        self.author = author
        self.summary = summary
        self.links = links
        self.license = license
        self.givenLicenseName = licenseName
    }

    @available(*, deprecated, renamed: "init(name:author:summary:links:license:licenseName:)")
    public init(
        name: String,
        author: String? = nil,
        summary: String? = nil,
        links: [AboutLink] = [],
        licence: String?,
        licenceName: String? = nil
    ) {
        self.init(name: name, author: author, summary: summary, links: links, license: licence, licenseName: licenceName)
    }

    /// "App Settings Utility by Anthony Darlow".
    public var heading: String {
        author.map { "\(name) by \($0)" } ?? name
    }

    /// The license’s label: the name the app gave, otherwise the text’s first
    /// non-empty line ("MIT License"). Nil when there is no license text.
    public var licenseName: String? {
        guard let license else { return nil }
        return givenLicenseName ?? license.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    @available(*, deprecated, renamed: "license")
    public var licence: String? {
        get { license }
        set { license = newValue }
    }

    @available(*, deprecated, renamed: "licenseName")
    public var licenceName: String? { licenseName }
}

/// The About window. Open it only from the app menu (`AppInfoCommands`); it is
/// left out of the Window menu.
///
/// ```swift
/// AboutWindow(configuration: .myApp)
/// ```
public struct AboutWindow: Scene {
    /// The window’s scene identifier, for `openWindow(id:)`.
    public static let id = "jtkit-about"

    let configuration: AboutConfiguration

    public init(configuration: AboutConfiguration) {
        self.configuration = configuration
    }

    public var body: some Scene {
        Window(configuration.windowTitle, id: Self.id) {
            AboutView(configuration: configuration)
                .modifier(CloseOnlyWindow())
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Mac apps don’t list About in the Window menu.
        .commandsRemoved()
    }
}

/// Like a standard Mac About window: only the close button works; minimize and
/// zoom are dimmed.
private struct CloseOnlyWindow: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
        } else {
            content.background(DimWindowButtons())
        }
    }
}

/// macOS 14 has no SwiftUI modifiers for this; dims the buttons on the hosting window.
private struct DimWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowButtonsView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowButtonsView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.remove(.miniaturizable)
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}

/// The app menu’s first items: "About [App]" and "Check for Updates…".
///
/// ```swift
/// .commands { AppInfoCommands(appName: "MyApp") { updates.checkManually() } }
/// ```
public struct AppInfoCommands: Commands {
    let appName: String
    let checkForUpdates: @MainActor () -> Void
    @Environment(\.openWindow) private var openWindow

    /// - Parameter checkForUpdates: runs a manual check; also bring forward the
    ///   window that presents the update sheet.
    public init(appName: String, checkForUpdates: @escaping @MainActor () -> Void) {
        self.appName = appName
        self.checkForUpdates = checkForUpdates
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(appName)") { openWindow(id: AboutWindow.id) }
            // The HIG puts About in a group of its own.
            Divider()
            Button("Check for Updates…") { checkForUpdates() }
        }
    }
}

/// The About window’s content: icon, name, version, copyright, author, summary,
/// links, disclaimer and acknowledgements. Update controls live in the app menu and
/// in Settings (`UpdateSettingsSection`), not here.
struct AboutView: View {
    let configuration: AboutConfiguration

    public init(configuration: AboutConfiguration) {
        self.configuration = configuration
    }

    /// "Version 1.2 (45)", with the same fallbacks the apps used.
    nonisolated static func versionText(short: String?, build: String?) -> String {
        "Version \(short ?? "1.0") (\(build ?? "1"))"
    }

    private var version: String {
        Self.versionText(
            short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    public var body: some View {
        if configuration.acknowledgements.isEmpty {
            content
                .frame(width: 600)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView {
                content
            }
            .frame(width: 600, height: 640)
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)

            Text(configuration.appName)
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(version)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let copyright = configuration.copyright {
                Text(copyright.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let author = configuration.author {
                Text(author)
                    .padding(.top, 6)
            }

            if let summary = configuration.summary {
                Text(summary)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            if !configuration.links.isEmpty {
                LinkRow(links: configuration.links, alignment: .center)
                    .padding(.top, 6)
            }

            // Above the acknowledgements, so it isn’t buried under long licenses.
            if let disclaimer = configuration.disclaimer {
                Text(disclaimer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            if !configuration.acknowledgements.isEmpty {
                Divider()
                    .padding(.vertical, 12)
                AcknowledgementsView(acknowledgements: configuration.acknowledgements)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}

/// The Acknowledgements part of the About window: each project’s credit, links
/// and full license text.
struct AcknowledgementsView: View {
    let acknowledgements: [Acknowledgement]

    public init(acknowledgements: [Acknowledgement]) {
        self.acknowledgements = acknowledgements
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Acknowledgements")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(acknowledgements) { acknowledgement in
                AcknowledgementRow(acknowledgement: acknowledgement)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AcknowledgementRow: View {
    let acknowledgement: Acknowledgement
    @State private var showsLicense = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(acknowledgement.heading)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let summary = acknowledgement.summary {
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !acknowledgement.links.isEmpty {
                LinkRow(links: acknowledgement.links, alignment: .leading)
            }
            if let license = acknowledgement.license {
                // Collapsed by default: MPL-2.0 and Apache-2.0 run to hundreds of lines.
                DisclosureGroup(isExpanded: $showsLicense) {
                    Text(license)
                        // Licenses are wrapped at about 80 columns; at this size a line fits.
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 4)
                } label: {
                    // The name opens it too, not only the small triangle.
                    Text(acknowledgement.licenseName ?? "License")
                        .contentShape(Rectangle())
                        .onTapGesture { showsLicense.toggle() }
                }
            }
        }
    }
}

/// Links side by side, or stacked when they don’t fit on one line.
private struct LinkRow: View {
    let links: [AboutLink]
    let alignment: HorizontalAlignment

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { items }
            VStack(alignment: alignment, spacing: 4) { items }
        }
    }

    private var items: some View {
        ForEach(links) { link in
            Link(link.title, destination: link.url)
        }
    }
}

#if DEBUG
#Preview("With acknowledgements") {
    AboutView(configuration: AboutConfiguration(
        appName: "Example",
        copyright: AboutCopyright(year: "2026", holder: "Jordy Thery"),
        author: "Created by Jordy Thery",
        summary: "A short sentence on what the app does.",
        links: [AboutLink("github.com/JordyThery/Example", address: "https://github.com/JordyThery/Example")].compactMap { $0 },
        acknowledgements: [Acknowledgement(name: "Some Library", author: "Someone", summary: "Used for one thing.", license: "MIT License\n\nCopyright (c) 2026 Someone")],
        disclaimer: "An independent project."
    ))
}

#Preview("Without") {
    AboutView(configuration: AboutConfiguration(appName: "Example", author: "Created by Jordy Thery"))
}
#endif
