import SwiftUI

// The apps’ recurring visual idioms, packaged as small components so every
// screen reads the same way.

/// Capsule status pill, e.g. "Managed", "Test tenant".
@MainActor
public struct StatusBadge: View {
    public nonisolated enum Style: Sendable {
        /// Accent-tinted pill for affirmative states.
        case tinted
        /// Quiet pill for neutral metadata.
        case neutral
        /// Yellow pill for a caution about the app itself, e.g. a setting
        /// that limits it. For a record’s state that needs a step, use `attention`.
        case warning
        /// A pill in a state’s color, e.g. Deployed in green: the text in
        /// the primary color (readable at caption size in every appearance)
        /// on a wash of the color, with a hairline of it.
        case colored(Color)

        /// Done, passed, deployed.
        public static let success = Style.colored(.green)
        /// Needs another step, e.g. out of date.
        public static let attention = Style.colored(.orange)
        /// Failed or refused.
        public static let failure = Style.colored(.red)
        /// Informational, e.g. a state the app doesn’t know.
        public static let info = Style.colored(.blue)
    }

    private let text: String
    private let style: Style
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ text: String, style: Style = .tinted) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .overlay {
                if case .colored(let color) = style {
                    Capsule().strokeBorder(color.opacity(contrast == .increased ? 1 : 0.6), lineWidth: 1)
                }
            }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .tinted: AnyShapeStyle(.tint.opacity(0.15))
        case .neutral: AnyShapeStyle(.quaternary)
        case .warning: AnyShapeStyle(.yellow.opacity(0.25))
        case .colored(let color): AnyShapeStyle(color.opacity(contrast == .increased ? 0.3 : 0.18))
        }
    }
}

extension JamfPlatform.BlueprintState {
    /// The badge style the Blueprint apps show a state with: Deployed
    /// green, Out of Date orange, Not Deployed quiet, another state blue.
    public var badgeStyle: StatusBadge.Style {
        switch self {
        case .deployed: .success
        case .outOfDate: .attention
        case .notDeployed: .neutral
        case .other: .info
        }
    }
}

/// A warning in a sentence: the multicolor triangle (yellow with a black
/// mark, the system’s own warning look) before the text, which carries the
/// meaning on its own.
public struct WarningLabel: View {
    private let text: Text

    public init(_ text: String) {
        self.text = Text(text)
    }

    public init(_ text: Text) {
        self.text = text
    }

    public var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
        }
    }
}

/// The shared pass/fail/warning iconography.
public nonisolated enum StatusIndicator: Sendable {
    case success
    case failure
    case warning
    case neutral
    case running

    @MainActor
    @ViewBuilder
    public var icon: some View {
        switch self {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Passed")
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Failed")
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityLabel("Needs attention")
        case .neutral:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not applicable")
        case .running:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("In progress")
        }
    }
}

/// The shared sheet skeleton: titled header with a busy spinner, divider,
/// content, divider, footer row.
@MainActor
public struct SheetFrame<Content: View, Footer: View>: View {
    private let title: String
    private let systemImage: String
    private let isBusy: Bool
    private let content: Content
    private let footer: Footer

    public init(
        title: String,
        systemImage: String,
        isBusy: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isBusy = isBusy
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("In progress")
                }
            }
            .padding()

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                footer
            }
            .padding()
        }
    }
}

/// The shared detail-page header: large tinted symbol, bold title and a
/// monospaced secondary subtitle.
@MainActor
public struct DetailHeader: View {
    private let systemImage: String
    private let title: String
    private let subtitle: String?

    public init(systemImage: String, title: String, subtitle: String? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                // Decoration; the title says what this is.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
