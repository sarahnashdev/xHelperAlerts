import SwiftUI

/// Bundled CHANGELOG.md rendered as Markdown, embedded as the "What's
/// New" tab inside the Settings window.
struct VersionHistoryView: View {
    private let changelog: AttributedString = Self.loadChangelog()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("What's New")
                            .font(.system(size: 22, weight: .bold))
                        Text("Every change shipped with each release.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 8)

                Divider()

                Text(changelog)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
    }

    /// Load the bundled CHANGELOG.md from `Contents/Resources/`. Falls
    /// back to a one-line note if the file isn't shipped.
    private static func loadChangelog() -> AttributedString {
        let fallback = AttributedString("Changelog not bundled.")
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return fallback }
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: raw, options: opts)) ?? AttributedString(raw)
    }
}
